# Picklist value-level mapping: maps a Sailfin field's source picklist values
# onto the target enum's values, inside an expandable sub-table on the grid.
# Loaded lazily into a Turbo Frame; edits re-render that frame.
class MappingValueEntriesController < ApplicationController
  before_action :load_mapping_entry
  after_action :verify_authorized

  def index
    authorize @mapping_entry, :show?, policy_class: MappingValueEntryPolicy
    render_value_table
  end

  # Upsert by source_value (it's unique per entry). A blank target clears the
  # mapping (delete) so the inline select's blank option works as "unset".
  def create
    authorize @mapping_entry, :create?, policy_class: MappingValueEntryPolicy
    sv = value_params[:source_value]
    if sv.present?
      existing = @mapping_entry.mapping_value_entries.find_by(source_value: sv)
      if value_params[:target_enum_value].blank?
        existing&.destroy!
      else
        entry = existing || @mapping_entry.mapping_value_entries.build(source_value: sv)
        entry.target_enum_value = value_params[:target_enum_value]
        entry.notes = value_params[:notes] if value_params.key?(:notes)
        entry.save!
      end
    end
    render_value_table
  end

  def destroy
    authorize @mapping_entry, :destroy?, policy_class: MappingValueEntryPolicy
    @mapping_entry.mapping_value_entries.find_by(id: params[:id])&.destroy!
    render_value_table
  end

  private

  # Parent visibility uses the run-level dimension (MappingEntryPolicy::Scope);
  # a sensitive-run entry isn't in scope for non-privileged users → 404, which
  # is the value sub-table scope-out.
  def load_mapping_entry
    @mapping_entry = policy_scope(MappingEntry).find(params[:mapping_id])
  end

  def value_params
    params.fetch(:mapping_value_entry, {}).permit(:source_value, :target_enum_value, :notes)
  end

  def render_value_table
    @snapshot = @mapping_entry.cashline_snapshot
    @can_edit = MappingValueEntryPolicy.new(Current.user, @mapping_entry).create?
    # Field-level sensitivity dimension: real picklist values are field content.
    @can_view_values = FieldSamplePolicy.new(Current.user, { run: source_run, sfield: @mapping_entry.source_field }).show_sample_values?
    @enum_values = enum_value_names
    @source_values = @can_view_values ? source_value_rows : []
    @existing = @mapping_entry.mapping_value_entries.index_by(&:source_value)
    @frame_id = "mapping_entry_#{@mapping_entry.id}_values"

    respond_to do |format|
      format.html { render :index, layout: false }
      format.turbo_stream { render :index, layout: false }
    end
  end

  def source_run
    @mapping_entry.source_field&.sobject&.extraction_run
  end

  def enum_value_names
    return [] if @snapshot.nil? || @mapping_entry.target_class.blank?
    (@snapshot.enum_values(@mapping_entry.target_class, @mapping_entry.target_field) || {}).keys
  end

  # Declared spicklist_values plus undeclared in-data values (from top_values),
  # each annotated with observed frequency; ordered by frequency desc.
  def source_value_rows
    sfield = @mapping_entry.source_field
    return [] if sfield.nil?

    freq = {}
    Array(field_profile_for(sfield)&.top_values).each do |tv|
      v = (tv["value"] || tv["v"]).to_s
      freq[v] = tv["count"] || tv["c"]
    end

    declared = sfield.spicklist_values.map do |pv|
      { value: pv.value.to_s, label: pv.label, count: freq[pv.value.to_s], declared: true, active: pv.active }
    end
    declared_set = declared.map { |d| d[:value] }
    undeclared = freq.keys.reject { |v| declared_set.include?(v) }.map do |v|
      { value: v, label: nil, count: freq[v], declared: false, active: nil }
    end

    (declared + undeclared).sort_by { |r| [ r[:count] ? -r[:count].to_i : 1, r[:value] ] }
  end

  def field_profile_for(sfield)
    run = sfield.sobject.extraction_run
    FieldProfile.joins(:object_profile)
      .where(object_profiles: { extraction_run_id: run.id }, sfield_id: sfield.id)
      .first
  end
end
