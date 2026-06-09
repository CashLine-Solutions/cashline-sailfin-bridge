class AddClientGroupToSyncAccountCrosswalks < ActiveRecord::Migration[8.1]
  def change
    # Invoices need a NOT NULL client_group_id; the account importer already knows
    # it (the client side of each account's pairing), so carry it on the crosswalk
    # alongside the customer ids. References the external sync DB, so no FK.
    add_column :sync_account_crosswalks, :client_group_id, :bigint
  end
end
