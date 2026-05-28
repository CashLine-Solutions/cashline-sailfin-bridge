# Content-addressed embedding store. Keyed by the SHA-256 of the descriptor
# text, so identical descriptors (and re-runs) reuse one row and never re-bill
# OpenAI. `neighbor` provides cosine nearest-neighbor search over the vector.
class EmbeddingCache < ApplicationRecord
  has_neighbors :embedding

  validates :content_sha256, presence: true, uniqueness: true
end
