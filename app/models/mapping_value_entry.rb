# A picklist value-level mapping: one source picklist value mapped to a target
# enum value (or a drop/derive sentinel) under a parent MappingEntry.
class MappingValueEntry < ApplicationRecord
  DROP = "__drop__".freeze
  DERIVE = "__derive__".freeze
  SENTINELS = [ DROP, DERIVE ].freeze

  belongs_to :mapping_entry

  validates :source_value, presence: true
  validates :source_value, uniqueness: { scope: :mapping_entry_id }

  def dropped?
    target_enum_value == DROP
  end

  def derived?
    target_enum_value == DERIVE
  end

  def sentinel?
    SENTINELS.include?(target_enum_value)
  end
end
