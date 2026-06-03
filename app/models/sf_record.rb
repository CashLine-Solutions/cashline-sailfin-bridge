class SfRecord < ApplicationRecord
  self.table_name = "sf_records"

  belongs_to :extraction_run

  validates :object_api_name, :sf_id, presence: true
end
