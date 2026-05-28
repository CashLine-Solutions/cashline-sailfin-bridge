require "faraday"

module Openai
  # Thin Faraday client for the one OpenAI endpoint this app uses (embeddings).
  # Modeled on Salesforce::ClientFactory — no new gem (faraday is already a
  # dependency), credentials in Rails.application.credentials.openai.
  module ClientFactory
    extend self

    API_BASE = "https://api.openai.com".freeze

    def configured?
      credentials[:api_key].to_s.strip.present?
    end

    def validate_credentials!
      return if configured?
      raise ConfigurationError,
            "OpenAI credentials not configured (missing api_key). " \
            "Run `bin/rails credentials:edit` and add:\n  openai:\n    api_key: sk-...\n" \
            "Embeddings degrade to heuristic-only until this is set."
    end

    def connection
      validate_credentials!
      Faraday.new(url: API_BASE) do |f|
        f.request :json
        f.response :json
        f.headers["Authorization"] = "Bearer #{credentials.fetch(:api_key)}"
        f.headers["OpenAI-Organization"] = credentials[:organization] if credentials[:organization].present?
        f.options.timeout = 30
        f.options.open_timeout = 10
      end
    end

    private

    def credentials
      Rails.application.credentials.openai || {}
    end
  end
end
