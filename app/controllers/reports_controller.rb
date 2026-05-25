class ReportsController < ApplicationController
  before_action :load_run

  def hub_orphan
    if @run.nil?
      skip_authorization
      return render :hub_orphan
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
      return render :mapping_order
    end
    authorize @run, :show?

    rows = ActiveRecord::Base.connection.select_all(<<~SQL.squish, "mapping_order", [ @run.id ])
      SELECT s.id, s.api_name, s.namespace_prefix, s.custom,
             COALESCE(f.field_count, 0)  AS field_count,
             COALESCE(o.out_count, 0)    AS out_count,
             COALESCE(i.in_count, 0)     AS in_count
      FROM sobjects s
      LEFT JOIN (
        SELECT sobject_id, COUNT(*) AS field_count FROM sfields GROUP BY sobject_id
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

  def unused_fields
    if @run.nil?
      skip_authorization
      return render :unused_fields
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
  # what's worked in practice: junctions have few non-ref fields, anchors
  # are heavily referenced but reference little themselves, everything else
  # is an entity. Designers should treat the suggested order as a starting
  # point, not gospel.
  JUNCTION_NON_REF_FIELDS_MAX = 4
  ANCHOR_IN_COUNT_MIN = 5

  def classify(row)
    field_count = row[:field_count].to_i
    out_count = row[:out_count].to_i
    in_count = row[:in_count].to_i
    non_ref_field_count = [ field_count - out_count, 0 ].max

    bucket, rationale =
      if out_count >= 2 && non_ref_field_count <= JUNCTION_NON_REF_FIELDS_MAX
        [ "junction", "links #{out_count} other objects with only #{non_ref_field_count} business fields" ]
      elsif in_count >= ANCHOR_IN_COUNT_MIN && in_count >= out_count
        [ "anchor", "referenced by #{in_count} others; map first so dependents can point at it" ]
      else
        [ "entity", "#{field_count} fields, #{in_count} inbound / #{out_count} outbound refs" ]
      end

    row.merge(bucket: bucket, non_ref_field_count: non_ref_field_count, rationale: rationale)
  end

  # Bucket order for rendering. Within each bucket, anchors and entities
  # sort by inbound-degree desc (most-referenced first), junctions sort
  # alphabetically (no meaningful dependency between junctions).
  BUCKET_ORDER = %w[anchor entity junction].freeze

  def sort_in_bucket(rows, bucket)
    case bucket
    when "junction"
      rows.sort_by { |r| r[:api_name].to_s.downcase }
    else
      rows.sort_by { |r| [ -r[:in_count].to_i, -r[:field_count].to_i, r[:api_name].to_s.downcase ] }
    end
  end

  helper_method :bucket_order

  def bucket_order
    BUCKET_ORDER
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
