class AddGroupingMergeSupport < ActiveRecord::Migration[8.1]
  def up
    # Provenance: which detected parent label this member came from. Lets a
    # manual merge stay reversible — unmerge pulls back exactly the members that
    # originally belonged to the absorbed grouping — and lets the detector
    # re-aggregate correctly after aliases are applied.
    add_column :customer_grouping_members, :source_parent_name, :string
    execute <<~SQL
      UPDATE customer_grouping_members m
      SET source_parent_name = g.parent_name
      FROM customer_groupings g
      WHERE g.id = m.customer_grouping_id
    SQL
    change_column_null :customer_grouping_members, :source_parent_name, false

    # A durable operator decision that one detected parent label is the same
    # customer as another (rebrands/aliases like "CB RICHARD ELLIS" = "CBRE",
    # which no string rule catches). The detector folds aliased candidates into
    # the canonical grouping on every run, so merges survive re-detection.
    create_table :customer_grouping_aliases do |t|
      t.references :extraction_run, null: false, foreign_key: true
      t.string :alias_normalized, null: false        # normalize(absorbed parent label)
      t.string :absorbed_display_name, null: false   # original label, for unmerge + display
      t.string :canonical_parent_name, null: false   # the surviving grouping's parent_name

      t.timestamps
    end

    add_index :customer_grouping_aliases, [ :extraction_run_id, :alias_normalized ],
              unique: true, name: "index_grouping_aliases_on_run_and_alias"
    add_index :customer_grouping_aliases, [ :extraction_run_id, :canonical_parent_name ],
              name: "index_grouping_aliases_on_run_and_canonical"
  end

  def down
    drop_table :customer_grouping_aliases
    remove_column :customer_grouping_members, :source_parent_name
  end
end
