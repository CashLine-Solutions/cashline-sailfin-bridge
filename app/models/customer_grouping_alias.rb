# A durable operator decision that one detected parent label is the same
# customer as another — e.g. "CB RICHARD ELLIS" is "CBRE" (a rebrand no string
# rule catches). The detector folds aliased candidates into the canonical
# grouping on every run, so a manual merge survives re-detection.
class CustomerGroupingAlias < ApplicationRecord
  belongs_to :extraction_run

  validates :alias_normalized, :absorbed_display_name, :canonical_parent_name, presence: true

  scope :for_run, ->(run_id) { where(extraction_run_id: run_id) }

  # normalize(absorbed parent label) => canonical_parent_name, for the detector.
  def self.map_for(run_id)
    for_run(run_id).pluck(:alias_normalized, :canonical_parent_name).to_h
  end
end
