# A candidate (and then human-confirmed) roll-up of multiple Sailfin Accounts
# under one parent customer. Detected from Account naming/structural signals,
# reviewed by an operator, and eventually applied by the importer as a customer
# org/group overlay. User-facing UI says "grouping"; state mirrors
# MappingProposal (open → confirmed/rejected) so re-detection never resurrects a
# question the operator already answered.
class CustomerGrouping < ApplicationRecord
  STATES = %w[open confirmed rejected].freeze

  belongs_to :extraction_run
  has_many :members, class_name: "CustomerGroupingMember", dependent: :destroy

  validates :parent_name, :detection_method, presence: true
  validates :state, inclusion: { in: STATES }
  validates :confidence, inclusion: { in: %w[high medium low] }

  scope :open, -> { where(state: "open") }
  scope :confirmed, -> { where(state: "confirmed") }
  scope :rejected, -> { where(state: "rejected") }
  scope :for_run, ->(run_id) { where(extraction_run_id: run_id) }
  scope :rolled_up, -> { where.not(customer_name: nil) }

  # Default group label when rolling this grouping up under +customer_name+: the
  # grouping's own name with the customer prefix and leading separators stripped
  # ("KINDER MORGAN / NGPL" under "KINDER MORGAN" -> "NGPL"). Blank when the
  # grouping *is* the customer (bare "KINDER MORGAN" -> nil), which the importer
  # reads as "fall back to the account-name suffix, else Main".
  def self.derive_group_label(parent_name, customer_name)
    label = parent_name.to_s
    label = label.sub(/\A#{Regexp.escape(customer_name.to_s)}/i, "") if customer_name.present?
    label.sub(%r{\A[\s/,\-:]+}, "").squish.presence
  end

  # True once this grouping has been nested under a higher-level customer.
  def rolled_up? = customer_name.present?

  # The customer org this grouping's accounts land in (itself, until rolled up).
  def customer_org = customer_name.presence || parent_name

  def member_count
    members.size
  end

  # Other detected parent labels an operator has merged into this grouping
  # (e.g. "CB RICHARD ELLIS" merged into "CBRE"). Keyed by parent_name so it
  # survives re-detection, which rebuilds grouping rows from scratch.
  def merged_aliases
    CustomerGroupingAlias.for_run(extraction_run_id).where(canonical_parent_name: parent_name)
  end
end
