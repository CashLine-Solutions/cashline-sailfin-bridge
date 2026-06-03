class CreateSfRecordsAndDataExports < ActiveRecord::Migration[8.1]
  def change
    # Full record data pulled from Salesforce, stored generically as JSONB so a
    # single table holds every object's rows without per-object DDL. The
    # workbench/ontology layer reads fields via payload->>'Field'. This is a
    # snapshot keyed by (run, object, sf_id) so re-running an export upserts in
    # place rather than duplicating rows.
    create_table :sf_records do |t|
      t.references :extraction_run, null: false, foreign_key: true
      t.string :object_api_name, null: false
      t.string :sf_id, null: false
      t.jsonb :payload, null: false, default: {}
      t.datetime :exported_at, null: false

      t.timestamps
    end

    add_index :sf_records, [ :extraction_run_id, :object_api_name, :sf_id ],
              unique: true, name: "index_sf_records_on_run_object_sfid"
    add_index :sf_records, [ :extraction_run_id, :object_api_name ],
              name: "index_sf_records_on_run_and_object"

    # Per-object export tracking so a full download is resumable and observable:
    # the driver skips objects already `complete`, retries `failed` ones, and
    # the row records the Bulk job id + count for spot-checks.
    create_table :data_exports do |t|
      t.references :extraction_run, null: false, foreign_key: true
      t.string :object_api_name, null: false
      t.string :status, null: false, default: "pending"
      t.integer :record_count, null: false, default: 0
      t.string :bulk_job_id
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :data_exports, [ :extraction_run_id, :object_api_name ],
              unique: true, name: "index_data_exports_on_run_and_object"
  end
end
