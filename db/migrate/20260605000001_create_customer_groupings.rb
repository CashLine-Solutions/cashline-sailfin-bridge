class CreateCustomerGroupings < ActiveRecord::Migration[8.1]
  def change
    # A proposed (and then human-confirmed) grouping of multiple Sailfin Accounts
    # under one parent customer — e.g. "BREITBURN OPERATING - GAYLORD" and
    # "BREITBURN OPERATING - HOUSTON" rolling up to "BREITBURN OPERATING".
    #
    # This is curation data the bridge owns for now (built here first, ported to
    # cashline-platform once the UX is refined). The Sailfin → cashline importer
    # will eventually read confirmed groupings to set customer_organization_id /
    # customer_group_id, but never overwrites them on re-sync (operator overlay).
    #
    # State mirrors MappingProposal: open → confirmed/rejected. Detection is
    # idempotent — re-running preserves a grouping's state and only inserts new
    # candidates (we don't re-ask a question the operator already answered).
    create_table :customer_groupings do |t|
      t.references :extraction_run, null: false, foreign_key: true
      t.string :parent_name, null: false             # canonical parent label, e.g. "BREITBURN OPERATING"
      t.string :detection_method, null: false        # name_prefix | structural_parent_no | llm | manual
      t.string :confidence, null: false, default: "medium"  # high | medium | low
      t.string :state, null: false, default: "open"  # open | confirmed | rejected
      t.boolean :user_modified, null: false, default: false

      t.timestamps
    end

    # One grouping per parent label per run; re-detection upserts in place.
    add_index :customer_groupings, [ :extraction_run_id, :parent_name ],
              unique: true, name: "index_customer_groupings_on_run_and_parent"
    add_index :customer_groupings, [ :extraction_run_id, :state ],
              name: "index_customer_groupings_on_run_and_state"

    # Each member is one Sailfin Account, referenced by its 18-char Salesforce Id
    # (the same key the importer's crosswalk columns carry). account_name is
    # denormalized so the review UI lists members without re-reading sf_records.
    create_table :customer_grouping_members do |t|
      t.references :customer_grouping, null: false, foreign_key: true
      t.string :sailfin_account_id, null: false      # Account.Id (18-char)
      t.string :account_name, null: false            # Account.Name verbatim

      t.timestamps
    end

    # An account belongs to at most one grouping per run. Scoped by run via the
    # parent grouping; we enforce uniqueness on the account id within a run using
    # a composite that includes the run through a partial — simplest is a unique
    # index on (customer_grouping_id, sailfin_account_id) plus app-level guard
    # that an account isn't claimed by two groupings in the same run.
    add_index :customer_grouping_members, [ :customer_grouping_id, :sailfin_account_id ],
              unique: true, name: "index_grouping_members_on_grouping_and_account"
    add_index :customer_grouping_members, :sailfin_account_id,
              name: "index_grouping_members_on_account"
  end
end
