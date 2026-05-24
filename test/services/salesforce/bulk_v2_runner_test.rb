require "test_helper"
require "ostruct"

module Salesforce
  class BulkV2RunnerTest < ActiveSupport::TestCase
    # Stub Faraday connection that returns canned responses from a script.
    # Each entry is { method:, path_match:, response: }, where response is a
    # Struct.new(:status, :body, :headers) instance.
    class StubConnection
      def initialize(script)
        @script = script
        @calls = []
      end
      attr_reader :calls

      def post(path)
        @calls << [:post, path]
        next_response(:post, path)
      end

      def get(path)
        @calls << [:get, path]
        next_response(:get, path)
      end

      private

      def next_response(method, path)
        entry = @script.find { |e| e[:method] == method && path.include?(e[:path_match]) && !e[:consumed] }
        raise "no script entry matched #{method} #{path}" unless entry
        entry[:consumed] = true
        entry[:response]
      end
    end

    Response = Struct.new(:status, :body, :headers, keyword_init: true)

    class StubFactory
      def initialize(token:, on_invalidate: ->{})
        @token = token
        @on_invalidate = on_invalidate
      end

      def ensure_token; @token; end
      def invalidate_token!; @on_invalidate.call; end
    end

    setup do
      @token = OpenStruct.new(access_token: "abc", instance_url: "https://x.salesforce.com")
      @factory = StubFactory.new(token: @token)
      @runner = BulkV2Runner.new(client_factory: @factory, poll_interval: 0, sleep_proc: ->(_) {})
    end

    test "happy path: submit → poll twice → JobComplete → fetch one chunk of rows" do
      script = [
        { method: :post, path_match: "/jobs/query", response: Response.new(status: 200, body: { id: "JOB1", state: "UploadComplete" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB1", response: Response.new(status: 200, body: { state: "InProgress" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB1", response: Response.new(status: 200, body: { state: "JobComplete" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB1/results", response: Response.new(status: 200, body: "Id,Name\n001,Acme\n002,Beta\n", headers: { "Sforce-Locator" => "null" }) }
      ]
      stub_conn = StubConnection.new(script)
      @runner.define_singleton_method(:connection) { |_token| stub_conn }

      collected = []
      job = @runner.query(soql: "SELECT Id, Name FROM Account", on_chunk: ->(rows) { collected.concat(rows) })

      assert_equal "JOB1", job["id"]
      assert_equal 2, collected.size
      assert_equal "001", collected.first["Id"]
    end

    test "paginates results via Sforce-Locator header until null" do
      script = [
        { method: :post, path_match: "/jobs/query", response: Response.new(status: 200, body: { id: "JOB2" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB2", response: Response.new(status: 200, body: { state: "JobComplete" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB2/results", response: Response.new(status: 200, body: "Id\n001\n", headers: { "Sforce-Locator" => "CURSOR1" }) },
        { method: :get, path_match: "/jobs/query/JOB2/results", response: Response.new(status: 200, body: "Id\n002\n", headers: { "Sforce-Locator" => "null" }) }
      ]
      stub_conn = StubConnection.new(script)
      @runner.define_singleton_method(:connection) { |_| stub_conn }

      collected = []
      @runner.query(soql: "SELECT Id FROM Account", on_chunk: ->(r) { collected.concat(r) })
      assert_equal %w[001 002], collected.map { |r| r["Id"] }

      result_calls = stub_conn.calls.count { |m, p| m == :get && p.include?("results") }
      assert_equal 2, result_calls
    end

    test "JobFailed surfaces error message and does not retry" do
      script = [
        { method: :post, path_match: "/jobs/query", response: Response.new(status: 200, body: { id: "JOB3" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB3", response: Response.new(status: 200, body: { state: "Failed", errorMessage: "soql syntax" }.to_json, headers: {}) }
      ]
      stub_conn = StubConnection.new(script)
      @runner.define_singleton_method(:connection) { |_| stub_conn }

      err = assert_raises(BulkV2Runner::JobFailedError) do
        @runner.query(soql: "BAD SOQL", on_chunk: ->(_) {})
      end
      assert_match(/soql syntax/, err.message)
    end

    test "401 on submit invalidates token and retries once" do
      invalidated = false
      factory = StubFactory.new(token: @token, on_invalidate: ->{ invalidated = true })
      runner = BulkV2Runner.new(client_factory: factory, poll_interval: 0, sleep_proc: ->(_) {})

      script = [
        { method: :post, path_match: "/jobs/query", response: Response.new(status: 401, body: "", headers: {}) },
        { method: :post, path_match: "/jobs/query", response: Response.new(status: 200, body: { id: "JOB4" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB4", response: Response.new(status: 200, body: { state: "JobComplete" }.to_json, headers: {}) },
        { method: :get, path_match: "/jobs/query/JOB4/results", response: Response.new(status: 200, body: "Id\n001\n", headers: { "Sforce-Locator" => "null" }) }
      ]
      stub_conn = StubConnection.new(script)
      runner.define_singleton_method(:connection) { |_| stub_conn }

      assert_nothing_raised { runner.query(soql: "SELECT Id FROM Account", on_chunk: ->(_) {}) }
      assert invalidated, "expected token cache to be invalidated on 401"
    end

    test "non-auth 4xx surfaces as JobFailedError" do
      script = [
        { method: :post, path_match: "/jobs/query", response: Response.new(status: 400, body: "bad request", headers: {}) }
      ]
      stub_conn = StubConnection.new(script)
      @runner.define_singleton_method(:connection) { |_| stub_conn }

      err = assert_raises(BulkV2Runner::JobFailedError) do
        @runner.query(soql: "BAD", on_chunk: ->(_) {})
      end
      assert_match(/400/, err.message)
    end

    test "sampling_soql builds a CreatedDate-windowed query" do
      soql = BulkV2Runner.sampling_soql(
        object: "Invoice__c",
        fields: %w[Id Amount__c],
        window_start: Time.utc(2025, 1, 1),
        window_end: Time.utc(2025, 2, 1),
        limit: 500
      )
      assert_match(/FROM Invoice__c/, soql)
      assert_match(/CreatedDate >= 2025-01-01/, soql)
      assert_match(/CreatedDate < 2025-02-01/, soql)
      assert_match(/LIMIT 500/, soql)
      assert_match(/ORDER BY CreatedDate ASC/, soql)
    end

    test "concurrency limit is exposed for the wrapping job to honor" do
      assert_equal 3, BulkV2Runner::CONCURRENCY_LIMIT
    end
  end
end
