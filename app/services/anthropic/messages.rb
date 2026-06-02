module Anthropic
  # Thin wrapper over POST /v1/messages. The only mode used here is a forced
  # single-tool call, which gives us schema-constrained structured output
  # (the candidate `target_id` is an enum, so the model cannot invent one).
  class Messages
    DEFAULT_MODEL = "claude-opus-4-7".freeze
    DEFAULT_MAX_TOKENS = 1024

    # connection is injectable for tests (a fake Faraday-like object).
    def initialize(connection: nil, model: DEFAULT_MODEL)
      @connection = connection
      @model = model
    end

    attr_reader :model

    def available?
      Anthropic::ClientFactory.configured?
    end

    # Forces `tool` and returns its parsed input hash (the structured result).
    #
    # cache_key: when non-nil, marks the stable prefix (tools + system) as
    # cacheable via Anthropic's ephemeral prompt cache. Cache reads are ~10% of
    # normal token cost. The key string itself is unused on the wire (Anthropic
    # keys by prefix content) — it's a caller-side label so the same prefix is
    # reused intentionally. Cache lifetime is 5 min, refreshed on each hit;
    # prefixes under the model's minimum cacheable size (~1024 tokens for
    # opus/sonnet) silently skip caching.
    def tool_call(system:, user:, tool:, max_tokens: DEFAULT_MAX_TOKENS, cache_key: nil)
      body = {
        model: @model,
        max_tokens: max_tokens,
        system: cache_key ? [ { type: "text", text: system, cache_control: { type: "ephemeral" } } ] : system,
        messages: [ { role: "user", content: user } ],
        tools: [ tool ],
        tool_choice: { type: "tool", name: tool[:name] }
      }

      response = conn.post("/v1/messages", body)
      unless response.success?
        raise Anthropic::Error, "Anthropic messages request failed (#{response.status}): #{response.body}"
      end

      block = Array(response.body["content"]).find { |c| c["type"] == "tool_use" }
      raise Anthropic::Error, "no tool_use block in response: #{response.body}" unless block
      block["input"] || {}
    end

    private

    def conn
      @connection ||= Anthropic::ClientFactory.connection
    end
  end
end
