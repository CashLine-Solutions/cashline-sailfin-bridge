class CreateSyncAccountCrosswalks < ActiveRecord::Migration[8.1]
  def change
    # Build-time crosswalk emitted by the Account importer: every active Sailfin
    # Account id -> the sync-DB customer_account (+ group/org) it landed in,
    # including accounts collapsed into another's pairing. Downstream importers
    # (contacts now, invoices later) resolve a Sailfin AccountId to the correct
    # rolled-up / merged customer through this, instead of re-deriving the
    # account importer's logic. customer_* ids reference the EXTERNAL sync DB, so
    # no FKs here (cross-database).
    create_table :sync_account_crosswalks do |t|
      t.references :extraction_run, null: false, foreign_key: true
      t.string :sailfin_account_id, null: false
      t.bigint :customer_account_id, null: false
      t.bigint :customer_organization_id, null: false
      t.bigint :customer_group_id, null: false
      t.timestamps
    end

    # One row per (run, Sailfin account); the importer full-refreshes per run.
    add_index :sync_account_crosswalks, [ :extraction_run_id, :sailfin_account_id ],
              unique: true, name: "index_sync_account_crosswalks_on_run_and_account"
  end
end
