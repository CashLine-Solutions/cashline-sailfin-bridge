require "test_helper"
require "fileutils"

class ExtractToolingJobTest < ActiveJob::TestCase
  class FixedFetcher
    def initialize(records)
      @records = records
    end

    def fetch_for(api_name)
      @records.map { |r| r.merge("api_name" => api_name) }
    end
  end

  class RaisingFetcher
    def fetch_for(_api_name)
      raise Salesforce::Error, "tooling failure"
    end
  end

  setup do
    @tmp_root = Rails.root.join("tmp", "test", "extract_tooling_job", SecureRandom.hex(4))
    FileUtils.mkdir_p(@tmp_root)
    Runs::RunDirectory.singleton_class.send(:define_method, :default_root) { @test_root }
    Runs::RunDirectory.instance_variable_set(:@test_root, @tmp_root)

    @run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
    rd = Runs::RunDirectory.for(@run)
    rd.ensure!
    rd.write_manifest!(
      "extraction_run_id" => @run.id,
      "objects_visited" => %w[Account Contact]
    )
    rd.append_jsonl!(rd.object_jsonl_path("Account"), { record_type: "describe", api_name: "Account" })
    rd.append_jsonl!(rd.object_jsonl_path("Contact"), { record_type: "describe", api_name: "Contact" })
  end

  teardown do
    Runs::RunDirectory.singleton_class.send(:remove_method, :default_root)
    FileUtils.rm_rf(@tmp_root)
  end

  test "appends tooling records to each visited object's jsonl" do
    fixed = FixedFetcher.new([ { "record_type" => "tooling_field_metadata", "field_developer_name" => "X" } ])

    job = ExtractToolingJob.new
    job.define_singleton_method(:build_fetcher) { fixed }
    job.perform(@run.id)

    rd = Runs::RunDirectory.for(@run.reload)
    %w[Account Contact].each do |obj|
      records = File.readlines(rd.object_jsonl_path(obj)).map { |l| JSON.parse(l) }
      assert records.any? { |r| r["record_type"] == "tooling_field_metadata" }, "expected tooling record for #{obj}"
    end
  end

  test "records a partial failure when fetcher raises Salesforce::Error" do
    raising = RaisingFetcher.new

    job = ExtractToolingJob.new
    job.define_singleton_method(:build_fetcher) { raising }
    job.perform(@run.id)

    @run.reload
    assert_equal 2, @run.partial_failures.size
    assert_includes @run.partial_failures.map { |pf| pf["object_api_name"] }, "Account"
  end

  test "finalizes the run: loads relational tables, fans out profile jobs, stamps content_hash, marks complete" do
    fixed = FixedFetcher.new([ { "record_type" => "tooling_field_metadata", "field_developer_name" => "X" } ])

    job = ExtractToolingJob.new
    job.define_singleton_method(:build_fetcher) { fixed }

    assert_enqueued_jobs 2, only: ProfileObjectJob do
      job.perform(@run.id)
    end

    @run.reload
    assert_equal "complete", @run.status, "expected run to be marked complete after finalization"
    assert_equal 2, @run.sobjects.count, "expected RelationalLoader to populate sobjects from JSONL"
    assert @run.content_hash.present?, "expected content_hash to be stamped from the run directory"
    assert_match(/\A[a-f0-9]{64}\z/, @run.content_hash, "expected content_hash to be a SHA256 hex digest")
  end

  test "marks complete_with_warnings when partial failures were recorded" do
    raising = RaisingFetcher.new

    job = ExtractToolingJob.new
    job.define_singleton_method(:build_fetcher) { raising }
    job.perform(@run.id)

    @run.reload
    assert_equal "complete_with_warnings", @run.status
    assert @run.content_hash.present?
  end
end
