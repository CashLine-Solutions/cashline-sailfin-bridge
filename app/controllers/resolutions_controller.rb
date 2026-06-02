class ResolutionsController < ApplicationController
  include CurrentSnapshot

  # Authorization: these are read-only summaries derived from MappingEntry +
  # MappingProposal data the user can already see via /mappings. We rely on
  # the MappingEntry Pundit scope for any committed entries surfaced, and the
  # snapshot policy is gated by CurrentSnapshot. No write actions, so no
  # verify_authorized callback needed.

  # By-source view: one row per Sailfin field, showing its fate (disposition
  # + resolved targets + role note + attention score). The Sailfin-side answer
  # to "what's happening to each of my fields?"
  def by_source
    @run = current_run
    @snapshot = current_snapshot
    return render_empty_state if @run.nil?

    sfields = Sfield.joins(:sobject)
      .where(sobjects: { extraction_run_id: @run.id })
      .includes(:sobject, :spicklist_values)
      .to_a

    assessments  = assessments_by_sfield_id(@snapshot, sfields)
    entries      = entries_by_sfield_id(@snapshot, sfields)
    proposals    = proposals_by_sfield_id(@snapshot, sfields)
    profiles     = profiles_by_sfield_id(@run, sfields)
    data_groups  = data_groups_by_sfield_id(@run, sfields)

    @rows = sfields.map do |sf|
      SourceFieldResolution.new(
        sfield: sf,
        assessment: assessments[sf.id],
        entries: entries[sf.id] || [],
        open_proposals: proposals[sf.id] || [],
        field_profile: profiles[sf.id],
        data_group: data_groups[sf.id]
      )
    end

    @total_count        = @rows.size
    @disposition_counts = compute_disposition_counts(@rows)
    @rows               = apply_source_filters(@rows)
    @rows               = sort_source_rows(@rows)

    @sobject_options    = sfields.map { |sf| sf.sobject.api_name }.uniq.sort
  end

  # By-target view: one row per cashline column, showing what feeds it
  # (status + sources). The cashline-side answer to "what do I need to do
  # with each of my fields?"
  def by_target
    @run = current_run
    @snapshot = current_snapshot
    return render_empty_state if @snapshot.nil?

    columns = snapshot_columns(@snapshot)
    entries_by_target = entries_by_target_key(@snapshot)
    proposals_by_target = proposals_by_target_key(@snapshot, @run)

    @rows = columns.map do |target_class, target_field, column_type|
      key = [ target_class, target_field ]
      TargetFieldCoverage.new(
        target_class: target_class,
        target_field: target_field,
        column_type: column_type,
        entries: entries_by_target[key] || [],
        open_proposals: proposals_by_target[key] || []
      )
    end

    @total_count   = @rows.size
    @status_counts = compute_status_counts(@rows)
    @rows          = apply_target_filters(@rows)
    @rows          = sort_target_rows(@rows)

    @class_options = columns.map(&:first).uniq.sort
  end

  # POST /resolutions/accept_candidate
  # Commit the top LLM-picked open proposal for a cashline target as a
  # MappingEntry. Idempotent — upsert_edge collapses re-clicks. The "top" is
  # the highest llm-signaled, non-suppressed proposal pointing at that target.
  def accept_candidate
    authorize MappingEntry, :create?
    snapshot = current_snapshot
    return redirect_with_alert("Load a snapshot first.") if snapshot.nil?

    target_class = params.require(:target_class)
    target_field = params.require(:target_field)

    proposal = top_candidate(snapshot, target_class, target_field)
    return redirect_with_alert("No candidate available for #{target_class}.#{target_field}.") if proposal.nil?

    MappingEntry.upsert_edge(
      cashline_snapshot: snapshot,
      source_field: proposal.source_field,
      target_class: target_class,
      target_field: target_field,
      attributes: {
        mapping_type: "direct",
        confidence: "high",
        reviewed: true,
        updated_by: Current.user,
        transformation_note: "Accepted top LLM candidate from resolutions view (llm=#{proposal.signals['llm'].to_f.round(2)}, model=#{proposal.signals['llm_model'] || 'unknown'})"
      }
    )
    src = proposal.source_field
    redirect_to resolutions_by_target_path,
      notice: "Committed #{src.sobject.api_name}.#{src.api_name} → #{target_class}.#{target_field}."
  end

  private

  def top_candidate(snapshot, target_class, target_field)
    MappingProposal
      .where(cashline_snapshot_id: snapshot.id, state: "open",
             target_class: target_class, target_field: target_field)
      .includes(source_field: :sobject)
      .to_a
      .reject { |p| p.signals && p.signals["disambig_suppressed"] }
      .select { |p| p.signals && p.signals["llm"].to_f > 0 }
      .max_by { |p| p.signals["llm"].to_f }
  end

  def redirect_with_alert(message)
    redirect_to resolutions_by_target_path, alert: message
  end

  def render_empty_state
    render :empty
  end

  # ── data loaders ────────────────────────────────────────────────────────

  def assessments_by_sfield_id(snapshot, sfields)
    return {} if snapshot.nil?
    FieldAssessment
      .where(cashline_snapshot_id: snapshot.id, sfield_id: sfields.map(&:id))
      .index_by(&:sfield_id)
  end

  def entries_by_sfield_id(snapshot, sfields)
    return Hash.new { |h, k| h[k] = [] } if snapshot.nil?
    policy_scope(MappingEntry)
      .for_session(snapshot.id)
      .where(source_field_id: sfields.map(&:id))
      .includes(:source_field)
      .group_by(&:source_field_id)
  end

  def proposals_by_sfield_id(snapshot, sfields)
    return Hash.new { |h, k| h[k] = [] } if snapshot.nil?
    MappingProposal
      .where(cashline_snapshot_id: snapshot.id, source_field_id: sfields.map(&:id), state: "open")
      .group_by(&:source_field_id)
  end

  def profiles_by_sfield_id(run, sfields)
    FieldProfile
      .joins(:object_profile)
      .where(object_profiles: { extraction_run_id: run.id })
      .where(sfield_id: sfields.map(&:id))
      .index_by(&:sfield_id)
  end

  def data_groups_by_sfield_id(run, sfields)
    return {} unless defined?(ClusterAssignment) && defined?(Cluster)
    sobject_groups = ClusterAssignment
      .joins(:cluster)
      .where(clusters: { extraction_run_id: run.id }, sobject_id: sfields.map(&:sobject_id).uniq)
      .pluck(:sobject_id, "clusters.name")
      .to_h
    sfields.each_with_object({}) { |sf, h| h[sf.id] = sobject_groups[sf.sobject_id] }
  end

  # ── target-side data loaders ───────────────────────────────────────────

  def snapshot_columns(snapshot)
    Array(snapshot.schema_json["classes"]).flat_map do |cls|
      class_name = cls["class_name"]
      Array(cls["columns"]).map { |col| [ class_name, col["name"], col["type"] ] }
    end
  end

  def entries_by_target_key(snapshot)
    policy_scope(MappingEntry)
      .for_session(snapshot.id)
      .where.not(target_class: nil)
      .includes(source_field: :sobject)
      .group_by { |e| [ e.target_class, e.target_field ] }
  end

  def proposals_by_target_key(snapshot, run)
    return {} if run.nil?
    field_ids = Sfield.joins(:sobject).where(sobjects: { extraction_run_id: run.id }).pluck(:id)
    MappingProposal
      .where(cashline_snapshot_id: snapshot.id, state: "open", source_field_id: field_ids)
      .includes(source_field: :sobject)
      .group_by { |p| [ p.target_class, p.target_field ] }
  end

  # ── filters ────────────────────────────────────────────────────────────

  def apply_source_filters(rows)
    if params[:disposition].present?
      val = params[:disposition]
      rows = rows.select { |r| (r.disposition || "unreviewed") == val }
    end
    if params[:sobject].present?
      rows = rows.select { |r| r.sobject_name == params[:sobject] }
    end
    if params[:attention] == "1"
      rows = rows.select { |r| r.attention >= 70 }
    end
    rows
  end

  def apply_target_filters(rows)
    if params[:status].present?
      rows = rows.select { |r| r.status == params[:status] }
    end
    if params[:class_name].present?
      rows = rows.select { |r| r.target_class == params[:class_name] }
    end
    rows
  end

  def sort_source_rows(rows)
    # Default: attention desc, then object/field for stable order.
    rows.sort_by { |r| [ -r.attention, r.sobject_name.to_s, r.field_name.to_s ] }
  end

  def sort_target_rows(rows)
    rows.sort_by { |r| [ r.sort_priority, r.target_class.to_s, r.target_field.to_s ] }
  end

  def compute_disposition_counts(rows)
    rows.each_with_object(Hash.new(0)) do |row, acc|
      acc[row.disposition || "unreviewed"] += 1
    end
  end

  def compute_status_counts(rows)
    rows.each_with_object(Hash.new(0)) { |row, acc| acc[row.status] += 1 }
  end
end
