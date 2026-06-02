require "test_helper"

module Mapping
  class LlmAdjudicatorTest < ActiveSupport::TestCase
    # Returns a fixed tool result, records the prompts it was handed.
    class FakeClient
      attr_reader :calls
      def initialize(result); @result = result; @calls = []; end
      def available? = true
      def tool_call(system:, user:, tool:, cache_key: nil)
        @calls << { system: system, user: user, tool: tool, cache_key: cache_key }
        @result
      end
    end

    setup do
      @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
      @sobject = Sobject.create!(extraction_run: @run, api_name: "sfsrm__Transaction__c", label: "Transaction")
      @sfield = Sfield.create!(sobject: @sobject, api_name: "Amount_Outstanding__c", data_type: "currency", sensitivity: "safe", raw_describe: {})
      @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: {
        "classes" => [ { "class_name" => "Invoice", "columns" => [
          { "name" => "balance_due_cents", "type" => "integer" },
          { "name" => "original_amount_cents", "type" => "integer" },
          { "name" => "invoice_number", "type" => "string" }
        ], "associations" => [] } ]
      })
    end

    def proposal(target_field, score: 0.1)
      MappingProposal.create!(source_field: @sfield, cashline_snapshot: @snapshot, target_class: "Invoice",
        target_field: target_field, score: score, state: "open",
        signals: { "lexical" => 0.1, "type" => false, "picklist" => 0.0 })
    end

    test "adjudicate boosts the chosen candidate above the rest and records the rationale" do
      %w[balance_due_cents original_amount_cents invoice_number].each { |f| proposal(f) }
      client = FakeClient.new({ "target_id" => "0", "confidence" => 0.9, "rationale" => "outstanding balance maps to balance_due", "evidence" => [ "type", "role" ] })

      assert LlmAdjudicator.new(snapshot: @snapshot, client: client).adjudicate(@sfield)

      props = MappingProposal.where(source_field: @sfield).to_a
      chosen = props.select { |p| p.signals["llm"].to_f > 0 }
      assert_equal 1, chosen.size, "exactly one candidate should be chosen"
      assert_equal 0.9, chosen.first.signals["llm"]
      assert_equal "outstanding balance maps to balance_due", chosen.first.signals["llm_rationale"]
      assert chosen.first.score > props.reject { |p| p == chosen.first }.map(&:score).max, "chosen must rerank above the rest"
    end

    test "NO_MATCH leaves every candidate with a zero llm signal and no rationale" do
      proposal("balance_due_cents")
      client = FakeClient.new({ "target_id" => "NO_MATCH", "confidence" => 0.0, "rationale" => "no fit" })

      LlmAdjudicator.new(snapshot: @snapshot, client: client).adjudicate(@sfield)

      p = MappingProposal.find_by(source_field: @sfield)
      assert_equal 0.0, p.signals["llm"].to_f
      assert_nil p.signals["llm_rationale"]
    end

    test "adjudicate still runs with no candidates and records a note + disposition" do
      client = FakeClient.new({ "target_id" => "NO_MATCH", "confidence" => 0.0, "rationale" => "no fit",
                                "role_note" => "Outstanding balance on the transaction.", "disposition" => "need_in_cashline" })
      assert LlmAdjudicator.new(snapshot: @snapshot, client: client).adjudicate(@sfield)
      assert_equal 1, client.calls.size

      fa = FieldAssessment.find_by(sfield_id: @sfield.id, cashline_snapshot_id: @snapshot.id)
      assert_equal "need_in_cashline", fa.disposition
      assert_equal "Outstanding balance on the transaction.", fa.role_note
    end

    test "adjudicate records a keep disposition + role note alongside the match" do
      proposal("balance_due_cents")
      client = FakeClient.new({ "target_id" => "0", "confidence" => 0.95, "rationale" => "balance",
                                "role_note" => "Remaining amount owed.", "disposition" => "keep" })
      LlmAdjudicator.new(snapshot: @snapshot, client: client).adjudicate(@sfield)

      fa = FieldAssessment.find_by(sfield_id: @sfield.id, cashline_snapshot_id: @snapshot.id)
      assert_equal "keep", fa.disposition
      assert_equal "Remaining amount owed.", fa.role_note
    end

    test "the candidate list and source dossier are included in the prompt" do
      proposal("balance_due_cents")
      client = FakeClient.new({ "target_id" => "0", "confidence" => 0.5, "rationale" => "x" })
      LlmAdjudicator.new(snapshot: @snapshot, client: client).adjudicate(@sfield)

      user = client.calls.first[:user]
      assert_includes user, "Amount_Outstanding__c"
      assert_includes user, "Invoice.balance_due_cents"
      assert_includes user, "candidate 0"
    end
  end
end
