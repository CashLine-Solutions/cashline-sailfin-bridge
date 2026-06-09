# Build-time map from a Sailfin Account id to the sync-DB customer_account it was
# imported into (after roll-up / merge / pairing collapse). Emitted by
# Sync::AccountImporter, read by Sync::ContactImporter (and the future invoice
# importer) so downstream rows attach to the correct rolled-up customer.
class SyncAccountCrosswalk < ApplicationRecord
  belongs_to :extraction_run

  validates :sailfin_account_id, presence: true
end
