# One mapping *edge* — a Sailfin source field pointed at (or deliberately not
# pointed at) a cashline target field, within a given snapshot. The grid is one
# row per edge. See the plan's Key Technical Decisions for the lifecycle.
#
# Row shapes:
#   - direct/value_collapse/derived: source + target set
#   - split: several targeted rows sharing one source_field_id
#   - dropped: source set, decided not to map
#   - net_new: target set, source_field_id NULL (cashline field with no source)
#   - reviewed-no-home: source set, target NULL, reviewed=true (the gap signal)
class MappingEntry < ApplicationRecord
  MAPPING_TYPES = %w[direct value_collapse split derived dropped net_new].freeze
  CONFIDENCES = %w[low medium high].freeze

  belongs_to :cashline_snapshot
  belongs_to :source_field, class_name: "Sfield", optional: true
  belongs_to :updated_by, class_name: "User", optional: true
  has_many :mapping_value_entries, dependent: :destroy

  validates :mapping_type, inclusion: { in: MAPPING_TYPES }, allow_nil: true
  validates :confidence, inclusion: { in: CONFIDENCES }, allow_blank: true
  validate :target_class_and_field_together
  validate :source_presence_matches_net_new

  after_destroy :demote_lone_split_sibling

  scope :for_session, ->(snapshot_id) { where(cashline_snapshot_id: snapshot_id) }
  scope :net_new, -> { where(mapping_type: "net_new") }
  scope :targeted, -> { where.not(target_class: nil) }

  # Find-or-create the edge for a uniqueness key, then apply attributes.
  # Owns the concurrency handling so the controller doesn't have to:
  # find_or_create_by is not atomic against the unique index, so a concurrent
  # first-write can raise RecordNotUnique — we retry, and the second pass finds
  # the row the racing request created.
  def self.upsert_edge(cashline_snapshot:, source_field:, target_class: nil, target_field: nil, attributes: {})
    key = {
      cashline_snapshot_id: cashline_snapshot.id,
      source_field_id: source_field&.id,
      target_class: target_class.presence,
      target_field: target_field.presence
    }
    retries = 0
    begin
      entry = find_or_create_by!(key)
      entry.update!(attributes) if attributes.present?
      entry
    rescue ActiveRecord::RecordNotUnique
      retries += 1
      retry if retries <= 2
      raise
    end
  end

  def net_new?
    mapping_type == "net_new"
  end

  def reviewed_no_home?
    reviewed? && target_class.blank? && !net_new?
  end

  # Sibling edges of a 1:N split: other targeted rows sharing this source.
  # Excludes the null-target reviewed-no-home row so it never counts as a leg.
  def split_siblings
    return self.class.none if source_field_id.nil?
    self.class
      .where(cashline_snapshot_id: cashline_snapshot_id, source_field_id: source_field_id)
      .where.not(id: id)
      .targeted
  end

  # How many other sources also claim this exact target (the N:1 indicator).
  def also_mapped_from_count
    return 0 if target_class.blank?
    self.class
      .where(cashline_snapshot_id: cashline_snapshot_id, target_class: target_class, target_field: target_field)
      .where.not(id: id)
      .count
  end

  private

  # When a split leg is removed and exactly one targeted row survives for that
  # source, demote the lone survivor back to `direct`. Never touches the
  # null-target reviewed-no-home row (it's excluded by `targeted`).
  def demote_lone_split_sibling
    return if source_field_id.nil?
    survivors = self.class
      .where(cashline_snapshot_id: cashline_snapshot_id, source_field_id: source_field_id)
      .targeted
    return unless survivors.count == 1
    lone = survivors.first
    lone.update!(mapping_type: "direct") if lone.mapping_type == "split"
  end

  def target_class_and_field_together
    return if target_class.blank? == target_field.blank?
    errors.add(:target_field, "and target_class must be set together")
  end

  def source_presence_matches_net_new
    if net_new? && source_field_id.present?
      errors.add(:source_field, "must be empty for a net_new mapping")
    elsif source_field_id.nil? && !net_new?
      errors.add(:source_field, "is required unless the mapping is net_new")
    end
  end
end
