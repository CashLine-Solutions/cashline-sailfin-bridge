class CreateAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_events do |t|
      t.bigint :user_id
      t.string :action, null: false
      t.string :subject_type
      t.bigint :subject_id
      t.jsonb :params, null: false, default: {}
      t.string :ip
      t.string :user_agent, limit: 500

      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_index :audit_events, [ :user_id, :created_at ]
    add_index :audit_events, [ :action, :created_at ]
    add_index :audit_events, [ :subject_type, :subject_id ]

    # Append-only enforcement at the DB layer. Catches direct SQL access by
    # tools that bypass the AuditEvent model layer.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          CREATE OR REPLACE FUNCTION audit_events_block_modification()
          RETURNS trigger AS $$
          BEGIN
            RAISE EXCEPTION 'audit_events is append-only';
          END;
          $$ LANGUAGE plpgsql;

          CREATE TRIGGER audit_events_no_modify
            BEFORE UPDATE OR DELETE ON audit_events
            FOR EACH ROW
            EXECUTE FUNCTION audit_events_block_modification();
        SQL
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS audit_events_no_modify ON audit_events;
          DROP FUNCTION IF EXISTS audit_events_block_modification();
        SQL
      end
    end
  end
end
