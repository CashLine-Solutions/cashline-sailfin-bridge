require "test_helper"

module Mapping
  class LlmDisambiguatorTest < ActiveSupport::TestCase
    class FakeClient
      attr_reader :calls
      def initialize(result); @result = result; @calls = []; end
      def available? = true
      def tool_call(system:, user:, tool:, cache_key: nil); @calls << user; @result; end
    end

    setup do
      @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
      @sobject = Sobject.create!(extraction_run: @run, api_name: "sfsrm__Transaction__c", label: "Transaction")
      @a = Sfield.create!(sobject: @sobject, api_name: "Amount_Outstanding__c", data_type: "currency", sensitivity: "safe", raw_describe: {})
      @b = Sfield.create!(sobject: @sobject, api_name: "Balance__c", data_type: "currency", sensitivity: "safe", raw_describe: {})
      @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: {
        "classes" => [ { "class_name" => "Invoice", "columns" => [ { "name" => "balance_due_cents", "type" => "integer" } ], "associations" => [] } ]
      })
      [ @a, @b ].each do |sf|
        MappingProposal.create!(source_field: sf, cashline_snapshot: @snapshot, target_class: "Invoice",
          target_field: "balance_due_cents", score: 2.0, state: "open", signals: { "llm" => 0.9 })
      end
    end

    test "resolve! suppresses the contested suggestion on all but the chosen source" do
      client = FakeClient.new({ "source_id" => "0", "rationale" => "best fit" })
      resolved = LlmDisambiguator.new(snapshot: @snapshot, client: client).resolve!(@run)

      assert_equal 1, resolved, "one contested target"
      props = MappingProposal.where(source_field_id: [ @a.id, @b.id ])
      suppressed = props.select { |p| p.signals["disambig_suppressed"] }
      kept = props.reject { |p| p.signals["disambig_suppressed"] }
      assert_equal 1, suppressed.size, "all but the winner suppressed"
      assert_equal 1, kept.size
    end

    test "resolve! does nothing when no target is contested" do
      MappingProposal.where(source_field_id: @b.id).update_all(target_field: "other_field")
      client = FakeClient.new({ "source_id" => "0" })
      assert_equal 0, LlmDisambiguator.new(snapshot: @snapshot, client: client).resolve!(@run)
      assert_empty client.calls
    end
  end
end
