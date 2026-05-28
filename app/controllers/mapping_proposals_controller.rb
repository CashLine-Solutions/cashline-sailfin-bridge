# Accept / reject / restore heuristic suggestions. Accepting persists the edge
# immediately (via upsert_edge) — it does not merely pre-fill a typeahead.
class MappingProposalsController < ApplicationController
  before_action :load_proposal
  after_action :verify_authorized

  def accept
    authorize MappingEntry, :create?, policy_class: MappingEntryPolicy
    MappingEntry.upsert_edge(
      cashline_snapshot: @proposal.cashline_snapshot,
      source_field: @proposal.source_field,
      target_class: @proposal.target_class,
      target_field: @proposal.target_field,
      attributes: { mapping_type: "direct", confidence: score_to_confidence(@proposal.score), updated_by: Current.user }
    )
    @proposal.update!(state: "accepted")
    redirect_to mappings_path, notice: "Applied suggestion #{@proposal.target_label}."
  end

  def reject
    authorize MappingEntry, :create?, policy_class: MappingEntryPolicy
    @proposal.update!(state: "rejected")
    redirect_to mappings_path, notice: "Suppressed suggestion #{@proposal.target_label}."
  end

  def unreject
    authorize MappingEntry, :create?, policy_class: MappingEntryPolicy
    @proposal.update!(state: "open")
    redirect_to mappings_path, notice: "Restored suggestion #{@proposal.target_label}."
  end

  private

  def load_proposal
    @proposal = MappingProposal.find(params[:id])
  end

  def score_to_confidence(score)
    return "high" if score >= 1.0
    return "medium" if score >= 0.5
    "low"
  end
end
