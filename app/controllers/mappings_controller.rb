class MappingsController < ApplicationController
  include CurrentSnapshot

  SENSITIVE_LEVELS = %w[pii financial pii_and_financial].freeze
  TARGET_REQUIRED_TYPES = %w[direct value_collapse split derived].freeze

  after_action :verify_policy_scoped, only: :index
  after_action :verify_authorized, only: %i[create update destroy split]

  # The single sortable/filterable mapping grid — one row per edge. Resolves
  # against the active Sailfin run (ActiveRun) and the active cashline snapshot
  # (CurrentSnapshot); degrades to a source-only grid when no snapshot is loaded
  # and to an empty state when no run is selected.
  def index
    @run = current_run
    @snapshot = current_snapshot

    entries_scope = @snapshot ? MappingEntry.for_session(@snapshot.id) : MappingEntry.none
    @entries = policy_scope(entries_scope).includes(:source_field, :updated_by).to_a

    @cashline_targets = target_options(@snapshot)
    @open_proposals_by_field = open_proposals_by_field
    @rejected_proposals_by_field = rejected_proposals_by_field
    @suggested_field_ids = @open_proposals_by_field.keys
    all_rows = build_rows.sort_by(&:sort_key)
    @total_count = all_rows.size
    @rows = apply_filters(all_rows)

    respond_to do |format|
      format.html
      format.csv { export_field_csv }
    end
  end

  # Enqueue the heuristic matcher for the active (run, snapshot).
  def compute_suggestions
    return head(:forbidden) unless MappingEntryPolicy.new(Current.user, MappingEntry).create?
    run = current_run
    snapshot = current_snapshot
    if run.nil? || snapshot.nil?
      return redirect_to mappings_path, alert: "Select a run and load a snapshot before computing suggestions."
    end
    ComputeMappingProposalsJob.perform_later(run.id, snapshot.id)
    redirect_to mappings_path, notice: "Computing suggestions — refresh in a moment."
  end

  # Value-companion CSV (real picklist values) — requires sensitive_data_access.
  def export_values
    return head(:forbidden) unless MappingEntryPolicy.new(Current.user, MappingEntry).export_sensitive?
    snapshot = current_snapshot
    return head(:not_found) if snapshot.nil?

    exporter = Mapping::CsvExporter.new(entries: export_entries(snapshot), snapshot: snapshot, include_free_text: true)
    audit_export("mapping.value_csv_exported", snapshot)
    send_data exporter.value_csv, filename: "mapping_values_snapshot_#{snapshot.id}.csv", type: "text/csv"
  end

  # Lazy-create the first edge for a synthetic (never-touched) Sailfin field,
  # or a net_new target. Keyed by (snapshot, source_field, target) so concurrent
  # first-writes collapse to one row (upsert_edge owns the retry).
  def create
    authorize MappingEntry, :create?
    snapshot = current_snapshot
    return redirect_with_alert("Load a cashline snapshot before mapping.") if snapshot.nil?

    sfield = source_field_param
    tclass, tfield = parse_target(mapping_params[:target])
    attrs = edit_attributes(target_present: tclass.present?)

    entry = MappingEntry.upsert_edge(
      cashline_snapshot: snapshot, source_field: sfield,
      target_class: tclass, target_field: tfield, attributes: attrs
    )
    audit_sensitivity_downgrade(entry, nil)

    replace_id = sfield ? "mapping_synthetic_#{sfield.id}" : nil
    respond_replacing(entry, replace_id: replace_id)
  end

  def update
    entry = policy_scope(MappingEntry).find(params[:id])
    authorize entry, :update?

    old_type = entry.mapping_type
    tclass, tfield = parse_target(mapping_params[:target])
    entry.assign_attributes(target_class: tclass, target_field: tfield, **edit_attributes(target_present: tclass.present?))

    begin
      entry.save!
    rescue ActiveRecord::RecordNotUnique
      return redirect_with_alert("That source is already mapped to #{tclass}##{tfield}.")
    rescue ActiveRecord::RecordInvalid => e
      return redirect_with_alert(e.record.errors.full_messages.to_sentence)
    end
    audit_sensitivity_downgrade(entry, old_type)

    respond_replacing(entry, replace_id: "mapping_entry_#{entry.id}")
  end

  # Admin-only true deletion (clearing a target is an update, not a destroy).
  def destroy
    entry = policy_scope(MappingEntry).find(params[:id])
    authorize entry, :destroy?
    source = entry.source_field
    snapshot = entry.cashline_snapshot
    entry.destroy! # after_destroy demotes a lone surviving split sibling

    respond_to do |format|
      format.turbo_stream do
        streams = [ turbo_stream.remove("mapping_entry_#{entry.id}") ]
        # Reflect any split→direct demotion of the surviving sibling.
        survivors(source, snapshot).each do |sib|
          streams << turbo_stream.replace("mapping_entry_#{sib.id}", row_html(build_row_for(sib), snapshot))
        end
        render turbo_stream: streams
      end
      format.html { redirect_to mappings_path }
    end
  end

  # Promote an edge (and its targeted siblings) to a 1:N split, optionally
  # adding a new targeted leg. Blank legs are held client-side and persisted via
  # #create once a target is chosen (split legs always carry a target).
  def split
    entry = policy_scope(MappingEntry).find(params[:id])
    authorize entry, :update?
    snapshot = entry.cashline_snapshot

    entry.update!(mapping_type: "split", updated_by: Current.user) if entry.target_class.present?
    entry.split_siblings.where.not(mapping_type: "split").find_each { |s| s.update!(mapping_type: "split") }

    new_leg = nil
    tclass, tfield = parse_target(mapping_params[:target])
    if tclass.present? && entry.source_field_id
      new_leg = MappingEntry.upsert_edge(
        cashline_snapshot: snapshot, source_field: entry.source_field,
        target_class: tclass, target_field: tfield,
        attributes: { mapping_type: "split", updated_by: Current.user }
      )
    end

    respond_to do |format|
      format.turbo_stream do
        streams = [ turbo_stream.replace("mapping_entry_#{entry.id}", row_html(build_row_for(entry), snapshot)) ]
        streams << turbo_stream.append("mappings-tbody", row_html(build_row_for(new_leg), snapshot)) if new_leg
        render turbo_stream: streams
      end
      format.html { redirect_to mappings_path }
    end
  end

  private

  def export_field_csv
    return head(:forbidden) unless MappingEntryPolicy.new(Current.user, MappingEntry).export?
    return head(:not_found) if @snapshot.nil?

    entries = export_entries(@snapshot)
    include_free_text = MappingEntryPolicy.new(Current.user, MappingEntry).export_sensitive?
    exporter = Mapping::CsvExporter.new(entries: entries, snapshot: @snapshot, include_free_text: include_free_text)
    audit_export("mapping.field_csv_exported", @snapshot, free_text: include_free_text)
    send_data exporter.field_csv, filename: "mapping_fields_snapshot_#{@snapshot.id}.csv", type: "text/csv"
  end

  def export_entries(snapshot)
    policy_scope(MappingEntry.for_session(snapshot.id))
      .includes({ source_field: :sobject }, :updated_by, :mapping_value_entries)
      .to_a
  end

  def audit_export(action, snapshot, extra = {})
    AuditEvent.record!(user: Current.user, action: action, params: { cashline_snapshot_id: snapshot.id }.merge(extra), request: request)
  end

  # URL-param filter chips + the gap-discovery / worklist saved views.
  # All filters are applied in Ruby over the built rows so they compose with
  # the synthetic/net_new row shapes uniformly. Bookmarkable via query params.
  def apply_filters(rows)
    rows = rows.select(&:reviewed?) if params[:reviewed] == "yes"
    rows = rows.reject(&:reviewed?) if params[:reviewed] == "no"
    rows = rows.select(&:mapped?) if params[:mapped] == "yes"
    rows = rows.reject(&:mapped?) if params[:mapped] == "no"
    rows = rows.select(&:net_new?) if params[:net_new] == "1"
    rows = rows.select(&:needs_crosswalk?) if params[:needs_crosswalk] == "1"
    rows = rows.select { |r| r.mapping_type == params[:mapping_type] } if params[:mapping_type].present?
    rows = rows.select { |r| r.disposition == params[:disposition] } if FieldAssessment::DISPOSITIONS.include?(params[:disposition])
    rows = rows.select(&:gap?) if params[:gap] == "1"
    rows = rows.select { |r| !r.reviewed? && r.high_population? && !r.net_new? } if params[:worklist] == "1"
    rows = rows.select { |r| r.sfield && @suggested_field_ids.include?(r.sfield.id) } if params[:has_suggestion] == "1"
    # target_class + target_field filter — deep-linked from the cashline coverage
    # view ("show me everything pointed at this cashline column").
    if params[:target_class].present? && params[:target_field].present?
      proposals_at_target = if @snapshot
        MappingProposal.open.for_session(@snapshot.id)
          .where(target_class: params[:target_class], target_field: params[:target_field])
          .pluck(:source_field_id).to_set
      else
        Set.new
      end
      rows = rows.select do |r|
        entry_matches = r.entry && r.entry.target_class == params[:target_class] && r.entry.target_field == params[:target_field]
        proposal_matches = r.sfield && proposals_at_target.include?(r.sfield.id)
        entry_matches || proposal_matches
      end
    end
    rows
  end

  # { source_field_id => [open MappingProposal, ...] } highest score first.
  def open_proposals_by_field
    return {} if @snapshot.nil?
    MappingProposal.open.for_session(@snapshot.id).order(score: :desc).group_by(&:source_field_id)
  end

  # { source_field_id => [rejected MappingProposal, ...] } — surfaces the
  # "restore" (un-reject) affordance.
  def rejected_proposals_by_field
    return {} if @snapshot.nil?
    MappingProposal.rejected.for_session(@snapshot.id).group_by(&:source_field_id)
  end

  def mapping_params
    params.fetch(:mapping_entry, {}).permit(:source_field_id, :target, :mapping_type, :confidence, :reviewed, :transformation_note, :source_citation, :needs_crosswalk)
  end

  def source_field_param
    id = mapping_params[:source_field_id]
    id.present? ? Sfield.find_by(id: id) : nil
  end

  def parse_target(raw)
    return [ nil, nil ] if raw.blank?
    klass, field = raw.to_s.split("#", 2)
    return [ nil, nil ] if klass.blank? || field.blank?
    [ klass, field ]
  end

  # Attribute set common to create/update. mapping_type normalizes against
  # whether a target is present (direct by default with a target; dropped or
  # unset without one).
  def edit_attributes(target_present:)
    p = mapping_params
    {
      mapping_type: normalized_type(p[:mapping_type], target_present),
      confidence: p[:confidence],
      reviewed: ActiveModel::Type::Boolean.new.cast(p[:reviewed]) || false,
      transformation_note: p[:transformation_note],
      source_citation: p[:source_citation],
      updated_by: Current.user
    }.tap { |h| h[:needs_crosswalk] = ActiveModel::Type::Boolean.new.cast(p[:needs_crosswalk]) if p.key?(:needs_crosswalk) }
  end

  def normalized_type(submitted, target_present)
    if target_present
      submitted.presence || "direct"
    else
      submitted == "dropped" ? "dropped" : nil
    end
  end

  # Records mapping.sensitivity_downgrade when an edge is set to `dropped` for a
  # PII/financial source field (the act of deciding not to carry sensitive data
  # forward). Uses the field-level sensitivity dimension.
  def audit_sensitivity_downgrade(entry, old_type)
    return unless entry.mapping_type == "dropped" && old_type != "dropped"
    field = entry.source_field
    return if field.nil? || !SENSITIVE_LEVELS.include?(field.sensitivity.to_s)

    AuditEvent.record!(
      user: Current.user,
      action: "mapping.sensitivity_downgrade",
      subject: entry,
      params: {
        sfield_id: field.id, sensitivity: field.sensitivity,
        old_mapping_type: old_type, new_mapping_type: entry.mapping_type
      },
      request: request
    )
  end

  def respond_replacing(entry, replace_id:)
    snapshot = entry.cashline_snapshot
    respond_to do |format|
      format.turbo_stream do
        target = replace_id || "mapping_entry_#{entry.id}"
        render turbo_stream: turbo_stream.replace(target, row_html(build_row_for(entry), snapshot))
      end
      format.html { redirect_to mappings_path }
    end
  end

  def redirect_with_alert(message)
    respond_to do |format|
      format.turbo_stream { redirect_to mappings_path, alert: message }
      format.html { redirect_to mappings_path, alert: message }
    end
  end

  def row_html(row, snapshot)
    proposals = {}
    rejected = {}
    if row.sfield && snapshot
      proposals = { row.sfield.id => MappingProposal.open.for_session(snapshot.id).where(source_field_id: row.sfield.id).order(score: :desc).to_a }
      rejected = MappingProposal.rejected.for_session(snapshot.id).where(source_field_id: row.sfield.id).group_by(&:source_field_id)
    end
    render_to_string(
      partial: "mappings/row",
      locals: { row: row, snapshot: snapshot, proposals_by_field: proposals, rejected_proposals_by_field: rejected },
      formats: [ :html ]
    )
  end

  # --- grid row construction -------------------------------------------------

  def build_rows
    rows = []
    entries_by_field = @entries.group_by(&:source_field_id)

    if @run
      sfields = source_fields_for(@run)
      profiles = field_profiles_for(@run, sfields)
      groups = data_groups_for(@run)
      assessments = assessments_for(sfields)

      sfields.each do |sf|
        fp = profiles[sf.id]
        dg = groups[sf.sobject_id]
        fa = assessments[sf.id]
        field_entries = entries_by_field[sf.id]
        if field_entries.blank?
          rows << MappingGridRow.new(sfield: sf, entry: nil, data_group: dg, field_profile: fp, field_assessment: fa)
        else
          field_entries.each do |entry|
            rows << MappingGridRow.new(sfield: sf, entry: entry, data_group: dg, field_profile: fp, field_assessment: fa)
          end
        end
      end
    end

    Array(entries_by_field[nil]).each do |entry|
      rows << MappingGridRow.new(sfield: nil, entry: entry, data_group: nil, field_profile: nil, field_assessment: nil)
    end

    rows
  end

  # Build a single grid row for a persisted entry (for Turbo Stream replacement).
  def build_row_for(entry)
    sfield = entry.source_field
    MappingGridRow.new(
      sfield: sfield, entry: entry,
      data_group: sfield && data_group_for(sfield),
      field_profile: sfield && field_profile_for(sfield),
      field_assessment: sfield && @snapshot && FieldAssessment.find_by(sfield_id: sfield.id, cashline_snapshot_id: @snapshot.id)
    )
  end

  # sfield_id => FieldAssessment for the active snapshot (role note + disposition).
  def assessments_for(sfields)
    return {} if @snapshot.nil?
    FieldAssessment.where(cashline_snapshot_id: @snapshot.id, sfield_id: sfields.map(&:id)).index_by(&:sfield_id)
  end

  def source_fields_for(run)
    Sfield.joins(:sobject).where(sobjects: { extraction_run_id: run.id }).includes(:sobject).to_a
  end

  def field_profiles_for(run, sfields)
    FieldProfile.joins(:object_profile)
      .where(object_profiles: { extraction_run_id: run.id }, sfield_id: sfields.map(&:id))
      .index_by(&:sfield_id)
  end

  def field_profile_for(sfield)
    FieldProfile.joins(:object_profile)
      .where(object_profiles: { extraction_run_id: sfield.sobject.extraction_run_id }, sfield_id: sfield.id)
      .first
  end

  # sobject_id => cluster name, for the Data Group column.
  def data_groups_for(run)
    ClusterAssignment.joins(:cluster)
      .where(clusters: { extraction_run_id: run.id })
      .pluck(:sobject_id, "clusters.name")
      .to_h
  end

  def data_group_for(sfield)
    ClusterAssignment.joins(:cluster)
      .where(sobject_id: sfield.sobject_id, clusters: { extraction_run_id: sfield.sobject.extraction_run_id })
      .pick("clusters.name")
  end

  def survivors(source, snapshot)
    return [] if source.nil?
    MappingEntry.for_session(snapshot.id).where(source_field_id: source.id).targeted.to_a
  end

  # Flat "Class#field" strings for the target typeahead datalist, grouped by
  # namespace order. Empty when no snapshot is loaded.
  def target_options(snapshot)
    return [] if snapshot.nil?
    snapshot.classes_by_namespace.sort_by { |ns, _| ns.to_s }.flat_map do |_ns, class_names|
      class_names.flat_map do |class_name|
        snapshot.fields_for(class_name).map { |col| "#{class_name}##{col['name']}" }
      end
    end
  end
end
