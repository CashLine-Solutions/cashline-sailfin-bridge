# cashline-ontology

Rails 8 app for extracting, profiling, and visualizing the Sailfin (Salesforce-based AR) data model — input to the future cashline platform's ontology design.

See `docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md` for the product brief and `docs/plans/2026-05-23-001-feat-sailfin-extraction-and-phase-1-ui-plan.md` for the implementation plan.

## Current status

**Phase A complete** — Rails skeleton + Rails 8 authentication + Pundit + append-only audit log. Subsequent phases (Salesforce client, extraction, profiling, UI views, run diff) are planned but not yet implemented; see the plan document for the unit list.

## Quickstart (development)

Prerequisites:
- Ruby 3.3+
- PostgreSQL 14+ running locally (homebrew default works)

```bash
bundle install
bin/rails db:create db:migrate

# Seed an initial admin (uses a generated password if PASSWORD env unset)
bin/rails users:create_admin EMAIL=you@example.com

bin/rails server
```

Sign in at `http://localhost:3000/session/new`.

## Architecture (Phase A)

Three Postgres databases (configured in `config/database.yml`):

| Database | Purpose |
|---|---|
| `cashline_ontology_development` | Primary app data (users, sessions, future schema rows, GoodJob queue) |
| `cashline_ontology_development_cache` | Solid Cache backend (Rails.cache; will host Salesforce token cache in Phase B) |
| `cashline_ontology_development_audit` | Append-only `audit_events`; in production has separate Postgres roles |

Background jobs run on **GoodJob 4.x** (Postgres-native). Dashboard mounted at `/jobs`, gated to admin users via `AdminConstraint`.

Authorization via **Pundit**; policies live in `app/policies/`. The `User` model has a `role` enum (`read_only`, `analyst`, `admin`) plus a `sensitive_data_access` boolean — both audited on change.

Schema dumps use SQL format (`db/structure.sql`, `db/audit_structure.sql`) so custom Postgres DDL (the audit trigger) is preserved.

## Audit log

`audit_events` is append-only with two enforcement layers:
- **Model**: `AuditEvent#update` and `#destroy` raise `ActiveRecord::ReadOnlyRecord`
- **Database**: a `BEFORE UPDATE OR DELETE` trigger raises an exception, catching anything that bypasses ActiveRecord

In production, the audit DB also uses two Postgres roles — `cashline_audit_owner` (for migrations) and `cashline_audit_writer` (Rails runtime, INSERT/SELECT only). Provisioning:

```bash
# Run once as a Postgres superuser
AUDIT_DB=cashline_ontology_production_audit \
AUDIT_OWNER_PASSWORD=... \
AUDIT_WRITER_PASSWORD=... \
POSTGRES_SUPERUSER_URL=postgres://postgres@host/postgres \
  bin/rails audit:provision_roles

# After audit migrations land:
AUDIT_DB=... AUDIT_OWNER_URL=... bin/rails audit:apply_writer_grants

# Verify writer cannot UPDATE/DELETE:
AUDIT_WRITER_URL=... bin/rails audit:smoke
```

## Tests

```bash
bin/rails test
```

## What's not here yet (per the plan)

- Salesforce JWT Bearer auth (Phase B, Units 5–6)
- API limits check (Unit 7)
- Extraction runs + relational load (Phase C, Units 8–11)
- Sensitivity classifier + profiling (Phase D, Units 12–15)
- UI views: runs / objects / ERDs / graph / reports / diff (Phase E, Units 16–20)
- Run-to-run diff (Phase F, Unit 21)
- Connected App + JWT cert runbook (`docs/runbook/`)
