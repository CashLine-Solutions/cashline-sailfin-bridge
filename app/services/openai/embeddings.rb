module Openai
  # Computes text embeddings via OpenAI's /v1/embeddings. One model in scope:
  # text-embedding-3-small (1536 dims, cosine). Transmits only the descriptor
  # text it is given — callers (Mapping::EmbeddingMatcher) are responsible for
  # the metadata-only / sensitivity gating; this layer never sees field values.
  class Embeddings
    MODEL = "text-embedding-3-small".freeze
    DIMENSIONS = 1536
    BATCH_SIZE = 96

    # connection is injectable for tests (a fake Faraday-like object).
    def initialize(connection: nil)
      @connection = connection
    end

    def available?
      Openai::ClientFactory.configured?
    end

    # texts: Array<String>. Returns Array<Array<Float>> in the same order.
    def embed(texts)
      texts = Array(texts)
      return [] if texts.empty?
      texts.each_slice(BATCH_SIZE).flat_map { |batch| request_batch(batch) }
    end

    private

    def conn
      @connection ||= Openai::ClientFactory.connection
    end

    def request_batch(batch)
      response = conn.post("/v1/embeddings", { model: MODEL, input: batch })
      unless response.success?
        raise Openai::Error, "OpenAI embeddings request failed (#{response.status}): #{response.body}"
      end
      Array(response.body["data"]).sort_by { |d| d["index"] }.map { |d| d["embedding"] }
    end
  end
end
