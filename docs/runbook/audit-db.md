# Audit Database Operations

cashline-ontology writes a tamper-resistant audit log to a separate Postgres database. This document covers provisioning, ongoing operations, and emergency recovery.

## Why a separate database

The `audit_events` table has two enforcement layers preventing tampering:

1. **Model-level** — `AuditEvent#update` and `#destroy` raise `ActiveRecord::ReadOnlyRecord`.
2. **Database-level** — a `BEFORE UPDATE OR DELETE` trigger on `audit_events` raises an exception, catching anything that bypasses ActiveRecord (rake tasks, `psql`, raw SQL in jobs).

In production, the audit DB is owned by `cashline_audit_owner` (used only for migrations and grant management) and written by `cashline_audit_writer` (the runtime Rails role, which has INSERT/SELECT only on `audit_events`). Even with a Rails RCE, an attacker cannot tamper with the existing audit trail.

In development, all three databases run as your local user and the trigger is the only protection. That's fine for dev because the threat model assumes a trusted developer.

## First-time provisioning (production)

These steps run **once**, by a Postgres superuser. They create the dedicated roles and grants.

```bash
AUDIT_DB=cashline_ontology_production_audit \
AUDIT_OWNER_PASSWORD=<strong-password> \
AUDIT_WRITER_PASSWORD=<strong-password> \
POSTGRES_SUPERUSER_URL=postgres://postgres@host/postgres \
  bin/rails audit:provision_roles
```

This creates:
- Role `cashline_audit_owner` (owns the audit DB; used for migrations).
- Role `cashline_audit_writer` (Rails runtime; INSERT/SELECT only after grants applied in step 2).

Then connect as `cashline_audit_owner` and run migrations:

```bash
AUDIT_OWNER_URL=postgres://cashline_audit_owner:<password>@host/cashline_ontology_production_audit \
  bin/rails db:migrate:audit
```

Then apply the writer's restricted grants:

```bash
AUDIT_DB=cashline_ontology_production_audit \
AUDIT_OWNER_URL=postgres://cashline_audit_owner:<password>@host/cashline_ontology_production_audit \
  bin/rails audit:apply_writer_grants
```

Finally, verify the writer cannot tamper:

```bash
AUDIT_WRITER_URL=postgres://cashline_audit_writer:<password>@host/cashline_ontology_production_audit \
  bin/rails audit:smoke
```

Expected output (two lines):

```
OK: writer role denied UPDATE (PG::InsufficientPrivilege)
OK: writer role denied DELETE (PG::InsufficientPrivilege)
```

## Production configuration

In `config/database.yml`, the `audit` connection points at `ENV["AUDIT_WRITER_URL"]`. Rails opens this connection with INSERT/SELECT-only privileges; any code path that tries to update or delete an audit row will raise. Never grant the runtime role broader privileges.

## What gets audited

Audit events are written for:
- `user.sign_in`, `user.sign_out`, `user.password_reset` (in `SessionsController`, `PasswordsController`)
- `user.privilege_changed` (auto-fired from `User#after_update_commit` when `role` or `sensitive_data_access` changes)
- `run.trigger` (in `RunsController#create`)
- `run.sensitive_view` (when a privileged user opens a sensitive run's details — not yet wired; see open question in plan)
- `run.purge` (from `PurgeExpiredSensitiveRunsJob`)

Each event captures `actor_user_id`, `action`, `subject_type`/`subject_id`, `params` (jsonb), `request_ip`, `request_user_agent`, and `created_at`.

## Retention

The plan defaults to **1 year** retention. There is no automatic purge today — once partitioned by month, drop partitions older than the retention window. For v0.1, expect this to be a manual operation if storage pressure becomes an issue (audit row volume is small).

## Recovering from a failed migration

If a migration to the audit DB fails halfway:

1. Connect as `cashline_audit_owner` (not the writer).
2. Inspect with `bin/rails db:migrate:status:audit`.
3. Re-run the failed migration manually.
4. If the trigger is missing after migration (rare), re-apply it from `db/audit_structure.sql`.

## Cert/role rotation

Roles need rotation roughly yearly:

```bash
# As superuser, alter the writer password
ALTER ROLE cashline_audit_writer WITH PASSWORD '<new-password>';

# Update AUDIT_WRITER_URL in your deployment secrets store.
# Restart Rails to pick up the new password. Existing audit rows are unaffected.
```

Do not rotate `cashline_audit_owner` without also confirming nothing besides migration tooling references it.

## Emergency: I need to inspect tampering attempts

The audit DB itself has a Postgres-level log of any `UPDATE`/`DELETE` attempt (they fail with the trigger's `RAISE EXCEPTION 'audit_events is append-only'`). Check Postgres logs (`/var/log/postgresql/`) for occurrences of that string.

If you find one, the offending caller is in the Rails stack trace within that log line. Investigate before doing anything else.

## Schema dumps

The audit DB schema is captured separately in `db/audit_structure.sql` (SQL format, not Ruby format). This preserves the trigger definition, which `schema.rb` would lose. Never edit this file by hand — re-generate via `bin/rails db:migrate` or `bin/rails db:schema:dump:audit`.
