class CreateEmbeddingSources < ActiveRecord::Migration[8.1]
  # Back-reference (Sailfin source field → descriptor content hash). The cache
  # alone is hash-keyed and can't be purged by field; this makes per-field purge
  # tractable when a field's sensitivity is upgraded (safe → sensitive).
  def change
    create_table :embedding_sources do |t|
      t.references :sfield, null: false, foreign_key: true
      t.string :content_sha256, null: false
      t.timestamps
    end

    add_index :embedding_sources, %i[sfield_id content_sha256], unique: true
    add_index :embedding_sources, :content_sha256
  end
end
