class CreateClusters < ActiveRecord::Migration[8.1]
  def change
    create_table :clusters do |t|
      t.references :extraction_run, null: false, foreign_key: true, index: true
      t.string :name, null: false
      t.string :color
      t.boolean :user_modified, null: false, default: false
      t.timestamps
    end
    add_index :clusters, [ :extraction_run_id, :name ], unique: true

    create_table :cluster_assignments do |t|
      t.references :cluster, null: false, foreign_key: true, index: true
      t.references :sobject, null: false, foreign_key: true, index: true
      t.timestamps
    end
    add_index :cluster_assignments, [ :cluster_id, :sobject_id ], unique: true
    add_index :cluster_assignments, :sobject_id, unique: true, name: "index_cluster_assignments_on_sobject_unique"
  end
end
