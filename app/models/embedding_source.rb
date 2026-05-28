# Back-reference linking a Sailfin source field to the descriptor content hash
# it produced, so embeddings can be purged per-field on a sensitivity upgrade
# (the hash-keyed EmbeddingCache alone can't be purged by field).
class EmbeddingSource < ApplicationRecord
  belongs_to :sfield

  validates :content_sha256, presence: true
end
