# One Sailfin Account belonging to a CustomerGrouping, keyed by its 18-char
# Salesforce Id (the same key the importer's sailfin_account_id crosswalk
# carries). account_name is denormalized for display in the review UI.
class CustomerGroupingMember < ApplicationRecord
  belongs_to :customer_grouping

  validates :sailfin_account_id, :account_name, presence: true
end
