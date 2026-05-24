require "csv"

module Salesforce
  # Direct-Faraday Bulk API 2.0 query runner.
  #
  # Used by the profiling pipeline only when an object's record count exceeds
  # ProfileRunner::LARGE_OBJECT_THRESHOLD (100k). For smaller objects, SOQL
  # via Restforce in the REST client is fine.
  #
  # Token handling: Bulk 2.0 jobs can run for minutes-to-hours, longer than
  # the cached access-token lifetime. The runner re-reads the token from
  # Salesforce::TokenCache on every Faraday call (submit, each poll, each
  # result fetch) rather than capturing it once. On 401/404 it invalidates
  # the cache entry, triggers a fresh JWT exchange via Salesforce::ClientFactory,
  # and retries the failed call once.
  #
  # Sampling sub-strategy: leading-wildcard `WHERE Id LIKE '%X'` is non-selective
  # on large objects (Salesforce rejects it as "operation took too long"), and
  # MOD() is not available on Id strings in SOQL. So we partition the object's
  # lifetime by CreatedDate and pull a small slice from one or more windows.
  # The bias (samples cluster by time window) is documented in the manifest.
  class BulkV2Runner
    POLL_INTERVAL = 5 # seconds; tests stub this to 0
    POLL_TIMEOUT = 30 * 60 # 30 minutes hard cap
    OPEN_TIMEOUT = 10  # seconds to establish TCP connection
    REQUEST_TIMEOUT = 60 # seconds for a single Faraday call to return
    MAX_AUTH_RETRIES = 1
    # Concurrency cap for any GoodJob job that wraps this runner. Caller
    # sets: good_job_control_concurrency_with(total_limit: CONCURRENCY_LIMIT,
    #   key: -> { "bulk_v2:#{credentials.fetch(:consumer_key)}" }) so concurrent
    # Bulk jobs against the same org are bounded org-wide.
    CONCURRENCY_LIMIT = 3

    class JobFailedError < Salesforce::Error; end
    class JobTimeoutError < Salesforce::Error; end

    def initialize(client_factory: Salesforce::ClientFactory, poll_interval: POLL_INTERVAL, sleep_proc: ->(s) { sleep(s) })
      @client_factory = client_factory
      @poll_interval = poll_interval
      @sleep_proc = sleep_proc
    end

    # Submits a Bulk 2.0 query and yields each chunk of parsed rows (Array of
    # Hash) via `on_chunk`. Returns the final job hash.
    def query(soql:, on_chunk:)
      job = submit_job!(soql)
      wait_for_completion!(job["id"])
      stream_results(job["id"], on_chunk)
      job
    end

    # Builds a SOQL string that samples from a CreatedDate window. Provided as
    # a class method so callers (ProfileRunner large-path) can construct
    # sampling queries declaratively.
    def self.sampling_soql(object:, fields:, window_start:, window_end:, limit: 1000)
      cols = Array(fields).join(", ")
      "SELECT #{cols} FROM #{object} " \
        "WHERE CreatedDate >= #{window_start.utc.iso8601} " \
        "AND CreatedDate < #{window_end.utc.iso8601} " \
        "ORDER BY CreatedDate ASC LIMIT #{limit}"
    end

    private

    def submit_job!(soql)
      response = with_auth_retry do |token|
        connection(token).post("/services/data/v#{Salesforce::API_VERSION}/jobs/query") do |req|
          req.headers["Content-Type"] = "application/json"
          req.body = { operation: "query", query: soql, contentType: "CSV" }.to_json
        end
      end
      JSON.parse(response.body)
    end

    def wait_for_completion!(job_id)
      deadline = monotonic + POLL_TIMEOUT
      loop do
        response = with_auth_retry { |token| connection(token).get("/services/data/v#{Salesforce::API_VERSION}/jobs/query/#{job_id}") }
        state = JSON.parse(response.body)
        case state["state"]
        when "JobComplete"
          return state
        when "Failed", "Aborted"
          raise JobFailedError, "Bulk 2.0 job #{job_id} #{state['state']}: #{state['errorMessage']}"
        when "UploadComplete", "InProgress"
          raise JobTimeoutError, "Bulk 2.0 job #{job_id} timed out after #{POLL_TIMEOUT}s" if monotonic > deadline
          @sleep_proc.call(@poll_interval)
        else
          raise JobFailedError, "Bulk 2.0 job #{job_id} unexpected state #{state['state'].inspect}"
        end
      end
    end

    def stream_results(job_id, on_chunk)
      locator = nil
      loop do
        path = "/services/data/v#{Salesforce::API_VERSION}/jobs/query/#{job_id}/results"
        path += "?locator=#{locator}" if locator

        response = with_auth_retry { |token| connection(token).get(path) }
        rows = parse_csv(response.body)
        on_chunk.call(rows) unless rows.empty?

        locator = response.headers["Sforce-Locator"]
        break if locator.nil? || locator == "null" || locator.empty?
      end
    end

    def parse_csv(body)
      return [] if body.nil? || body.strip.empty?
      CSV.parse(body, headers: true).map(&:to_h)
    end

    def connection(token)
      Faraday.new(url: token.instance_url) do |f|
        f.headers["Authorization"] = "Bearer #{token.access_token}"
        # Hard bound on a single Faraday call so a hung Salesforce response
        # cannot pin a GoodJob worker thread + DB connection indefinitely.
        # POLL_TIMEOUT only fires between polls; this fires within them.
        f.options.open_timeout = OPEN_TIMEOUT
        f.options.timeout = REQUEST_TIMEOUT
        f.adapter Faraday.default_adapter
      end
    end

    def with_auth_retry
      retries = 0
      begin
        token = @client_factory.ensure_token
        response = yield(token)
        if [ 401, 404 ].include?(response.status) && retries < MAX_AUTH_RETRIES
          @client_factory.invalidate_token!
          retries += 1
          raise RetryError
        end
        raise JobFailedError, "Bulk 2.0 call failed (#{response.status}): #{response.body}" if response.status >= 400
        response
      rescue RetryError
        retry
      rescue Faraday::Error, SocketError, SystemCallError => e
        # Surface transport-layer failures as Salesforce::Error so callers
        # (job-level rescue) can handle them like any other SF failure
        # rather than letting them propagate to GoodJob as an unrelated
        # job error that triggers full retry from the top.
        raise Salesforce::Error, "Bulk 2.0 transport failure: #{e.class}: #{e.message}"
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    class RetryError < StandardError; end
  end
end
