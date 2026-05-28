class CreateMappingProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :mapping_proposals do |t|
      t.references :source_field, null: false, foreign_key: { to_table: :sfields }
      t.references :cashline_snapshot, null: false, foreign_key: true
      t.string :target_class, null: false
      t.string :target_field, null: false
      t.float :score, null: false, default: 0.0
      t.jsonb :signals, null: false, default: {}
      t.string :state, null: false, default: "open"
      t.timestamps
    end

    add_index :mapping_proposals, %i[source_field_id cashline_snapshot_id target_class target_field],
              unique: true, name: "index_mapping_proposals_on_edge"
    add_index :mapping_proposals, %i[cashline_snapshot_id state]
    # Rejection lookup is snapshot-independent (a rejection survives re-snapshot).
    add_index :mapping_proposals, %i[source_field_id target_class target_field state]
  end
end
