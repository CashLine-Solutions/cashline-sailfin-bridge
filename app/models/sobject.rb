class Sobject < ApplicationRecord
  self.table_name = "sobjects"

  belongs_to :extraction_run
  has_many :sfields, dependent: :destroy
  has_many :object_profiles, dependent: :destroy
  has_many :outgoing_relationships, class_name: "Srelationship",
                                    foreign_key: :source_sobject_id, dependent: :destroy
  has_many :incoming_relationships, class_name: "Srelationship",
                                    foreign_key: :target_sobject_id, dependent: :nullify
  has_one :cluster_assignment, dependent: :destroy
  has_one :cluster, through: :cluster_assignment

  validates :api_name, presence: true

  # Returns [prev_api_name, next_api_name] for alphabetical sequential
  # navigation through this sobject's fields. Used by the standalone
  # field detail page's prev/next links.
  def field_neighbors(sfield)
    ordered = sfields.order(:api_name).pluck(:api_name)
    idx = ordered.index(sfield.api_name)
    return [ nil, nil ] if idx.nil?
    [ idx.positive? ? ordered[idx - 1] : nil, ordered[idx + 1] ]
  end
end
