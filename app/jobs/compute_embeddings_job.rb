# Adds embedding-based candidates to the mapping proposals for a (run, snapshot).
# Runs after the heuristic pass (Unit 9). Degrades to a no-op when OpenAI isn't
# configured or the API is unavailable — the heuristic proposals stand.
class ComputeEmbeddingsJob < ApplicationJob
  queue_as :default

  if respond_to?(:good_job_control_concurrency_with)
    good_job_control_concurrency_with(
      total_limit: 1,
      key: -> { "compute_embeddings:#{arguments.first}:#{arguments.second}" }
    )
  end

  def perform(extraction_run_id, cashline_snapshot_id)
    run = ExtractionRun.find(extraction_run_id)
    snapshot = CashlineSnapshot.find(cashline_snapshot_id)

    matcher = build_matcher(snapshot)
    return unless matcher.available? # no credentials → heuristic-only

    matcher.combine!(run)
  rescue Openai::Error, Faraday::Error => e
    # Graceful degradation: a transient OpenAI failure must not fail the grid.
    Rails.logger.warn("[ComputeEmbeddingsJob] degraded to heuristic-only: #{e.class}: #{e.message}")
  end

  private

  # Test seam — override to inject a fake embeddings client.
  def build_matcher(snapshot)
    Mapping::EmbeddingMatcher.new(snapshot: snapshot)
  end
end
