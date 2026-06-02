require "test_helper"

class Openai::ChatTest < ActiveSupport::TestCase
  class FakeResp
    def initialize(ok, status, body) = (@ok, @status, @body = ok, status, body)
    def success? = @ok
    def status = @status
    def body = @body
  end

  class FakeConn
    attr_reader :last_body
    def initialize(response); @response = response; end
    def post(_path, body); @last_body = body; @response; end
  end

  TOOL = { name: "record_match", description: "d", input_schema: { type: "object", properties: {} } }.freeze
  RESPONSE_BODY = { "choices" => [ { "message" => { "tool_calls" => [ { "function" => { "name" => "record_match", "arguments" => "{}" } } ] } } ] }.freeze

  test "tool_call omits prompt_cache_key when cache_key is nil" do
    conn = FakeConn.new(FakeResp.new(true, 200, RESPONSE_BODY))
    Openai::Chat.new(connection: conn).tool_call(system: "s", user: "u", tool: TOOL)

    assert_not conn.last_body.key?(:prompt_cache_key)
  end

  test "tool_call forwards cache_key as prompt_cache_key" do
    conn = FakeConn.new(FakeResp.new(true, 200, RESPONSE_BODY))
    Openai::Chat.new(connection: conn).tool_call(system: "s", user: "u", tool: TOOL, cache_key: "mapping/adjudicator/v1")

    assert_equal "mapping/adjudicator/v1", conn.last_body[:prompt_cache_key]
  end
end
