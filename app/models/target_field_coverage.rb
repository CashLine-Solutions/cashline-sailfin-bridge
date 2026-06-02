# One row in the "Cashline coverage" view — what's filling (or not filling)
# a single cashline column. Inverts the mapping data: we walk every column
# in the snapshot and aggregate the MappingEntries + open MappingProposals
# that target it.
#
# Built by ResolutionsController#by_target. Read-only.
TargetFieldCoverage = Data.define(:target_class, :target_field, :column_type, :entries, :open_proposals) do
  def initialize(target_class:, target_field:, column_type: nil, entries: [], open_proposals: [])
    super
  end

  def label
    "#{target_class}.#{target_field}"
  end

  # Committed mapping rows pointing at this column. A `net_new` entry counts
  # as a deliberate "no source needed" — handled separately from `filled`.
  # No memoization: Data.define instances are frozen, and per-row work is cheap.
  def committed_entries
    entries.reject { |e| e.mapping_type == "net_new" }
  end

  def net_new_entries
    entries.select { |e| e.mapping_type == "net_new" }
  end

  # Top-N LLM-picked proposals that nothing has committed to yet. Suppressed
  # disambiguation losers and zero-llm heuristics are filtered out.
  def visible_candidates
    open_proposals
      .reject { |p| p.signals && p.signals["disambig_suppressed"] }
      .select { |p| p.signals && p.signals["llm"].to_f > 0 }
      .sort_by { |p| -p.signals["llm"].to_f }
  end

  # FILLED      — at least one source is committed
  # CONTENDED   — multiple committed sources (a real N:1 collapse waiting on a call)
  # CANDIDATE   — no commitment yet, but the LLM proposed at least one source
  # UNTOUCHED   — no commitment, no proposal — nothing's looked at this column
  # NET-NEW     — intentionally no source (a cashline-only column)
  def status
    return "net_new"   if committed_entries.empty? && net_new_entries.any?
    return "contended" if committed_entries.size > 1
    return "filled"    if committed_entries.size == 1
    return "candidate" if visible_candidates.any?
    "untouched"
  end

  def status_label
    case status
    when "filled"    then "Filled"
    when "contended" then "Contended"
    when "candidate" then "Candidate"
    when "net_new"   then "Net-new"
    when "untouched" then "Untouched"
    end
  end

  def status_color
    case status
    when "filled"    then "emerald"
    when "contended" then "rose"
    when "candidate" then "yellow"
    when "net_new"   then "sky"
    when "untouched" then "slate"
    end
  end

  # "Fed by" chips for the row. Either committed sources or LLM-picked
  # candidates, depending on status.
  def feeders
    if committed_entries.any?
      committed_entries.map { |e| source_chip_from_entry(e) }.compact.uniq
    else
      visible_candidates.first(3).map { |p| source_chip_from_proposal(p) }
    end
  end

  def feeder_count
    committed_entries.any? ? committed_entries.size : visible_candidates.size
  end

  def needs_attention?
    %w[contended candidate].include?(status)
  end

  # Sort key: contended first (collisions waiting on a call), then candidate
  # (low-friction commits available), untouched (gaps), filled (done),
  # net_new (informational) last.
  def sort_priority
    case status
    when "contended" then 0
    when "candidate" then 1
    when "untouched" then 2
    when "filled"    then 3
    when "net_new"   then 4
    end
  end

  def dom_id
    "tgt_cov_#{target_class.parameterize}_#{target_field}"
  end

  private

  def source_chip_from_entry(entry)
    return nil if entry.source_field_id.nil?
    sf = entry.source_field
    return nil if sf.nil?
    "#{sf.sobject.api_name}.#{sf.api_name}"
  end

  def source_chip_from_proposal(proposal)
    sf = proposal.source_field
    "#{sf.sobject.api_name}.#{sf.api_name}"
  end
end

TargetFieldCoverage::STATUSES = %w[filled contended candidate untouched net_new].freeze

