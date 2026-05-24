class CreateRunDiffs < ActiveRecord::Migration[8.1]
  def change
    create_table :run_diffs do |t|
      t.references :run_a, null: false, foreign_key: { to_table: :extraction_runs }, index: true
      t.references :run_b, null: false, foreign_key: { to_table: :extraction_runs }, index: true
      t.datetime :computed_at, null: false
      t.jsonb :diff, null: false, default: {}
      t.timestamps
    end
    add_index :run_diffs, [ :run_a_id, :run_b_id ], unique: true
  end
end
