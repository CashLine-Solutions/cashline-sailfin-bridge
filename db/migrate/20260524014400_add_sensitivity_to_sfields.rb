class AddSensitivityToSfields < ActiveRecord::Migration[8.1]
  def change
    add_column :sfields, :sensitivity, :string, null: false, default: "unknown_sensitivity"
    add_column :sfields, :sensitivity_signals, :jsonb, null: false, default: []
    add_index :sfields, :sensitivity
  end
end
