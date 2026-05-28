# Computes heuristic mapping proposals for every Sailfin field in a run against
# a cashline snapshot. One job per (run, snapshot); per-field failures are
# recorded as partial failures rather than aborting the whole pass.
class ComputeMappingProposalsJob < ApplicationJob
  queue_as :default

  if respond_to?(:good_job_control_concurrency_with)
    good_job_control_concurrency_with(
      total_limit: 1,
      key: -> { "compute_mapping_proposals:#{arguments.first}:#{arguments.second}" }
    )
  end

  def perform(extraction_run_id, cashline_snapshot_id)
    run = ExtractionRun.find(extraction_run_id)
    snapshot = CashlineSnapshot.find(cashline_snapshot_id)
    matcher = build_matcher(snapshot)

    source_fields(run).find_each do |sfield|
      compute_for_field(sfield, snapshot, matcher)
    rescue StandardError => e
      run.record_partial_failure!(object_api_name: "proposals:#{sfield.api_name}", reason: e.message)
    end

    # Additive embedding signal — only when OpenAI is configured; otherwise the
    # heuristic proposals above stand on their own.
    ComputeEmbeddingsJob.perform_later(run.id, snapshot.id) if Openai::ClientFactory.configured?
  end

  private

  # Test seam — override to inject a fake matcher.
  def build_matcher(snapshot)
    Mapping::HeuristicMatcher.new(snapshot: snapshot)
  end

  def source_fields(run)
    Sfield.joins(:sobject).where(sobjects: { extraction_run_id: run.id }).includes(:spicklist_values)
  end

  def compute_for_field(sfield, snapshot, matcher)
    # Replace this field's prior OPEN proposals for this snapshot; accepted and
    # rejected rows are preserved (and suppress re-emission below).
    MappingProposal.where(source_field_id: sfield.id, cashline_snapshot_id: snapshot.id, state: "open").delete_all

    matcher.candidates_for(sfield).each do |cand|
      tc = cand[:target_class]
      tf = cand[:target_field]
      # Snapshot-independent rejection survives a re-snapshot.
      next if MappingProposal.rejected?(source_field_id: sfield.id, target_class: tc, target_field: tf)
      # An accepted edge for this snapshot already occupies the unique key.
      next if MappingProposal.exists?(source_field_id: sfield.id, cashline_snapshot_id: snapshot.id, target_class: tc, target_field: tf)

      MappingProposal.create!(
        source_field_id: sfield.id, cashline_snapshot_id: snapshot.id,
        target_class: tc, target_field: tf,
        score: cand[:score], signals: cand[:signals], state: "open"
      )
    end
  end
end
