class CreateSrecordTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :srecord_types do |t|
      t.references :sobject, null: false, foreign_key: true
      t.string :salesforce_id, null: false
      t.string :developer_name
      t.string :label
      t.boolean :available, null: false, default: true
      t.boolean :default_mapping, null: false, default: false
      # fieldApiName => [active value strings] valid for this record type,
      # from the describe/layouts recordTypeMappings. Empty when layouts were
      # unavailable (managed package, FLS) — the field's global picklist still
      # holds the full vocabulary in spicklist_values.
      t.jsonb :picklist_values, null: false, default: {}
      t.timestamps
    end

    add_index :srecord_types, %i[sobject_id salesforce_id], unique: true
  end
end
