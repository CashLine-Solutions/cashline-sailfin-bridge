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
