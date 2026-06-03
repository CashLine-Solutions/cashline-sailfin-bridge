module Salesforce
  # Exports the full record set for one Salesforce object into the generic
  # `sf_records` JSONB table via Bulk API 2.0. The field list comes from the
  # already-extracted `sfields` metadata, so an ExtractionRun must have described
  # the object first.
  #
  # Storage model: one `sf_records` row per Salesforce record, keyed by
  # (extraction_run_id, object_api_name, sf_id). Re-running upserts in place, so
  # the export is idempotent. A raw JSONL backup is also streamed to
  # storage/runs/<token>/records/<Object>.jsonl as a disk-side safety net.
  #
  # Per-object progress + outcome is tracked on a `data_exports` row so the
  # driver (sailfin:download_records) can resume, skip completed objects, and
  # retry failures.
  class RecordExporter
    # Compound (address/location) and large-binary (base64) fields cannot be
    # selected directly in a Bulk 2.0 SOQL query — Salesforce rejects them. The
    # compound *child* fields (BillingStreet, BillingCity, …) are separate
    # queryable string fields and are kept.
    EXCLUDED_TYPES = %w[address location base64].freeze

    # Upsert in bounded slices. A Bulk 2.0 results page (one on_chunk call) can
    # be tens of thousands of wide JSONB rows; a single upsert_all of that size
    # builds a multi-MB SQL statement that can crash the Postgres backend
    # (observed: "PQconsumeInput() server closed the connection unexpectedly").
    UPSERT_BATCH = 1_000

    def initialize(bulk_runner: Salesforce::BulkV2Runner.new)
      @bulk_runner = bulk_runner
    end

    # Exports one sobject. Returns the DataExport tracking row.
    def export!(sobject:, run: sobject.extraction_run, run_directory: Runs::RunDirectory.for(run))
      export = DataExport.find_or_initialize_by(
        extraction_run_id: run.id, object_api_name: sobject.api_name
      )
      export.update!(status: "running", started_at: Time.current, finished_at: nil,
                     error: nil, record_count: 0, bulk_job_id: nil)

      # Clear any prior rows for this (run, object) so a re-export reflects
      # deletes in the source org rather than leaving orphaned records behind.
      SfRecord.where(extraction_run_id: run.id, object_api_name: sobject.api_name).delete_all

      backup_path = run_directory.record_backup_path(sobject.api_name)
      File.delete(backup_path) if File.exist?(backup_path)

      soql = build_soql(sobject)
      count = 0

      job = @bulk_runner.query(soql: soql, on_chunk: ->(rows) {
        persist_chunk(run, sobject.api_name, rows, run_directory, backup_path)
        count += rows.size
        export.update_columns(record_count: count, updated_at: Time.current)
      })

      export.update!(status: "complete", finished_at: Time.current,
                     record_count: count, bulk_job_id: job["id"])
      export
    rescue StandardError => e
      export&.update!(status: "failed", finished_at: Time.current,
                      error: "#{e.class}: #{e.message}")
      raise
    end

    # Fields this object will export. Public so the driver can report counts.
    def self.queryable_fields(sobject)
      fields = sobject.sfields
                      .where(accessible: true)
                      .where.not(data_type: EXCLUDED_TYPES)
                      .pluck(:api_name)
      fields.unshift("Id") unless fields.include?("Id")
      fields.uniq
    end

    private

    def build_soql(sobject)
      "SELECT #{self.class.queryable_fields(sobject).join(', ')} FROM #{sobject.api_name}"
    end

    def persist_chunk(run, object_api_name, rows, run_directory, backup_path)
      now = Time.current
      # Bulk CSV bodies arrive ASCII-8BIT; Salesforce serves UTF-8, so reinterpret
      # the bytes and scrub any stray invalid sequences before they reach jsonb
      # (and before JSON.generate, which rejects BINARY strings in json 3.0).
      clean_rows = rows.map { |row| row.transform_values { |v| utf8(v) } }

      records = clean_rows.filter_map do |row|
        sf_id = row["Id"] || row["id"]
        next if sf_id.blank?
        {
          extraction_run_id: run.id,
          object_api_name: object_api_name,
          sf_id: sf_id,
          payload: row,
          exported_at: now,
          created_at: now,
          updated_at: now
        }
      end
      return if records.empty?

      records.each_slice(UPSERT_BATCH) do |slice|
        SfRecord.upsert_all(slice, unique_by: "index_sf_records_on_run_object_sfid")
      end

      run_directory.ensure_records_dir!
      File.open(backup_path, "a") { |f| clean_rows.each { |r| f.puts(JSON.generate(r)) } }
    end

    def utf8(value)
      return value unless value.is_a?(String)
      value.dup.force_encoding("UTF-8").scrub
    end
  end
end
