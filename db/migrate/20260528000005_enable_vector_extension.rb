class EnableVectorExtension < ActiveRecord::Migration[8.1]
  # pgvector must exist before any vector column is created (next migration),
  # and before db/structure.sql is loaded in CI/prod — bake pgvector into those
  # Postgres images first (see README / plan Risks).
  def change
    enable_extension "vector"
  end
end
