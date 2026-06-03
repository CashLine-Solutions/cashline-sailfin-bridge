require "fileutils"

# Full Sailfin data download: a complete metadata sweep followed by a full
# record export into the generic sf_records table, plus a pg_dump helper to
# ship the local snapshot to Render.
#
#   bin/rails sailfin:full_metadata               # describe every sfsrm/sfcapp object
#   bin/rails sailfin:download_records RUN=<id>    # pull all records for that run
#   bin/rails sailfin:dump_local                   # pg_dump primary DB for Render restore
namespace :sailfin do
  STANDARD_SEEDS = %w[Account Contact User RecordType Opportunity Task Event Pricebook2 Profile].freeze

  desc "Complete metadata sweep: describe every queryable sfsrm/sfcapp object + standard AR objects."
  task full_metadata: :environment do
    rest = Salesforce::ClientFactory.rest
    ns = ->(name) { name.include?("__") ? name.split("__").first : "(standard)" }

    sailfin = Array(rest.describe).filter_map do |e|
      name = e["name"] || e[:name]
      next if name.blank?
      queryable = e["queryable"].nil? ? e[:queryable] : e["queryable"]
      name if queryable && %w[sfsrm sfcapp].include?(ns.call(name))
    end

    seeds = (sailfin + STANDARD_SEEDS).uniq.sort
    run = ExtractionRun.create!(
      api_version: Salesforce::API_VERSION,
      status: "queued",
      seed_objects: seeds,
      walk_options: {
        "namespace_allowlist" => [ nil, "", "sfsrm", "sfcapp" ],
        "standard_allowlist"  => STANDARD_SEEDS,
        "max_hops"            => 4
      }
    )
    puts "Created run ##{run.id}: #{seeds.size} seed objects (#{sailfin.size} sfsrm/sfcapp + #{STANDARD_SEEDS.size} standard)."

    # Run describe + tooling synchronously. The :test adapter captures the
    # trailing perform_later calls (the chained ExtractToolingJob and the
    # per-object ProfileObjectJob fan-out) instead of executing them, so we run
    # tooling ourselves and skip profiling — profiling samples each object for
    # sensitivity classification, which is unrelated to a full data download
    # and would burn API budget we want for the record export.
    previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    begin
      puts "Walking describe graph..."
      ExtractDescribeJob.perform_now(run.id)
      puts "Loading relational metadata (+ tooling)..."
      ExtractToolingJob.perform_now(run.id)
    ensure
      ActiveJob::Base.queue_adapter = previous_adapter
    end

    run.reload
    field_count = Sfield.joins(:sobject).where(sobjects: { extraction_run_id: run.id }).count
    puts "Run ##{run.id} #{run.status}: #{run.sobjects.count} objects, #{field_count} fields."
    puts "Partial failures: #{run.partial_failures.size}" if run.partial_failures.any?
    puts "\nNext: bin/rails sailfin:download_records RUN=#{run.id}"
  end

  # Objects whose records carry no business value and are excluded by default.
  # ContentBody is a 1-column (Id only) internal blob index — Salesforce
  # platform plumbing, not data. Actual file bytes live in base64 fields, which
  # RecordExporter skips regardless (see the deferred file-binary capability).
  DEFAULT_EXCLUDE_OBJECTS = %w[ContentBody].freeze

  desc "Download records for a run's objects into sf_records. Skips __Share + __History + " \
       "useless platform objects by default; FULL=1 pulls every object. " \
       "RUN=<id> [FULL=1] [INCLUDE_SHARE=1] [HISTORY=1] [FORCE=1] [ONLY=Obj1,Obj2] [EXCLUDE=Obj1,Obj2]"
  task download_records: :environment do
    run = ExtractionRun.find(ENV.fetch("RUN") { abort("Set RUN=<extraction_run_id>") })
    # FULL=1 is the "give me everything" switch: every object, including __Share
    # ACL rows, __History audit trails, and ContentBody. The actual file *bytes*
    # (base64 fields) are still excluded by RecordExporter — that binary
    # capability is deferred separately.
    full = ENV["FULL"] == "1"
    include_share = full || ENV["INCLUDE_SHARE"] == "1"
    include_history = full || ENV["HISTORY"] == "1"
    force = ENV["FORCE"] == "1"
    only = ENV["ONLY"].to_s.split(",").map(&:strip).reject(&:blank?)
    extra_exclude = ENV["EXCLUDE"].to_s.split(",").map(&:strip).reject(&:blank?)

    # Pre-flight quota guard so we fail fast rather than mid-sweep.
    Salesforce::LimitsCheck.guard!(Salesforce::ClientFactory.rest)

    scope = run.sobjects.order(:api_name)
    scope = scope.where(api_name: only) if only.any?
    objects = scope.to_a

    excluded = (full ? [] : DEFAULT_EXCLUDE_OBJECTS) + extra_exclude
    objects, dropped_useless = objects.partition { |o| excluded.exclude?(o.api_name) }
    puts "Skipping #{dropped_useless.size} excluded object(s): #{dropped_useless.map(&:api_name).join(', ')}." if dropped_useless.any?

    unless include_share
      objects, shares = objects.partition { |o| !o.api_name.end_with?("__Share") }
      puts "Skipping #{shares.size} __Share objects (row-level ACL rows, not business data; pass INCLUDE_SHARE=1 to include)." if shares.any?
    end

    unless include_history
      objects, histories = objects.partition { |o| !o.api_name.end_with?("__History") }
      puts "Skipping #{histories.size} __History objects (field-change audit trails; pass HISTORY=1 to include)." if histories.any?
    end

    exporter = Salesforce::RecordExporter.new
    total = objects.size
    puts "Downloading records for #{total} objects from run ##{run.id}.\n\n"

    grand = 0
    failed = []
    objects.each_with_index do |sobject, i|
      prefix = "[#{i + 1}/#{total}] #{sobject.api_name}: "
      existing = DataExport.find_by(extraction_run_id: run.id, object_api_name: sobject.api_name)
      if existing&.complete? && !force
        puts "#{prefix}skip (already complete, #{existing.record_count} rows)"
        grand += existing.record_count
        next
      end

      begin
        export = exporter.export!(sobject: sobject)
        grand += export.record_count
        puts "#{prefix}#{export.record_count} rows"
      rescue StandardError => e
        failed << [ sobject.api_name, "#{e.class}: #{e.message}" ]
        puts "#{prefix}FAILED — #{e.class}: #{e.message}"
      end
    end

    puts "\nDone. #{grand} total rows across #{total - failed.size} objects."
    unless failed.empty?
      puts "\n#{failed.size} object(s) failed:"
      failed.each { |name, msg| puts "  #{name}: #{msg}" }
      puts "Re-run the same command to retry failures — completed objects are skipped."
    end
  end

  desc "pg_dump the primary DB (objects, fields, sf_records, mappings) for restore onto Render."
  task dump_local: :environment do
    config = ActiveRecord::Base.configurations
                               .configs_for(env_name: Rails.env, name: "primary")
                               .configuration_hash
    out_dir = Rails.root.join("storage", "dumps")
    FileUtils.mkdir_p(out_dir)
    stamp = Time.current.utc.strftime("%Y%m%dT%H%M%SZ")
    file = out_dir.join("primary-#{Rails.env}-#{stamp}.dump")

    cmd = [ "pg_dump", "--format=custom", "--no-owner", "--no-privileges", "--file=#{file}" ]
    cmd << "--host=#{config[:host]}" if config[:host].present?
    cmd << "--port=#{config[:port]}" if config[:port].present?
    cmd << "--username=#{config[:username]}" if config[:username].present?
    cmd << config.fetch(:database)

    puts "Dumping #{config[:database]} -> #{file}"
    env = config[:password].present? ? { "PGPASSWORD" => config[:password].to_s } : {}
    abort("pg_dump failed") unless system(env, *cmd)

    size_mb = (File.size(file).to_f / 1.megabyte).round(1)
    puts "Wrote #{size_mb} MB.\n\n"
    puts "Restore onto Render once you have access (custom-format dump):"
    puts "  pg_restore --no-owner --no-privileges --clean --if-exists \\"
    puts "    --dbname=\"$PRIMARY_DATABASE_URL\" #{file}"
    puts "\nOr stream without an intermediate file:"
    puts "  pg_dump --no-owner --no-privileges #{config[:database]} | psql \"$PRIMARY_DATABASE_URL\""
  end
end
