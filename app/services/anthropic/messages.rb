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
    def tool_call(system:, user:, tool:, max_tokens: DEFAULT_MAX_TOKENS)
      body = {
        model: @model,
        max_tokens: max_tokens,
        system: system,
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
