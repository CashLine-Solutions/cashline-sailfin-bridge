class CreateMappingEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :mapping_entries do |t|
      t.references :cashline_snapshot, null: false, foreign_key: true
      # Nullable: net_new rows (a cashline field with no Sailfin source) have no source field.
      t.references :source_field, null: true, foreign_key: { to_table: :sfields }
      t.references :updated_by, null: true, foreign_key: { to_table: :users }
      t.string :target_class   # natural key into the snapshot, nullable (reviewed-no-home)
      t.string :target_field   # natural key into the snapshot, nullable
      t.string :mapping_type   # direct|value_collapse|split|derived|dropped|net_new
      t.string :confidence
      t.boolean :reviewed, null: false, default: false
      t.text :transformation_note
      t.text :source_citation
      t.boolean :needs_crosswalk, null: false, default: false
      t.timestamps
    end

    # Grid join + N:1 ("also mapped from N fields") lookups.
    add_index :mapping_entries, %i[cashline_snapshot_id target_class target_field]

    # Postgres 14 has no NULLS NOT DISTINCT, so COALESCE(source_field_id, -1)
    # makes the null source_field_id of net_new rows collide instead of being
    # treated as distinct — otherwise duplicate net_new edges would slip past.
    reversible do |dir|
      dir.up do
        # (a) one row per concrete edge (incl. net_new, which has null source + a target)
        execute <<~SQL
          CREATE UNIQUE INDEX index_mapping_entries_on_targeted_edge
          ON mapping_entries (cashline_snapshot_id, COALESCE(source_field_id, -1), target_class, target_field)
          WHERE target_class IS NOT NULL;
        SQL
        # (b) the single canonical null-target row per source (reviewed-no-home)
        execute <<~SQL
          CREATE UNIQUE INDEX index_mapping_entries_on_null_target
          ON mapping_entries (cashline_snapshot_id, COALESCE(source_field_id, -1))
          WHERE target_class IS NULL;
        SQL
      end
    end
  end
end
