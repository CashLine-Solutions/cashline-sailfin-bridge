class ExtractDescribeJob < ApplicationJob
  # GoodJob's concurrency DSL is included from ApplicationJob in production via
  # an initializer (see config/initializers/good_job.rb). It is a no-op under
  # the test queue adapter, so we just declare the key here — single inflight
  # describe per run id keeps the run-directory writes well-ordered.
  if respond_to?(:good_job_control_concurrency_with)
    good_job_control_concurrency_with(total_limit: 1, key: -> { "extract_describe:#{arguments.first}" })
  end

  queue_as :default

  DEFAULT_WALK_OPTIONS = {
    "namespace_allowlist" => [ nil, "" ],
    "standard_allowlist" => %w[Account Contact User RecordType Opportunity Task Event],
    "max_hops" => 3
  }.freeze

  def perform(extraction_run_id)
    run = ExtractionRun.find(extraction_run_id)
    client = Salesforce::ClientFactory.rest

    # Pre-flight quota check. If we're already over, fail the run early so we
    # don't burn API budget on a doomed extraction.
    snapshot = Salesforce::LimitsCheck.guard!(client)
    run.mark_started!(limits_snapshot: snapshot)

    walker = Salesforce::DescribeWalker.new(
      client: client,
      seed_objects: run.seed_objects,
      namespace_allowlist: walk_option(run, "namespace_allowlist", DEFAULT_WALK_OPTIONS["namespace_allowlist"]),
      standard_allowlist: walk_option(run, "standard_allowlist", DEFAULT_WALK_OPTIONS["standard_allowlist"]),
      max_hops: walk_option(run, "max_hops", DEFAULT_WALK_OPTIONS["max_hops"])
    )

    result = walker.walk
    rd = Runs::RunDirectory.for(run)

    # Per-object describe failures the walker caught — surface them so the
    # run lands as `complete_with_warnings` rather than silently dropping them.
    Array(result.partial_failures).each do |pf|
      run.record_partial_failure!(object_api_name: pf[:object_api_name] || pf["object_api_name"],
                                  reason: pf[:reason] || pf["reason"])
    end

    rt_picklist_fetcher = Salesforce::RecordTypePicklistFetcher.new(client: client, api_version: run.api_version)

    result.describes.each do |api_name, payload|
      path = rd.object_jsonl_path(api_name)
      rd.append_jsonl!(path, { record_type: "describe", api_name: api_name, payload: payload })

      # Record-type-scoped picklists need a second call, so only spend the API
      # budget on objects that actually have non-Master record types.
      if scoped_record_types?(payload)
        record = rt_picklist_fetcher.fetch_for(api_name)
        rd.append_jsonl!(path, record) if record
      end
    rescue StandardError => e
      run.record_partial_failure!(object_api_name: api_name, reason: "describe write failed: #{e.message}")
    end

    rd.write_manifest!(
      "extraction_run_id" => run.id,
      "api_version" => run.api_version,
      "started_at" => run.started_at&.iso8601,
      "walk_options" => run.walk_options,
      "seed_objects" => run.seed_objects,
      "objects_visited" => result.visited,
      "edges" => result.edges
    )

    ExtractToolingJob.perform_later(run.id)
    result
  rescue Salesforce::Error, ActiveRecord::ActiveRecordError => e
    run&.mark_failed!(e.message)
    raise
  end

  private

  def walk_option(run, key, default)
    run.walk_options.is_a?(Hash) ? run.walk_options.fetch(key, default) : default
  end

  # True when the object exposes at least one assignable, non-Master record
  # type -- i.e. real subtypes whose picklist availability can differ from the
  # global vocabulary. Master-only objects gain nothing from a layouts call.
  def scoped_record_types?(payload)
    Array(payload["recordTypeInfos"]).any? { |rti| !rti["master"] && rti.fetch("available", true) }
  end
end
