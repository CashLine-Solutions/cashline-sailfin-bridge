require "test_helper"

module Anthropic
  class MessagesTest < ActiveSupport::TestCase
    class FakeResponse
      def initialize(success, status, body); @success = success; @status = status; @body = body; end
      def success? = @success
      attr_reader :status, :body
    end

    class FakeConn
      attr_reader :last_body
      def initialize(response); @response = response; end
      def post(_path, body); @last_body = body; @response; end
    end

    TOOL = { name: "record_match" }.freeze

    test "tool_call returns the tool_use input from a successful response" do
      body = { "content" => [
        { "type" => "text", "text" => "thinking" },
        { "type" => "tool_use", "name" => "record_match", "input" => { "target_id" => "2", "confidence" => 0.8 } }
      ] }
      conn = FakeConn.new(FakeResponse.new(true, 200, body))
      result = Messages.new(connection: conn).tool_call(system: "s", user: "u", tool: TOOL)

      assert_equal "2", result["target_id"]
      assert_equal 0.8, result["confidence"]
    end

    test "tool_call forces the tool and passes the model" do
      conn = FakeConn.new(FakeResponse.new(true, 200, { "content" => [ { "type" => "tool_use", "input" => {} } ] }))
      Messages.new(connection: conn, model: "claude-test").tool_call(system: "s", user: "u", tool: TOOL)

      assert_equal "claude-test", conn.last_body[:model]
      assert_equal({ type: "tool", name: "record_match" }, conn.last_body[:tool_choice])
    end

    test "tool_call passes system as plain string when cache_key is omitted" do
      conn = FakeConn.new(FakeResponse.new(true, 200, { "content" => [ { "type" => "tool_use", "input" => {} } ] }))
      Messages.new(connection: conn).tool_call(system: "stable instructions", user: "u", tool: TOOL)

      assert_equal "stable instructions", conn.last_body[:system]
    end

    test "tool_call wraps system in cache-controlled content block when cache_key is set" do
      conn = FakeConn.new(FakeResponse.new(true, 200, { "content" => [ { "type" => "tool_use", "input" => {} } ] }))
      Messages.new(connection: conn).tool_call(system: "stable instructions", user: "u", tool: TOOL, cache_key: "label")

      assert_equal [ { type: "text", text: "stable instructions", cache_control: { type: "ephemeral" } } ],
                   conn.last_body[:system]
    end

    test "tool_call raises on a non-success response" do
      conn = FakeConn.new(FakeResponse.new(false, 429, { "error" => "rate_limited" }))
      assert_raises(Anthropic::Error) { Messages.new(connection: conn).tool_call(system: "s", user: "u", tool: TOOL) }
    end

    test "tool_call raises when the response carries no tool_use block" do
      conn = FakeConn.new(FakeResponse.new(true, 200, { "content" => [ { "type" => "text", "text" => "no tool" } ] }))
      assert_raises(Anthropic::Error) { Messages.new(connection: conn).tool_call(system: "s", user: "u", tool: TOOL) }
    end
  end
end
