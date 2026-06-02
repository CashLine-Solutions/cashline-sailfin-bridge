# One row in the "Sailfin field fate" view — what's happening to a single
# source field. Wraps Sfield + FieldAssessment + committed MappingEntries
# (+ open proposals as a fallback target hint when no entry is committed).
#
# Built by ResolutionsController#by_source. Read-only; the existing mappings
# grid remains the edit surface.
SourceFieldResolution = Data.define(:sfield, :assessment, :entries, :open_proposals, :field_profile, :data_group) do
  def initialize(sfield:, assessment: nil, entries: [], open_proposals: [], field_profile: nil, data_group: nil)
    super
  end

  def sobject_name
    sfield.sobject.api_name
  end

  def field_name
    sfield.api_name
  end

  def label
    sfield.label.presence
  end

  def role_note
    assessment&.role_note.presence
  end

  def disposition
    assessment&.disposition.presence || (entries.any? ? "keep" : nil)
  end

  def disposition_label
    case disposition
    when "keep"             then "Keep"
    when "need_in_cashline" then "Need in cashline"
    when "sync_reference"   then "Sailfin sync"
    when "discard"          then "Discard"
    else                         "Unreviewed"
    end
  end

  def disposition_color
    case disposition
    when "keep"             then "emerald"
    when "need_in_cashline" then "amber"
    when "sync_reference"   then "indigo"
    when "discard"          then "slate"
    else                         "slate"
    end
  end

  # The resolution shape — derived from committed entries first, then
  # disposition when nothing's committed. Drives the badge in the UI.
  def shape
    return "drop"           if disposition == "discard"   && entries.empty?
    return "sync-ref"       if disposition == "sync_reference"
    return "gap"            if disposition == "need_in_cashline"
    return "unreviewed"     if disposition.nil?           && entries.empty?

    targeted = entries.reject { |e| e.target_class.blank? }
    return "drop"           if targeted.empty? && disposition == "discard"
    return "candidate"      if targeted.empty? && suggested_targets.any?
    return "unmapped"       if targeted.empty?

    types = targeted.map(&:mapping_type).compact.uniq
    return "value-collapse" if types.include?("value_collapse")
    return "derived"        if types.include?("derived")
    return "split"          if targeted.size > 1 || types.include?("split")
    "direct"
  end

  def shape_color
    case shape
    when "direct"         then "emerald"
    when "split"          then "violet"
    when "value-collapse" then "cyan"
    when "derived"        then "sky"
    when "sync-ref"       then "indigo"
    when "gap"            then "amber"
    when "drop"           then "slate"
    when "candidate"      then "yellow"
    else                       "slate"
    end
  end

  # Committed targets, as "Class.field" strings.
  def resolved_targets
    entries.reject { |e| e.target_class.blank? }
      .map { |e| "#{e.target_class}.#{e.target_field}" }
      .uniq
  end

  # When no entry is committed, surface the LLM-picked open proposal(s) so
  # the user sees what the suggestion was without leaving the row.
  def suggested_targets
    open_proposals
      .reject { |p| p.signals && p.signals["disambig_suppressed"] }
      .select { |p| p.signals && p.signals["llm"].to_f > 0 }
      .sort_by { |p| -p.signals["llm"].to_f }
      .first(2)
      .map { |p| "#{p.target_class}.#{p.target_field}" }
  end

  # Either the committed targets or the top-LLM-suggested ones.
  def target_chips
    resolved_targets.any? ? resolved_targets : suggested_targets
  end

  def population
    return nil unless field_profile&.null_rate
    1 - field_profile.null_rate
  end

  def confidence
    assessment&.confidence
  end

  def model
    assessment&.model.to_s.sub("claude-opus-4-7", "opus").sub("gpt-4o-mini", "mini").presence
  end

  def reviewed?
    entries.any?(&:reviewed?)
  end

  # Attention score — what the user should look at next. Unreviewed +
  # high-population + has a candidate but no commitment = highest signal.
  # Reviewed fields fall to the bottom; pure discards even lower.
  def attention
    return 0 if disposition == "discard"
    pop = population || 0.0
    base = 100.0 * pop
    base += 30 if disposition == "need_in_cashline" # gaps to design
    base += 20 if !reviewed? && target_chips.any?   # has suggestion, not yet committed
    base += 10 if disposition == "sync_reference"   # needs a sailfin_ column
    base
  end

  def synthetic?
    entries.empty?
  end

  def dom_id
    "src_res_#{sfield.id}"
  end

  # Mapping-grid deep link — jumps to the existing edit surface.
  def edit_url_params(snapshot_id)
    { snapshot: snapshot_id, anchor: "mapping_synthetic_#{sfield.id}" }
  end
end
