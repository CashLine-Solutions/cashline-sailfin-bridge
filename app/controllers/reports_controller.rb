class ReportsController < ApplicationController
  before_action :load_run

  def hub_orphan
    if @run.nil?
      skip_authorization
      return render :hub_orphan, formats: [ :html ]
    end
    authorize @run, :show?

    rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish, "hub_orphan", [ @run.id ])
      SELECT s.id, s.api_name, s.namespace_prefix, s.custom,
             COALESCE(out_count, 0) AS out_count,
             COALESCE(in_count, 0)  AS in_count
      FROM sobjects s
      LEFT JOIN (
        SELECT source_sobject_id, COUNT(*) AS out_count
        FROM srelationships
        WHERE extraction_run_id = $1
        GROUP BY source_sobject_id
      ) o ON o.source_sobject_id = s.id
      LEFT JOIN (
        SELECT target_sobject_id, COUNT(*) AS in_count
        FROM srelationships
        WHERE extraction_run_id = $1 AND target_sobject_id IS NOT NULL
        GROUP BY target_sobject_id
      ) i ON i.target_sobject_id = s.id
      WHERE s.extraction_run_id = $1
      ORDER BY (COALESCE(out_count, 0) + COALESCE(in_count, 0)) DESC, s.api_name ASC
    SQL
    @rows = rows.to_a.map(&:symbolize_keys)
    @orphans, @nonorphans = @rows.partition { |r| r[:out_count].to_i.zero? && r[:in_count].to_i.zero? }

    respond_to do |format|
      format.html
      format.csv { send_data csv_for(@rows, %i[api_name namespace_prefix out_count in_count]), filename: "hub_orphan_#{@run.directory_token}.csv" }
    end
  end

  # Suggested mapping order: reference targets → entities → junctions.
  # The bucket is a heuristic — designers should adjust as they go — but
  # it answers the runbook's "where do I start?" question for a fresh
  # extraction.
  def mapping_order
    if @run.nil?
      skip_authorization
      return render :mapping_order, formats: [ :html ]
    end
    authorize @run, :show?

    rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish, "mapping_order", [ @run.id ])
      SELECT s.id, s.api_name, s.namespace_prefix, s.custom,
             COALESCE(f.field_count, 0)  AS field_count,
             COALESCE(o.out_count, 0)    AS out_count,
             COALESCE(i.in_count, 0)     AS in_count
      FROM sobjects s
      LEFT JOIN (
        SELECT sf.sobject_id, COUNT(*) AS field_count
        FROM sfields sf
        JOIN sobjects so ON so.id = sf.sobject_id
        WHERE so.extraction_run_id = $1
        GROUP BY sf.sobject_id
      ) f ON f.sobject_id = s.id
      LEFT JOIN (
        SELECT source_sobject_id, COUNT(*) AS out_count
        FROM srelationships WHERE extraction_run_id = $1
        GROUP BY source_sobject_id
      ) o ON o.source_sobject_id = s.id
      LEFT JOIN (
        SELECT target_sobject_id, COUNT(*) AS in_count
        FROM srelationships
        WHERE extraction_run_id = $1 AND target_sobject_id IS NOT NULL
        GROUP BY target_sobject_id
      ) i ON i.target_sobject_id = s.id
      WHERE s.extraction_run_id = $1
    SQL

    classified = rows.to_a.map { |r| classify(r.symbolize_keys) }
    @bucketed = BUCKET_ORDER.to_h { |b| [ b, sort_in_bucket(classified.select { |r| r[:bucket] == b }, b) ] }
    @bucket_order = BUCKET_ORDER
    # Flat ordered list for CSV/JSON consumers and the .csv branch below.
    @rows = BUCKET_ORDER.flat_map { |b| @bucketed[b] }

    respond_to do |format|
      format.html
      format.csv do
        send_data csv_for(@rows, %i[bucket api_name namespace_prefix field_count out_count in_count rationale]),
                  filename: "mapping_order_#{@run.directory_token}.csv"
      end
    end
  end

  # Inventory of every picklist / multipicklist field in the run, ordered by
  # value count desc. Each row reports the object, field, value count, and a
  # short preview of active values. Pull this when sizing the ontology's
  # controlled-vocabulary translation work.
  def picklists
    if @run.nil?
      skip_authorization
      return render :picklists, formats: [ :html ]
    end
    authorize @run, :show?

    rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish, "picklists", [ @run.id ])
      SELECT so.api_name AS object_name,
             so.namespace_prefix AS namespace_prefix,
             sf.id AS sfield_id,
             sf.api_name AS field_name,
             sf.data_type AS data_type,
             COUNT(pv.id) FILTER (WHERE pv.active) AS active_value_count,
             COUNT(pv.id) AS total_value_count
      FROM sobjects so
      JOIN sfields sf ON sf.sobject_id = so.id
      LEFT JOIN spicklist_values pv ON pv.sfield_id = sf.id
      WHERE so.extraction_run_id = $1
        AND sf.data_type IN ('picklist', 'multipicklist')
      GROUP BY so.api_name, so.namespace_prefix, sf.id, sf.api_name, sf.data_type
      ORDER BY active_value_count DESC, so.api_name ASC, sf.api_name ASC
    SQL

    @rows = rows.to_a.map(&:symbolize_keys)

    # Preload value previews in a single query to avoid N+1.
    sfield_ids = @rows.map { |r| r[:sfield_id] }
    previews = SpicklistValue.where(sfield_id: sfield_ids, active: true)
                             .order(:value)
                             .pluck(:sfield_id, :value)
                             .group_by(&:first)
                             .transform_values { |pairs| pairs.map(&:last) }
    @previews = previews

    @field_count = @rows.size
    @value_total = @rows.sum { |r| r[:active_value_count].to_i }

    respond_to do |format|
      format.html
      format.csv do
        send_data csv_for(@rows, %i[object_name namespace_prefix field_name data_type active_value_count total_value_count]),
                  filename: "picklists_#{@run.directory_token}.csv"
      end
    end
  end

  # Inventory of every real record type (subtype) in the run, with the
  # per-record-type picklist availability captured from the describe/layouts
  # endpoint. Master record types are not stored, so every row here is a
  # genuine subtype — the unit of work when modeling polymorphic objects
  # (e.g. which Transaction kinds exist) in the forward-looking ontology.
  def record_types
    if @run.nil?
      skip_authorization
      return render :record_types, formats: [ :html ]
    end
    authorize @run, :show?

    records = SrecordType
                .joins(:sobject)
                .where(sobjects: { extraction_run_id: @run.id })
                .order(Arel.sql("sobjects.api_name ASC, srecord_types.label ASC NULLS LAST"))
                .select("srecord_types.*, sobjects.api_name AS object_api_name, sobjects.namespace_prefix AS object_namespace")

    @rows = records.map do |rt|
      picklists = rt.picklist_values.is_a?(Hash) ? rt.picklist_values : {}
      {
        object_name: rt.object_api_name,
        namespace_prefix: rt.object_namespace,
        label: rt.label,
        developer_name: rt.developer_name,
        default_mapping: rt.default_mapping,
        available: rt.available,
        scoped_field_count: picklists.keys.size,
        scoped_picklists: picklists
      }
    end

    @object_count = @rows.map { |r| r[:object_name] }.uniq.size
    @record_type_count = @rows.size

    respond_to do |format|
      format.html
      format.csv do
        send_data csv_for(@rows, %i[object_name namespace_prefix label developer_name default_mapping available scoped_field_count]),
                  filename: "record_types_#{@run.directory_token}.csv"
      end
    end
  end

  def unused_fields
    if @run.nil?
      skip_authorization
      return render :unused_fields, formats: [ :html ]
    end
    authorize @run, :show?

    threshold = params.fetch(:threshold, "0.99").to_f
    @threshold = threshold

    @rows = FieldProfile
              .joins(object_profile: :sobject, sfield: {})
              .where(object_profiles: { extraction_run_id: @run.id })
              .where("null_rate >= ?", threshold)
              .order("sobjects.api_name ASC, sfields.api_name ASC")
              .pluck("sobjects.api_name", "sfields.api_name", "sfields.data_type", "sfields.sensitivity", "field_profiles.null_rate", "sfields.id")
              .map { |row| { sobject: row[0], field: row[1], type: row[2], sensitivity: row[3], null_rate: row[4], sfield_id: row[5] } }

    respond_to do |format|
      format.html
      format.csv { send_data csv_for(@rows, %i[sobject field type sensitivity null_rate]), filename: "unused_fields_#{@run.directory_token}.csv" }
    end
  end

  private

  # Heuristic bucketing for the mapping-order report. The thresholds reflect
  # what's worked in practice: anchors are heavily referenced but reference
  # little themselves, junctions have few non-ref fields, everything else
  # is an entity. Designers should treat the suggested order as a starting
  # point, not gospel.
  JUNCTION_NON_REF_FIELDS_MAX = 4
  ANCHOR_IN_COUNT_MIN = 5

  # Bucket order for rendering. Within each bucket, anchors and entities
  # sort by inbound-degree desc (most-referenced first), junctions sort
  # alphabetically (no meaningful dependency between junctions).
  BUCKET_ORDER = %w[anchor entity junction].freeze

  def classify(row)
    field_count = row[:field_count].to_i
    out_count = row[:out_count].to_i
    in_count = row[:in_count].to_i
    non_ref_field_count = [ field_count - out_count, 0 ].max

    # Anchor before junction: a heavily-referenced hub that also points at
    # 2+ other objects belongs in the anchor bucket (map first), not the
    # junction bucket (map last).
    bucket, rationale =
      if in_count >= ANCHOR_IN_COUNT_MIN && in_count >= out_count
        [ "anchor", "referenced by #{in_count} others; map first so dependents can point at it" ]
      elsif out_count >= 2 && non_ref_field_count <= JUNCTION_NON_REF_FIELDS_MAX
        [ "junction", "links #{out_count} other objects with only #{non_ref_field_count} business fields" ]
      else
        [ "entity", "#{field_count} fields, #{in_count} inbound / #{out_count} outbound refs" ]
      end

    row.merge(bucket: bucket, non_ref_field_count: non_ref_field_count, rationale: rationale)
  end

  def sort_in_bucket(rows, bucket)
    case bucket
    when "junction"
      rows.sort_by { |r| r[:api_name].to_s.downcase }
    else
      rows.sort_by { |r| [ -r[:in_count].to_i, -r[:field_count].to_i, r[:api_name].to_s.downcase ] }
    end
  end

  def load_run
    @run = current_run
  end

  def csv_for(rows, keys)
    require "csv"
    CSV.generate do |csv|
      csv << keys.map(&:to_s)
      rows.each { |r| csv << keys.map { |k| r[k] } }
    end
  end
end
