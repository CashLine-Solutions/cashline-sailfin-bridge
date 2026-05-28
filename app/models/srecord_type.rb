class SrecordType < ApplicationRecord
  self.table_name = "srecord_types"

  belongs_to :sobject

  validates :salesforce_id, presence: true
end
