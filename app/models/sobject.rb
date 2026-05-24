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
end
