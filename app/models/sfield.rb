class Sfield < ApplicationRecord
  self.table_name = "sfields"

  belongs_to :sobject
  has_many :spicklist_values, dependent: :destroy
  has_many :field_profiles, dependent: :destroy

  validates :api_name, presence: true
end
