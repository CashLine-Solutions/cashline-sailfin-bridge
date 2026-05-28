# One edge row in the mapping grid. Wraps either:
#   - a persisted MappingEntry for a Sailfin field (entry + sfield present)
#   - a synthetic, never-touched Sailfin field (entry nil)
#   - a net_new cashline target with no Sailfin source (sfield nil)
# Built by MappingsController#index; rendered by mappings/_row.
MappingGridRow = Data.define(:sfield, :entry, :data_group, :field_profile) do
  # net_new rows sort to a pinned "(no source)" group at the bottom — an
  # explicit high sentinel, not alphabetical on a blank Data Group.
  NET_NEW_SORT_GROUP = "￿(no source)".freeze

  def synthetic?
    entry.nil?
  end

  def net_new?
    sfield.nil?
  end

  def reviewed?
    entry&.reviewed? || false
  end

  # A reviewed row with no target is the gap-discovery signal.
  def reviewed_no_home?
    entry&.reviewed_no_home? || false
  end

  def mapping_type
    entry&.mapping_type
  end

  def mapped?
    target_label.present?
  end

  def needs_crosswalk?
    entry&.needs_crosswalk || false
  end

  # Fraction of rows that are non-null (1 - null_rate), or nil if unprofiled.
  def population
    return nil unless field_profile&.null_rate
    1 - field_profile.null_rate
  end

  def high_population?(threshold = 0.5)
    population.present? && population >= threshold
  end

  # The gap-discovery signal: a Sailfin field a reviewer looked at, found no
  # cashline home for, that nonetheless carries real data. NOT raw "unmapped"
  # (every field starts unmapped).
  def gap?(threshold = 0.5)
    reviewed? && !mapped? && !net_new? && high_population?(threshold)
  end

  def confidence
    entry&.confidence
  end

  def target_label
    return nil if entry&.target_class.blank?
    "#{entry.target_class}##{entry.target_field}"
  end

  def data_group_label
    net_new? ? "(no source)" : (data_group.presence || "Unclustered")
  end

  # Sort key for the Data Group cell; pins net_new to the bottom client-side.
  def data_group_sort_value
    net_new? ? NET_NEW_SORT_GROUP : data_group_label
  end

  def sobject_name
    sfield&.sobject&.api_name
  end

  def field_name
    sfield&.api_name
  end

  def dom_id
    if net_new?
      "mapping_net_new_#{entry.id}"
    elsif entry
      "mapping_entry_#{entry.id}"
    else
      "mapping_synthetic_#{sfield.id}"
    end
  end

  # Server-render order: data group, object, field, then target; net_new last.
  def sort_key
    [ net_new? ? 1 : 0, data_group_sort_value, sobject_name.to_s, field_name.to_s, target_label.to_s ]
  end
end
