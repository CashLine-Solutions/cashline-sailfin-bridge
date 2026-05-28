class CreateEmbeddingCaches < ActiveRecord::Migration[8.1]
  # Content-addressed embedding cache: keyed by the SHA-256 of the descriptor
  # text so re-runs (and fields/targets with identical descriptors) never
  # re-bill OpenAI. One model (text-embedding-3-small / 1536) is in scope — no
  # speculative model/dims columns; add them only if a second model arrives.
  def change
    create_table :embedding_caches do |t|
      t.string :content_sha256, null: false
      t.column :embedding, "vector(1536)", null: false
      t.timestamps
    end

    add_index :embedding_caches, :content_sha256, unique: true
    # No ANN index initially (hundreds of rows). Add HNSW + vector_cosine_ops
    # only if nearest-neighbor gets slow at real field counts.
  end
end
