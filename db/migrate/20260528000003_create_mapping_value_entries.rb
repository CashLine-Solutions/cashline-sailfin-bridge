class CreateMappingValueEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :mapping_value_entries do |t|
      t.references :mapping_entry, null: false, foreign_key: true
      # Raw string so undeclared in-data values (not in spicklist_values) still map.
      t.string :source_value, null: false
      t.string :target_enum_value # enum natural key, or a drop/derive sentinel
      t.text :notes
      t.timestamps
    end

    add_index :mapping_value_entries, %i[mapping_entry_id source_value], unique: true
  end
end
