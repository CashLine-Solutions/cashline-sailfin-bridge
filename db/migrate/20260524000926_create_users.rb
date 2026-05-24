class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      # 0 = read_only (default), 1 = analyst, 2 = admin
      t.integer :role, null: false, default: 0
      # Gates triggering and viewing of sensitive (PII/financial) data —
      # checked in both controllers and jobs. Changes are audited (see Unit 4).
      t.boolean :sensitive_data_access, null: false, default: false

      t.timestamps
    end
    add_index :users, :email_address, unique: true
    add_index :users, :role
  end
end
