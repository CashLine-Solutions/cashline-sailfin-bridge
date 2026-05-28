class AddComplianceToSfields < ActiveRecord::Migration[8.1]
  def change
    # Admin-declared field metadata from Tooling-API FieldDefinition. These are
    # the authoritative PII/sensitivity signals; the heuristic classifier only
    # fills the gap when an admin left them blank.
    add_column :sfields, :compliance_group, :string
    add_column :sfields, :security_classification, :string
  end
end
