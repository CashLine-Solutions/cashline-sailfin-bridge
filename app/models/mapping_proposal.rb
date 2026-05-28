# A heuristic/embedding-suggested candidate target for a Sailfin source field.
# Surfaced as the grid's one-click "suggest" button. User-facing UI says
# "suggestion"; the data model says "proposal" (intentional layer split).
#
# Rejections are keyed by (source_field_id, target_class, target_field)
# *independent of snapshot* so a re-snapshot doesn't resurrect a rejected
# suggestion — the recompute job filters candidates against #rejected? before
# persisting state: "open".
class MappingProposal < ApplicationRecord
  STATES = %w[open accepted rejected].freeze

  belongs_to :source_field, class_name: "Sfield"
  belongs_to :cashline_snapshot

  validates :target_class, :target_field, presence: true
  validates :state, inclusion: { in: STATES }

  scope :open, -> { where(state: "open") }
  scope :rejected, -> { where(state: "rejected") }
  scope :for_session, ->(snapshot_id) { where(cashline_snapshot_id: snapshot_id) }

  # Snapshot-independent: has this exact (source → target) edge been rejected in
  # ANY snapshot? Used by the recompute job to suppress resurrected suggestions.
  def self.rejected?(source_field_id:, target_class:, target_field:)
    rejected.where(source_field_id: source_field_id, target_class: target_class, target_field: target_field).exists?
  end

  def target_label
    "#{target_class}##{target_field}"
  end
end
