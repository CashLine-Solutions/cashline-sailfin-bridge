require "test_helper"

class Mapping::EmbeddingMatcherTest < ActiveSupport::TestCase
  # Deterministic stand-in for OpenAI: each text becomes a unit vector at an
  # index. A `map` of substring => index lets a test force two unrelated texts
  # to the same vector (i.e. "semantically similar"). Records transmitted texts.
  class FakeEmbeddings
    attr_reader :inputs
    def initialize(map: {})
      @map = map
      @inputs = []
    end

    def available? = true

    def embed(texts)
      @inputs.concat(texts)
      texts.map { |t| vector_for(t) }
    end

    def vector_for(text)
      v = Array.new(Openai::Embeddings::DIMENSIONS, 0.0)
      key = @map.keys.find { |k| text.include?(k) }
      idx = key ? @map[key] : Digest::SHA256.hexdigest(text).to_i(16) % Openai::Embeddings::DIMENSIONS
      v[idx] = 1.0
      v
    end
  end

  setup do
    schema = { "classes" => [ { "class_name" => "Invoice", "namespace" => nil, "columns" => [
      { "name" => "id", "type" => "integer" },
      { "name" => "invoice_number", "type" => "string" },
      { "name" => "priority", "type" => "integer" },
      { "name" => "status", "type" => "integer", "enum_values" => { "draft" => 0 } }
    ] } ] }
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: schema)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
  end

  test "an identical descriptor is embedded once and cached on re-run" do
    Sfield.create!(sobject: @sobject, api_name: "Invoice_Number__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    fake = FakeEmbeddings.new

    Mapping::EmbeddingMatcher.new(snapshot: @snapshot, embeddings: fake).combine!(@run)
    after_first = fake.inputs.size
    assert after_first.positive?

    Mapping::EmbeddingMatcher.new(snapshot: @snapshot, embeddings: fake).combine!(@run)
    assert_equal after_first, fake.inputs.size, "cached descriptors must not be re-embedded"
  end

  test "a sensitive field is embedded metadata-only; a safe field's label is transmitted" do
    Sfield.create!(sobject: @sobject, api_name: "Notes__c", label: "PUBLIC_LABEL", data_type: "string",
      sensitivity: "safe", raw_describe: { "inlineHelpText" => "public help" })
    Sfield.create!(sobject: @sobject, api_name: "SSN__c", label: "SECRET_LABEL", data_type: "string",
      sensitivity: "pii", raw_describe: { "inlineHelpText" => "SECRET_HELP" })
    fake = FakeEmbeddings.new

    Mapping::EmbeddingMatcher.new(snapshot: @snapshot, embeddings: fake).combine!(@run)

    assert fake.inputs.any? { |t| t.include?("PUBLIC_LABEL") }, "safe field's label should be transmitted"
    refute fake.inputs.any? { |t| t.include?("SECRET_LABEL") || t.include?("SECRET_HELP") },
      "a pii field's label/help must never be transmitted"
  end

  test "unknown_sensitivity is treated as sensitive (fail-closed, metadata-only)" do
    Sfield.create!(sobject: @sobject, api_name: "Mystery__c", label: "UNK_LABEL", data_type: "string",
      sensitivity: "unknown_sensitivity", raw_describe: { "inlineHelpText" => "UNK_HELP" })
    fake = FakeEmbeddings.new

    Mapping::EmbeddingMatcher.new(snapshot: @snapshot, embeddings: fake).combine!(@run)
    refute fake.inputs.any? { |t| t.include?("UNK_LABEL") || t.include?("UNK_HELP") }
  end

  test "embedding nearest-neighbor adds a candidate that lexical+type matching missed" do
    # Memo__c (string) shares no tokens with priority and is type-incompatible
    # with it (integer) — heuristic alone would never propose it. The fake makes
    # them semantically identical.
    memo = Sfield.create!(sobject: @sobject, api_name: "Memo__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    fake = FakeEmbeddings.new(map: { "Memo" => 5, "priority" => 5 })

    Mapping::EmbeddingMatcher.new(snapshot: @snapshot, embeddings: fake).combine!(@run)

    proposal = MappingProposal.find_by(source_field_id: memo.id, target_class: "Invoice", target_field: "priority")
    assert proposal, "embedding should surface the semantically-matched target"
    assert_equal 1.0, proposal.signals["embedding"]
    assert_in_delta 1.0, proposal.score, 0.001
  end

  test "an embedding candidate already rejected is not re-created" do
    memo = Sfield.create!(sobject: @sobject, api_name: "Memo__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    MappingProposal.create!(source_field: memo, cashline_snapshot: @snapshot,
      target_class: "Invoice", target_field: "priority", score: 1.0, state: "rejected")
    fake = FakeEmbeddings.new(map: { "Memo" => 5, "priority" => 5 })

    Mapping::EmbeddingMatcher.new(snapshot: @snapshot, embeddings: fake).combine!(@run)
    refute MappingProposal.open.where(source_field_id: memo.id, target_field: "priority").exists?
  end

  test "purge_field! removes a field's sources and orphaned cache rows but keeps shared ones" do
    field = Sfield.create!(sobject: @sobject, api_name: "A__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    other = Sfield.create!(sobject: @sobject, api_name: "B__c", data_type: "string", sensitivity: "safe", raw_describe: {})

    EmbeddingCache.create!(content_sha256: "orphan", embedding: Array.new(1536, 0.0))
    EmbeddingCache.create!(content_sha256: "shared", embedding: Array.new(1536, 0.0))
    EmbeddingSource.create!(sfield: field, content_sha256: "orphan")
    EmbeddingSource.create!(sfield: field, content_sha256: "shared")
    EmbeddingSource.create!(sfield: other, content_sha256: "shared")

    Mapping::EmbeddingMatcher.purge_field!(field)

    assert_equal 0, EmbeddingSource.where(sfield_id: field.id).count
    assert_not EmbeddingCache.exists?(content_sha256: "orphan"), "orphaned cache row removed"
    assert EmbeddingCache.exists?(content_sha256: "shared"), "still-referenced cache row kept"
  end

  test "a safe -> sensitive reclassification purges the field's embeddings via the model hook" do
    field = Sfield.create!(sobject: @sobject, api_name: "C__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    EmbeddingCache.create!(content_sha256: "h1", embedding: Array.new(1536, 0.0))
    EmbeddingSource.create!(sfield: field, content_sha256: "h1")

    field.update!(sensitivity: "pii")

    assert_equal 0, EmbeddingSource.where(sfield_id: field.id).count
    assert_not EmbeddingCache.exists?(content_sha256: "h1")
  end
end
