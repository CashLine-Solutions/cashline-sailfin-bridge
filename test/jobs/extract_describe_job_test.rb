require "test_helper"
require "fileutils"
require "ostruct"

class ExtractDescribeJobTest < ActiveJob::TestCase
  class StubRestClient
        attr_reader :described, :gets
        def initialize(payloads, limits:, layouts: {})
          @payloads = payloads
          @described = []
          @limits = limits
          @layouts = layouts
          @gets = []
        end

        def describe(name)
          @described << name
          @payloads[name] or raise "no describe payload stub for #{name}"
        end

        def get(path)
          @gets << path
          if path.include?("describe/layouts")
            name = @layouts.keys.find { |k| path.include?("/sobjects/#{k}/") }
            return OpenStruct.new(body: @layouts.fetch(name, { "recordTypeMappings" => [] }))
          end
          OpenStruct.new(body: @limits)
        end
  end

  setup do
    @tmp_root = Rails.root.join("tmp", "test", "extract_describe_job", SecureRandom.hex(4))
    FileUtils.mkdir_p(@tmp_root)
    Runs::RunDirectory.singleton_class.send(:define_method, :default_root) { @test_root }
    Runs::RunDirectory.instance_variable_set(:@test_root, @tmp_root)

    @payloads = {
      "Account" => {
        "name" => "Account",
        "label" => "Account",
        "namespacePrefix" => nil,
        "fields" => [
          { "name" => "Name", "type" => "string" },
          { "name" => "OwnerId", "type" => "reference", "referenceTo" => %w[User] }
        ]
      },
      "User" => {
        "name" => "User",
        "label" => "User",
        "namespacePrefix" => nil,
        "fields" => []
      }
    }
    @limits = {
      "DailyApiRequests" => { "Max" => 15_000, "Remaining" => 14_999 },
      "DailyBulkApiBatches" => { "Max" => 15_000, "Remaining" => 14_999 },
      "DailyBulkV2QueryJobs" => { "Max" => 10_000, "Remaining" => 9_999 },
      "ConcurrentAsyncGetReportInstances" => { "Max" => 200, "Remaining" => 199 }
    }
    @client = StubRestClient.new(@payloads, limits: @limits)
    Salesforce::ClientFactory.singleton_class.send(:define_method, :rest) { @test_rest }
    Salesforce::ClientFactory.instance_variable_set(:@test_rest, @client)
  end

  teardown do
    Salesforce::ClientFactory.singleton_class.send(:remove_method, :rest)
    Runs::RunDirectory.singleton_class.send(:remove_method, :default_root)
    FileUtils.rm_rf(@tmp_root)
  end

  test "writes one jsonl per visited object plus a manifest" do
    run = ExtractionRun.create!(
      api_version: "62.0",
      seed_objects: %w[Account],
      walk_options: { "namespace_allowlist" => [ nil ], "standard_allowlist" => %w[Account User], "max_hops" => 2 }
    )

    ExtractDescribeJob.new.perform(run.id)

    rd = Runs::RunDirectory.for(run.reload)
    assert File.exist?(rd.object_jsonl_path("Account"))
    assert File.exist?(rd.object_jsonl_path("User"))
    assert File.exist?(rd.manifest_path)

    manifest = JSON.parse(File.read(rd.manifest_path))
    assert_equal %w[Account User].sort, manifest["objects_visited"].sort
    assert_equal "62.0", manifest["api_version"]
  end

  test "marks the run extracting and records the limits snapshot" do
    run = ExtractionRun.create!(
      api_version: "62.0",
      seed_objects: %w[Account],
      walk_options: { "namespace_allowlist" => [ nil ], "standard_allowlist" => %w[Account User], "max_hops" => 1 }
    )

    ExtractDescribeJob.new.perform(run.id)

    run.reload
    assert_equal "extracting", run.status
    assert_equal 14_999, run.limits_at_start["DailyApiRequests"]["Remaining"]
  end

  test "fails the run when LimitsCheck.guard! raises" do
    starved_limits = @limits.merge("DailyApiRequests" => { "Max" => 15_000, "Remaining" => 1 })
    @client = StubRestClient.new(@payloads, limits: starved_limits)
    Salesforce::ClientFactory.instance_variable_set(:@test_rest, @client)

    run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])

    assert_raises(Salesforce::QuotaExhausted) do
      ExtractDescribeJob.new.perform(run.id)
    end

    run.reload
    assert_equal "failed", run.status
    assert_match(/quota/i, run.error_message)
  end

  test "writes a record_type_picklists line for objects with non-Master record types" do
    payloads = {
      "Account" => {
        "name" => "Account", "label" => "Account", "namespacePrefix" => nil,
        "fields" => [ { "name" => "Industry", "type" => "picklist" } ],
        "recordTypeInfos" => [
          { "recordTypeId" => "012MASTER", "name" => "Master", "master" => true },
          { "recordTypeId" => "012CUST", "name" => "Customer", "master" => false, "available" => true }
        ]
      }
    }
    layouts = {
      "Account" => { "recordTypeMappings" => [
        { "recordTypeId" => "012CUST", "name" => "Customer", "available" => true,
          "picklistsForRecordType" => [
            { "picklistName" => "Industry", "picklistValues" => [ { "value" => "Tech", "active" => true } ] }
          ] }
      ] }
    }
    client = StubRestClient.new(payloads, limits: @limits, layouts: layouts)
    Salesforce::ClientFactory.instance_variable_set(:@test_rest, client)

    run = ExtractionRun.create!(
      api_version: "62.0", seed_objects: %w[Account],
      walk_options: { "namespace_allowlist" => [ nil ], "standard_allowlist" => %w[Account], "max_hops" => 1 }
    )

    ExtractDescribeJob.new.perform(run.id)

    rd = Runs::RunDirectory.for(run.reload)
    lines = File.readlines(rd.object_jsonl_path("Account")).map { |l| JSON.parse(l) }
    rt_line = lines.find { |l| l["record_type"] == "record_type_picklists" }
    assert rt_line, "expected a record_type_picklists line"
    assert_equal "012CUST", rt_line["mappings"].first["record_type_id"]
    assert_equal %w[Tech], rt_line["mappings"].first["picklists"]["Industry"]
  end

  test "enqueues ExtractToolingJob on success" do
    run = ExtractionRun.create!(
      api_version: "62.0",
      seed_objects: %w[Account],
      walk_options: { "namespace_allowlist" => [ nil ], "standard_allowlist" => %w[Account User], "max_hops" => 1 }
    )

    assert_enqueued_with(job: ExtractToolingJob, args: [ run.id ]) do
      ExtractDescribeJob.new.perform(run.id)
    end
  end
end
