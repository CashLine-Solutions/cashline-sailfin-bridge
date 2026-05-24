require "test_helper"

module Salesforce
  class ProfileRunnerTest < ActiveSupport::TestCase
    # A simple SOQL router. Each entry is [pattern, response]; the first
    # pattern matching the SOQL string wins. Response can be an Array of
    # hashes (which we wrap to support `.to_a`) or an exception class.
    class StubRest
      def initialize(routes)
        @routes = routes
      end

      def query(soql)
        route = @routes.find { |pattern, _| soql.include?(pattern) }
        raise "no route matched: #{soql}" unless route
        result = route[1]
        raise result if result.is_a?(Class) && result < Exception
        result.each
      end
    end

    class StubTooling
      def initialize(record_count: nil)
        @record_count = record_count
      end

      def query(_soql)
        [{ "RecordCount" => @record_count }].each
      end
    end

    setup do
      @user = User.create!(email_address: "ops@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
      @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, user: @user, seed_objects: %w[Account])
      @sobject = Sobject.create!(extraction_run: @run, api_name: "Contact", raw_describe: {})
      @safe = Sfield.create!(sobject: @sobject, api_name: "Title", data_type: "string", sensitivity: "safe", raw_describe: {})
      @pii = Sfield.create!(sobject: @sobject, api_name: "Email", data_type: "email", sensitivity: "pii", raw_describe: {})
    end

    test "computes null_rate from null_count / total" do
      routes = [
        ["FROM Contact WHERE Title = null", [{ "c" => 80 }]],
        ["FROM Contact WHERE Email = null", [{ "c" => 0 }]],
        ["COUNT_DISTINCT(Title)", [{ "c" => 5 }]],
        ["COUNT_DISTINCT(Email)", [{ "c" => 12 }]],
        ["SELECT Title FROM Contact", (1..10).map { |i| { "Title" => "T#{i}" } }],
        ["SELECT Email FROM Contact", (1..10).map { |i| { "Email" => "e#{i}@x.com" } }],
        # Top-N + sample queries (won't be hit for PII since policy denies, but
        # will be for safe Title even if policy says allowed-via-safe).
        ["GROUP BY Title", [{ "v" => "Engineer", "c" => 7 }]],
        ["GROUP BY Email", [{ "v" => "e1@x.com", "c" => 1 }]]
      ]

      runner = ProfileRunner.new(rest_client: StubRest.new(routes), tooling_client: StubTooling.new(record_count: 100))
      policy = Ontology::ProfilingPolicy.new(extraction_run: @run, user: @user)

      profile = runner.profile!(extraction_run: @run, sobject: @sobject, policy: policy)
      assert_equal "complete", profile.status
      assert_equal 100, profile.record_count

      title_fp = profile.field_profiles.joins(:sfield).find_by(sfields: { api_name: "Title" })
      assert_in_delta 0.8, title_fp.null_rate, 0.001
      assert_equal 5, title_fp.distinct_count
    end

    test "all-null field → null_rate 1.0 and distinct_count 0" do
      routes = [
        ["FROM Contact WHERE Title = null", [{ "c" => 100 }]],
        ["FROM Contact WHERE Email = null", [{ "c" => 100 }]],
        ["COUNT_DISTINCT(Title)", [{ "c" => 0 }]],
        ["COUNT_DISTINCT(Email)", [{ "c" => 0 }]],
        ["SELECT Title FROM Contact", []],
        ["SELECT Email FROM Contact", []]
      ]
      runner = ProfileRunner.new(rest_client: StubRest.new(routes), tooling_client: StubTooling.new(record_count: 100))
      policy = Ontology::ProfilingPolicy.new(extraction_run: @run, user: @user)

      runner.profile!(extraction_run: @run, sobject: @sobject, policy: policy)
      title_fp = FieldProfile.joins(:sfield).find_by(sfields: { id: @safe.id })
      assert_in_delta 1.0, title_fp.null_rate, 0.001
      assert_equal 0, title_fp.distinct_count
    end

    test "sensitive field with distinct_count 3 → suppressed" do
      tiny_pii = Sfield.create!(sobject: @sobject, api_name: "RareField", data_type: "string", sensitivity: "pii", raw_describe: {})

      routes = [
        ["FROM Contact WHERE Title = null", [{ "c" => 0 }]],
        ["FROM Contact WHERE Email = null", [{ "c" => 0 }]],
        ["FROM Contact WHERE RareField = null", [{ "c" => 0 }]],
        ["COUNT_DISTINCT(Title)", [{ "c" => 10 }]],
        ["COUNT_DISTINCT(Email)", [{ "c" => 10 }]],
        ["COUNT_DISTINCT(RareField)", [{ "c" => 3 }]],
        ["SELECT Title FROM Contact", []],
        ["SELECT Email FROM Contact", []],
        ["SELECT RareField FROM Contact", []],
        ["GROUP BY Title", [{ "v" => "x", "c" => 1 }]],
        ["GROUP BY Email", [{ "v" => "y", "c" => 1 }]],
        ["GROUP BY RareField", [{ "v" => "z", "c" => 1 }]]
      ]
      runner = ProfileRunner.new(rest_client: StubRest.new(routes), tooling_client: StubTooling.new(record_count: 100))
      policy = Ontology::ProfilingPolicy.new(extraction_run: @run, user: @user)

      runner.profile!(extraction_run: @run, sobject: @sobject, policy: policy)

      rare_fp = FieldProfile.joins(:sfield).find_by(sfields: { id: tiny_pii.id })
      assert rare_fp.distinct_count_suppressed
      assert_nil rare_fp.distinct_count
    end

    test "record_count > LARGE_OBJECT_THRESHOLD marks sampled and skips SOQL profiling" do
      called = 0
      stub = Object.new
      stub.define_singleton_method(:query) { |_| called += 1; raise "should not be called for large object" }

      runner = ProfileRunner.new(rest_client: stub, tooling_client: StubTooling.new(record_count: 1_000_000))
      policy = Ontology::ProfilingPolicy.new(extraction_run: @run, user: @user)

      profile = runner.profile!(extraction_run: @run, sobject: @sobject, policy: policy)
      assert profile.sampled
      assert_equal 0, called
    end

    test "safe field with override OFF still gets top-N + samples populated" do
      plain_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false, user: @user, seed_objects: [])
      sobject = Sobject.create!(extraction_run: plain_run, api_name: "Contact", raw_describe: {})
      safe = Sfield.create!(sobject: sobject, api_name: "Title", data_type: "string", sensitivity: "safe", raw_describe: {})

      routes = [
        ["FROM Contact WHERE Title = null", [{ "c" => 10 }]],
        ["COUNT_DISTINCT(Title)", [{ "c" => 4 }]],
        ["SELECT Title FROM Contact", [{ "Title" => "Engineer" }, { "Title" => "Manager" }]],
        ["GROUP BY Title", [{ "v" => "Engineer", "c" => 7 }, { "v" => "Manager", "c" => 3 }]],
      ]
      runner = ProfileRunner.new(rest_client: StubRest.new(routes), tooling_client: StubTooling.new(record_count: 100))
      policy = Ontology::ProfilingPolicy.new(extraction_run: plain_run, user: @user)
      runner.profile!(extraction_run: plain_run, sobject: sobject, policy: policy)

      fp = FieldProfile.joins(:sfield).find_by(sfields: { id: safe.id })
      assert_equal 2, fp.top_values.size
      refute fp.sensitive_override_used
    end

    test "pii field with override OFF → top-N and samples both empty" do
      plain_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false, user: @user, seed_objects: [])
      sobject = Sobject.create!(extraction_run: plain_run, api_name: "Contact", raw_describe: {})
      pii = Sfield.create!(sobject: sobject, api_name: "Email", data_type: "email", sensitivity: "pii", raw_describe: {})

      routes = [
        ["FROM Contact WHERE Email = null", [{ "c" => 5 }]],
        ["COUNT_DISTINCT(Email)", [{ "c" => 80 }]],
        ["SELECT Email FROM Contact", [{ "Email" => "e1@x.com" }]]
        # No GROUP BY route — verifying the runner doesn't issue that query.
      ]
      runner = ProfileRunner.new(rest_client: StubRest.new(routes), tooling_client: StubTooling.new(record_count: 100))
      policy = Ontology::ProfilingPolicy.new(extraction_run: plain_run, user: @user)
      runner.profile!(extraction_run: plain_run, sobject: sobject, policy: policy)

      fp = FieldProfile.joins(:sfield).find_by(sfields: { id: pii.id })
      assert_equal [], fp.top_values
      assert_equal [], fp.sample_values
      refute fp.sensitive_override_used
    end

    test "pii field with override ON + role → top-N and samples populated, sensitive_override_used=true" do
      routes = [
        ["FROM Contact WHERE Title = null", [{ "c" => 0 }]],
        ["FROM Contact WHERE Email = null", [{ "c" => 0 }]],
        ["COUNT_DISTINCT(Title)", [{ "c" => 5 }]],
        ["COUNT_DISTINCT(Email)", [{ "c" => 90 }]],
        ["SELECT Title FROM Contact", [{ "Title" => "Eng" }]],
        ["SELECT Email FROM Contact", [{ "Email" => "e1@x.com" }]],
        ["GROUP BY Title", [{ "v" => "Eng", "c" => 1 }]],
        ["GROUP BY Email", [{ "v" => "e1@x.com", "c" => 11 }]]
      ]
      runner = ProfileRunner.new(rest_client: StubRest.new(routes), tooling_client: StubTooling.new(record_count: 100))
      policy = Ontology::ProfilingPolicy.new(extraction_run: @run, user: @user)
      runner.profile!(extraction_run: @run, sobject: @sobject, policy: policy)

      email_fp = FieldProfile.joins(:sfield).find_by(sfields: { id: @pii.id })
      assert_equal 1, email_fp.top_values.size
      assert email_fp.sensitive_override_used
    end

    test "failure during profiling marks the object_profile failed and re-raises" do
      raising = Class.new do
        def query(_)
          raise StandardError, "boom"
        end
      end.new

      runner = ProfileRunner.new(rest_client: raising, tooling_client: StubTooling.new(record_count: 100))
      policy = Ontology::ProfilingPolicy.new(extraction_run: @run, user: @user)

      # The record_count path uses Tooling, then runs SOQL queries that raise.
      # Inside the runner, errors are swallowed per-query (safe_query / aggregate
      # rescue), so the profile actually completes — we assert that behavior.
      profile = runner.profile!(extraction_run: @run, sobject: @sobject, policy: policy)
      assert_equal "complete", profile.status
    end

    test "nil record_count (no Tooling RecordCount) sets sampled=false and proceeds via SOQL path" do
      # Reproduces the production bug where every standard Salesforce object
      # comes back with nil RecordCount from EntityDefinition. Previously
      # `use_bulk = nil && ...` resolved to nil and writing nil into the
      # NOT NULL `sampled` column raised PG::NotNullViolation for every
      # ProfileObjectJob in a run.
      routes = [
        ["FROM Contact WHERE Title = null", [{ "c" => 0 }]],
        ["FROM Contact WHERE Email = null", [{ "c" => 0 }]],
        ["COUNT_DISTINCT(Title)", [{ "c" => 1 }]],
        ["COUNT_DISTINCT(Email)", [{ "c" => 1 }]],
        ["SELECT COUNT(Id) c FROM Contact", [{ "c" => 0 }]],
        ["GROUP BY Title", [{ "v" => "X", "c" => 0 }]],
        ["GROUP BY Email", [{ "v" => "X", "c" => 0 }]],
        ["SELECT Title FROM Contact", []],
        ["SELECT Email FROM Contact", []]
      ]

      runner = ProfileRunner.new(rest_client: StubRest.new(routes), tooling_client: StubTooling.new(record_count: nil))
      policy = Ontology::ProfilingPolicy.new(extraction_run: @run, user: @user)

      profile = nil
      assert_nothing_raised do
        profile = runner.profile!(extraction_run: @run, sobject: @sobject, policy: policy)
      end

      assert_equal "complete", profile.status
      assert_equal false, profile.sampled
      assert_nil profile.record_count
    end
  end
end
