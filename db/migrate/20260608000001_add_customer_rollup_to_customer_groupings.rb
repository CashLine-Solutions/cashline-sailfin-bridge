class AddCustomerRollupToCustomerGroupings < ActiveRecord::Migration[8.1]
  def change
    # Roll-up support: a grouping can be nested under a higher-level customer.
    # When customer_name is set, the importer treats the grouping as one GROUP
    # (labeled by group_label) under that customer ORG — e.g. the "KINDER MORGAN
    # / NGPL" grouping becomes group "NGPL" under customer "KINDER MORGAN".
    # When customer_name is null the grouping is its own org (today's behavior).
    add_column :customer_groupings, :customer_name, :string
    add_column :customer_groupings, :group_label, :string

    # Lets the importer (and the "rolled up under X" UI) find all groupings that
    # share a customer without scanning the whole run.
    add_index :customer_groupings, [ :extraction_run_id, :customer_name ],
              name: "index_customer_groupings_on_run_and_customer"
  end
end
