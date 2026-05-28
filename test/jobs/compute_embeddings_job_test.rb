require "test_helper"

class ComputeEmbeddingsJobTest < ActiveSupport::TestCase
  setup do
    schema = { "classes" => [ { "class_name" => "Invoice", "namespace" => nil, "columns" => [
      { "name" => "invoice_number", "type" => "string" }
    ] } ] }
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: schema)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
    Sfield.create!(sobject: @sobject, api_name: "Invoice_Number__c", data_type: "string", sensitivity: "safe", raw_describe: {})
  end

  test "is a no-op when OpenAI is not configured (heuristic-only)" do
    assert_not Openai::ClientFactory.configured?, "test env should have no OpenAI key"
    assert_nothing_raised { ComputeEmbeddingsJob.perform_now(@run.id, @snapshot.id) }
    assert_equal 0, EmbeddingCache.count
    assert_equal 0, MappingProposal.count
  end

  test "runs the combiner when embeddings are available" do
    combined = false
    fake_matcher = Object.new
    fake_matcher.define_singleton_method(:available?) { true }
    fake_matcher.define_singleton_method(:combine!) { |_run| combined = true }

    job = ComputeEmbeddingsJob.new
    job.define_singleton_method(:build_matcher) { |_snapshot| fake_matcher }
    job.perform(@run.id, @snapshot.id)

    assert combined, "combine! should run when the matcher is available"
  end

  test "swallows OpenAI errors so the grid never hard-fails" do
    failing = Object.new
    failing.define_singleton_method(:available?) { true }
    failing.define_singleton_method(:combine!) { |_run| raise Openai::Error, "boom" }

    job = ComputeEmbeddingsJob.new
    job.define_singleton_method(:build_matcher) { |_snapshot| failing }
    assert_nothing_raised { job.perform(@run.id, @snapshot.id) }
  end
end
