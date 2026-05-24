namespace :sailfin do
  desc <<~DESC
    Salesforce discovery helpers. Use these once Salesforce credentials are wired.

      bin/rails sailfin:smoke         # one-line auth + API connectivity check
      bin/rails sailfin:namespaces    # histogram of object api_name namespaces
      bin/rails sailfin:limits        # current API quota snapshot
  DESC
  task help: :environment do
    puts <<~HELP
      Sailfin discovery tasks:

        bin/rails sailfin:smoke         Verify JWT exchange + REST connectivity.
        bin/rails sailfin:namespaces    Group all visible objects by namespace prefix.
        bin/rails sailfin:limits        Print the org's current daily API limits.

      All tasks read credentials from Rails.application.credentials.salesforce.
    HELP
  end

  desc "Verify Salesforce JWT auth + a basic REST call."
  task smoke: :environment do
    user = Salesforce::ClientFactory.rest.query("SELECT Id, Username FROM User LIMIT 1").first
    if user
      puts "OK — authenticated. Sample user: #{user["Username"]} (Id: #{user["Id"]})"
    else
      puts "Auth succeeded but no User rows returned (org has zero users? unusual)."
    end
  rescue StandardError => e
    warn "Smoke test failed: #{e.class}: #{e.message}"
    warn ""
    warn "Common causes:"
    warn "  invalid_grant         -> integration user has not pre-authorized the Connected App"
    warn "  invalid_client_id     -> consumer_key wrong, or app still propagating (wait 2-10 min)"
    warn "  KeyError on :username -> credentials missing; bin/rails credentials:edit -e development"
    warn "  IP restriction        -> set Permitted Users IP Relaxation to 'Relax IP restrictions'"
    exit 1
  end

  desc "List all visible Salesforce objects grouped by namespace prefix."
  task namespaces: :environment do
    rest = Salesforce::ClientFactory.rest
    # Restforce returns an array of sobject metadata hashes when describe is
    # called with no argument; each entry has a "name" key.
    entries = rest.describe

    by_ns = Hash.new(0)
    examples = Hash.new { |h, k| h[k] = [] }

    Array(entries).each do |entry|
      name = entry.respond_to?(:[]) ? (entry["name"] || entry[:name]) : entry.to_s
      next if name.blank?
      ns = name.include?("__") ? name.split("__").first : "(standard)"
      by_ns[ns] += 1
      examples[ns] << name if examples[ns].size < 5
    end

    puts "Found #{Array(entries).size} visible objects across #{by_ns.size} namespaces.\n\n"
    by_ns.sort_by { |_ns, count| -count }.each do |ns, count|
      tag = ns == "(standard)" ? "standard" : "managed:#{ns}"
      puts "%5d  %-30s  %s" % [ count, tag, examples[ns].first(3).join(", ") ]
    end

    puts <<~NOTE

      Take note of:
        - Sailfin's managed-package namespace prefix (cluster it has the most objects)
        - Which standard objects you want to seed from (typically Account + Contact + Opportunity)

      Then update RunsController::PRESET_SEED_OBJECTS or pass a custom seed list at /runs/new.
    NOTE
  rescue StandardError => e
    warn "Namespace discovery failed: #{e.class}: #{e.message}"
    warn "Tip: run `bin/rails sailfin:smoke` first to verify auth before discovery."
    exit 1
  end

  desc "Print the current Salesforce API limits snapshot."
  task limits: :environment do
    snapshot = Salesforce::LimitsCheck.guard!(Salesforce::ClientFactory.rest)
    puts "Limits OK. Key counters:"
    %w[DailyApiRequests DailyBulkApiBatches DailyBulkV2QueryJobs].each do |key|
      entry = snapshot[key]
      next unless entry
      remaining = entry["Remaining"]
      max = entry["Max"]
      pct = max.to_f.zero? ? 0 : (remaining.to_f / max * 100).round(1)
      puts "  #{key.ljust(28)} #{remaining} / #{max}  (#{pct}% remaining)"
    end
  rescue Salesforce::QuotaExhausted => e
    warn "Quota would be exhausted: #{e.message}"
    exit 1
  rescue StandardError => e
    warn "Limits fetch failed: #{e.class}: #{e.message}"
    exit 1
  end
end
