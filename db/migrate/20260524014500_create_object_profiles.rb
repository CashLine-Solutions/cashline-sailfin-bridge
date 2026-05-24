class CreateObjectProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :object_profiles do |t|
      t.references :extraction_run, null: false, foreign_key: true
      t.references :sobject, null: false, foreign_key: true
      t.bigint :record_count
      t.datetime :profiled_at
      t.boolean :sampled, null: false, default: false
      t.integer :sample_size
      t.string :status, null: false, default: "pending" # pending/complete/failed
      t.text :failure_reason
      t.timestamps
    end

    add_index :object_profiles, %i[extraction_run_id sobject_id], unique: true
  end
end
