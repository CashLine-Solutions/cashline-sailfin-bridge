class ObjectProfile < ApplicationRecord
  STATUSES = %w[pending complete failed].freeze

  belongs_to :extraction_run
  belongs_to :sobject
  has_many :field_profiles, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
end
