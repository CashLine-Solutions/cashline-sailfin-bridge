require "test_helper"

class ComputeMappingProposalsJobTest < ActiveSupport::TestCase
  def schema
    {
      "classes" => [
        { "class_name" => "Invoice", "namespace" => nil, "columns" => [
          { "name" => "invoice_number", "type" => "string" },
          { "name" => "status", "type" => "integer", "enum_values" => { "draft" => 0 } }
        ] }
      ]
    }
  end

  setup do
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: schema)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
    @field = Sfield.create!(sobject: @sobject, api_name: "Invoice_Number__c", data_type: "string")
  end

  test "terminal state: proposals are persisted for the run's fields" do
    ComputeMappingProposalsJob.perform_now(@run.id, @snapshot.id)
    proposal = MappingProposal.find_by(cashline_snapshot_id: @snapshot.id, source_field_id: @field.id, target_field: "invoice_number")
    assert proposal, "expected an open proposal for the lexically matching target"
    assert_equal "open", proposal.state
  end

  test "a per-field matcher failure is recorded as a partial failure, not a crash" do
    raising = Class.new(ComputeMappingProposalsJob) do
      def build_matcher(_snapshot)
        Class.new { def candidates_for(_f) = raise("boom") }.new
      end
    end
    raising.perform_now(@run.id, @snapshot.id)
    assert @run.reload.partial_failures.any? { |f| f["reason"] == "boom" }
  end

  test "a rejected (source, target) is NOT re-emitted as open after a re-snapshot recompute" do
    MappingProposal.create!(source_field: @field, cashline_snapshot: @snapshot,
      target_class: "Invoice", target_field: "invoice_number", score: 1.5, state: "rejected")

    snapshot2 = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s2", schema_json: schema)
    ComputeMappingProposalsJob.perform_now(@run.id, snapshot2.id)

    refute MappingProposal.open.where(cashline_snapshot_id: snapshot2.id, source_field_id: @field.id,
      target_class: "Invoice", target_field: "invoice_number").exists?,
      "a rejection must survive re-snapshot and suppress the resurrected suggestion"
  end

  test "recompute replaces stale open proposals but preserves accepted ones" do
    accepted = MappingProposal.create!(source_field: @field, cashline_snapshot: @snapshot,
      target_class: "Invoice", target_field: "invoice_number", score: 1.5, state: "accepted")
    stale_open = MappingProposal.create!(source_field: @field, cashline_snapshot: @snapshot,
      target_class: "Invoice", target_field: "status", score: 0.2, state: "open")

    ComputeMappingProposalsJob.perform_now(@run.id, @snapshot.id)

    assert MappingProposal.exists?(accepted.id), "accepted proposals are preserved"
    refute MappingProposal.exists?(stale_open.id), "stale open proposals are replaced"
  end
end
