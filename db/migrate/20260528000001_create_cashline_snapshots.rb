class CreateCashlineSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :cashline_snapshots do |t|
      t.datetime :loaded_at, null: false
      t.string :sha256, null: false
      t.jsonb :schema_json, null: false, default: {}
      t.timestamps
    end

    add_index :cashline_snapshots, :loaded_at
  end
end
