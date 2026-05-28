require "test_helper"

class Openai::EmbeddingsTest < ActiveSupport::TestCase
  class FakeResp
    def initialize(ok, status, body) = (@ok, @status, @body = ok, status, body)
    def success? = @ok
    def status = @status
    def body = @body
  end

  class FakeConn
    attr_reader :calls
    def initialize(ok: true, status: 200)
      @ok = ok
      @status = status
      @calls = []
    end

    # Echoes one zero-vector per input so batching is observable.
    def post(path, payload)
      @calls << { path: path, payload: payload }
      data = Array(payload[:input]).each_with_index.map { |_t, i| { "index" => i, "embedding" => Array.new(Openai::Embeddings::DIMENSIONS, 0.0) } }
      FakeResp.new(@ok, @status, { "data" => data })
    end
  end

  test "embeds texts and returns one vector per input, in order" do
    conn = FakeConn.new
    result = Openai::Embeddings.new(connection: conn).embed(%w[alpha beta])
    assert_equal 2, result.size
    assert_equal Openai::Embeddings::DIMENSIONS, result.first.size
    assert_equal "/v1/embeddings", conn.calls.first[:path]
    assert_equal "text-embedding-3-small", conn.calls.first[:payload][:model]
  end

  test "batches inputs over BATCH_SIZE" do
    conn = FakeConn.new
    texts = Array.new(Openai::Embeddings::BATCH_SIZE + 4) { |i| "t#{i}" }
    result = Openai::Embeddings.new(connection: conn).embed(texts)
    assert_equal texts.size, result.size
    assert_equal 2, conn.calls.size
  end

  test "raises on a non-success response" do
    conn = FakeConn.new(ok: false, status: 429)
    assert_raises(Openai::Error) { Openai::Embeddings.new(connection: conn).embed(%w[x]) }
  end

  test "available? is false when no credentials are configured" do
    assert_not Openai::Embeddings.new.available?
  end
end
