# The LLM enrichment verdict for one Sailfin field against one cashline snapshot:
# a generated functional-role note plus a keep/need/discard disposition. Distinct
# from MappingProposal (per candidate target) — this is the field-level summary
# that drives the grid's context-notes and disposition columns. Covers every
# field, including ones with no proposal.
class FieldAssessment < ApplicationRecord
  belongs_to :sfield
  belongs_to :cashline_snapshot

  # keep            — a real cashline domain field fits; map it there and use it.
  # need_in_cashline — a lasting business field that IS used in Sailfin but has no
  #                    cashline home; add a first-class field (incl. future
  #                    services). Unused fields are discard, not need.
  # sync_reference   — a Sailfin-specific id / source key / cross-reference kept
  #                    only to map+sync during migration. Stored as a `sailfin_`-
  #                    prefixed column, not adopted as a key, purged after sunset.
  # discard          — unused/vestigial; drop it.
  DISPOSITIONS = %w[keep need_in_cashline sync_reference discard].freeze

  validates :disposition, inclusion: { in: DISPOSITIONS }, allow_nil: true

  LABELS = {
    "keep" => "keep",
    "need_in_cashline" => "need in cashline",
    "sync_reference" => "sailfin sync",
    "discard" => "discard"
  }.freeze

  def disposition_label
    LABELS[disposition] || disposition
  end
end
