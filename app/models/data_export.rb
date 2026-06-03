class DataExport < ApplicationRecord
  self.table_name = "data_exports"

  STATUSES = %w[pending running complete failed skipped].freeze

  belongs_to :extraction_run

  validates :object_api_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end
end
