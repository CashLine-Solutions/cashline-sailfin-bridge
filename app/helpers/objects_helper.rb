require "csv"

module ObjectsHelper
  # Builds a flat one-row-per-field CSV for the given sobjects, scoped to
  # the run's profile data. Used by /objects.csv (filtered field list) and
  # /objects/:api_name.csv (single object).
  #
  # PII / financial top_values and sample_values are intentionally NOT
  # included in the CSV — the file is meant to be safe to share with
  # designers working on mapping. Aggregate stats (counts, rates) are
  # included because they don't leak the underlying values.
  def fields_export_csv(sobjects, run)
    sobject_ids = sobjects.map(&:id)
    sfields = Sfield.where(sobject_id: sobject_ids).order("sobjects.api_name, sfields.api_name").joins(:sobject).to_a
    field_profiles = FieldProfile.joins(:object_profile)
      .where(object_profiles: { extraction_run_id: run.id }, sfield_id: sfields.map(&:id))
      .index_by(&:sfield_id)
    record_counts = ObjectProfile.where(extraction_run_id: run.id, sobject_id: sobject_ids).pluck(:sobject_id, :record_count).to_h
    sobjects_by_id = sobjects.index_by(&:id)
    relationship_targets = relationship_target_lookup(run, sfields.map(&:id))

    CSV.generate do |csv|
      csv << CSV_HEADERS
      sfields.each do |sf|
        so = sobjects_by_id[sf.sobject_id]
        fp = field_profiles[sf.id]
        rc = record_counts[sf.sobject_id]
        csv << csv_row_for(so, sf, fp, rc, relationship_targets[sf.id])
      end
    end
  end

  CSV_HEADERS = %w[
    sobject_api_name sobject_label sobject_namespace sobject_custom sobject_record_count
    field_api_name field_label field_data_type field_length field_sensitivity
    field_calculated field_encrypted field_nillable field_name_field
    field_accessible field_createable field_updateable field_filterable
    field_picklist_count field_references_count field_reference_target
    null_rate distinct_count distinct_count_suppressed
    min_length max_length avg_length
    min_value max_value mean_value p50_value p95_value
    min_date max_date
    has_top_values has_samples
    formula
    target_iri confidence notes
  ].freeze

  # Blank columns shipped at the end of every row for designers to fill in:
  # target_iri / confidence / notes. Kept as a named constant so a future
  # CSV_HEADERS reorder can't silently misalign them.
  MAPPING_PLACEHOLDERS = [ nil, nil, nil ].freeze

  private

  def csv_row_for(sobject, sfield, fp, record_count, ref_target)
    [
      sobject.api_name, sobject.label, sobject.namespace_prefix.presence || "standard",
      sobject.custom, record_count,
      sfield.api_name, sfield.label, sfield.data_type, sfield.length, sfield.sensitivity,
      sfield.calculated, sfield.encrypted, sfield.nillable, sfield.name_field,
      sfield.accessible, sfield.createable, sfield.updateable, sfield.filterable,
      sfield.picklist_count, sfield.references_count, ref_target,
      fp&.null_rate, fp&.distinct_count, fp&.distinct_count_suppressed,
      fp&.min_length, fp&.max_length, fp&.avg_length,
      fp&.min_value, fp&.max_value, fp&.mean_value, fp&.p50_value, fp&.p95_value,
      fp&.min_date&.iso8601, fp&.max_date&.iso8601,
      fp ? fp.top_values.present? : nil, fp ? fp.sample_values.present? : nil,
      sfield.calculated_formula,
      *MAPPING_PLACEHOLDERS
    ]
  end

  # For each sfield that's a reference, returns the comma-joined target
  # sobject api_names. Built in one query to avoid N+1.
  def relationship_target_lookup(run, sfield_ids)
    rels = Srelationship.where(extraction_run_id: run.id, source_field_id: sfield_ids).includes(:target_sobject)
    rels.each_with_object(Hash.new { |h, k| h[k] = [] }) do |rel, acc|
      label = rel.target_sobject&.api_name || Array(rel.reference_to_api_names).join("|")
      label += " (polymorphic)" if rel.polymorphic
      acc[rel.source_field_id] << label
    end.transform_values { |arr| arr.join(", ") }
  end
end
