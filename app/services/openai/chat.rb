module Openai
  # Thin /v1/chat/completions client used for the cheap first-tier field
  # assessment. Exposes the SAME interface as Anthropic::Messages#tool_call so
  # Mapping::LlmAdjudicator can run against either provider — the tool hash
  # (Anthropic-style: name/description/input_schema) is translated to OpenAI
  # function-calling here, and the forced function's arguments are returned.
  class Chat
    DEFAULT_MODEL = "gpt-4o-mini".freeze

    def initialize(connection: nil, model: DEFAULT_MODEL)
      @connection = connection
      @model = model
    end

    attr_reader :model

    def available?
      Openai::ClientFactory.configured?
    end

    def tool_call(system:, user:, tool:)
      body = {
        model: @model,
        messages: [ { role: "system", content: system }, { role: "user", content: user } ],
        tools: [ { type: "function", function: { name: tool[:name], description: tool[:description], parameters: tool[:input_schema] } } ],
        tool_choice: { type: "function", function: { name: tool[:name] } }
      }

      response = conn.post("/v1/chat/completions", body)
      unless response.success?
        raise Openai::Error, "OpenAI chat request failed (#{response.status}): #{response.body}"
      end

      arguments = response.body.dig("choices", 0, "message", "tool_calls", 0, "function", "arguments")
      raise Openai::Error, "no tool call in response: #{response.body}" if arguments.nil?

      JSON.parse(arguments)
    rescue JSON::ParserError => e
      raise Openai::Error, "could not parse tool arguments: #{e.message}"
    end

    private

    def conn
      @connection ||= Openai::ClientFactory.connection
    end
  end
end
