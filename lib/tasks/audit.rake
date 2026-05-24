namespace :audit do
  desc <<~DESC.squish
    Provision the audit DB Postgres roles and grants for production.
    Run as a Postgres superuser. Idempotent.
    Required env: AUDIT_DB (e.g., cashline_ontology_production_audit),
                  AUDIT_OWNER_PASSWORD, AUDIT_WRITER_PASSWORD.
  DESC
  task :provision_roles do
    require "pg"

    db = ENV.fetch("AUDIT_DB")
    owner_pw = ENV.fetch("AUDIT_OWNER_PASSWORD")
    writer_pw = ENV.fetch("AUDIT_WRITER_PASSWORD")

    superuser_url = ENV.fetch("POSTGRES_SUPERUSER_URL") # e.g., postgres://postgres@localhost:5432/postgres

    conn = PG.connect(superuser_url)

    sql = <<~SQL
      DO $$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cashline_audit_owner') THEN
          CREATE ROLE cashline_audit_owner LOGIN PASSWORD '#{owner_pw.gsub("'", "''")}';
        ELSE
          ALTER ROLE cashline_audit_owner WITH PASSWORD '#{owner_pw.gsub("'", "''")}';
        END IF;

        IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cashline_audit_writer') THEN
          CREATE ROLE cashline_audit_writer LOGIN PASSWORD '#{writer_pw.gsub("'", "''")}';
        ELSE
          ALTER ROLE cashline_audit_writer WITH PASSWORD '#{writer_pw.gsub("'", "''")}';
        END IF;
      END $$;

      ALTER DATABASE #{conn.escape_identifier(db)} OWNER TO cashline_audit_owner;
    SQL

    conn.exec(sql)
    conn.close
    puts "Roles provisioned. Now run `bin/rails db:migrate:audit` as cashline_audit_owner."
  end

  desc <<~DESC.squish
    Apply runtime grants: writer role gets INSERT/SELECT only on audit_events.
    Run AFTER migrations have created the table, as the audit DB owner.
    Required env: AUDIT_DB.
  DESC
  task :apply_writer_grants do
    require "pg"

    db = ENV.fetch("AUDIT_DB")
    owner_url = ENV.fetch("AUDIT_OWNER_URL") # owner role connection string

    conn = PG.connect(owner_url)

    sql = <<~SQL
      REVOKE ALL ON audit_events FROM cashline_audit_writer;
      GRANT INSERT, SELECT ON audit_events TO cashline_audit_writer;
      GRANT USAGE, SELECT ON SEQUENCE audit_events_id_seq TO cashline_audit_writer;
    SQL

    conn.exec(sql)
    conn.close
    puts "Writer role has INSERT/SELECT only on audit_events."
  end

  desc "Smoke test: assert the writer role cannot UPDATE/DELETE audit_events"
  task smoke: :environment do
    require "pg"
    writer_url = ENV.fetch("AUDIT_WRITER_URL")
    conn = PG.connect(writer_url)

    begin
      conn.exec("UPDATE audit_events SET action = 'tampered' WHERE id = 0")
      abort "FAIL: writer role was permitted to UPDATE audit_events"
    rescue PG::InsufficientPrivilege, PG::RaiseException => e
      puts "OK: writer role denied UPDATE (#{e.class})"
    end

    begin
      conn.exec("DELETE FROM audit_events WHERE id = 0")
      abort "FAIL: writer role was permitted to DELETE audit_events"
    rescue PG::InsufficientPrivilege, PG::RaiseException => e
      puts "OK: writer role denied DELETE (#{e.class})"
    ensure
      conn.close
    end
  end
end
