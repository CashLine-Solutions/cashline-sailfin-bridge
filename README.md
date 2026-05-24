# cashline-ontology

Rails 8 app for extracting, profiling, and visualizing the Sailfin (Salesforce-based AR) data model — input to the future cashline platform's ontology design.

See `docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md` for the product brief and `docs/plans/2026-05-23-001-feat-sailfin-extraction-and-phase-1-ui-plan.md` for the implementation plan.

## Current status

**Phases A–F complete** (all 21 implementation units from the plan):

| Phase | Coverage |
|---|---|
| **A** Foundation | Rails 8 skeleton, session auth, role-based access (Pundit), append-only audit log (separate DB + trigger) |
| **B** Salesforce client | JWT Bearer auth via Restforce 8, token cache, API limits guard |
| **C** Extraction | `ExtractionRun` model, REST `describe` walker, Tooling API, JSONL run storage, relational loader |
| **D** Profiling | Sensitivity classifier (PII / financial), `ProfileObjectJob`, Bulk 2.0 sampling, redaction policy |
| **E** UI views | Runs / objects / ERDs (Mermaid) / force-directed graph (Cytoscape) / hub-orphan + unused-fields reports |
| **F** Diff | `DiffCalculator` + `ComputeDiffJob`, categorized diff UI, Markdown export |

Phase 3 (mapping workbench, FIBO suggestions, Turtle export) is deferred to a future plan.

178 tests, 457 assertions, 0 failures.

## Quickstart (development)

Prerequisites:
- Ruby 3.3+
- PostgreSQL 14+ running locally

```bash
bundle install
bin/rails db:create db:migrate
bin/rails users:create_admin EMAIL=you@example.com
bin/rails server
```

Sign in at `http://localhost:3000/session/new`.

## Try it without Salesforce credentials

Seed two fake extraction runs to preview the full UI end-to-end:

```bash
bin/rails ontology:demo_data
```

This creates a baseline run and a "delta" run with a known set of differences (a new object, a new field, a picklist change, a formula change, a length change, a new relationship). Useful for:

- Verifying Cytoscape, Mermaid, and Turbo Streams render in your browser
- Trying the diff UI and Markdown export
- Walking a designer through the views before real extraction

Open `/runs`, then explore. To wipe and re-seed:

```bash
bin/rails ontology:demo_data RESET=1
```

## Connecting to Salesforce

See `docs/runbook/salesforce-connected-app.md` for the one-time External Client App setup. After credentials are wired:

```bash
bin/rails sailfin:smoke         # verify JWT + basic API connectivity
bin/rails sailfin:namespaces    # histogram of all visible objects by namespace prefix
bin/rails sailfin:limits        # current API quota snapshot
```

`sailfin:namespaces` is the right way to discover what Sailfin's managed-package namespace prefix is before triggering a real extraction. Use that output to update `RunsController::PRESET_SEED_OBJECTS` or pass a custom seed list via `/runs/new`.

## Architecture

Three Postgres databases (configured in `config/database.yml`):

| Database | Purpose |
|---|---|
| `cashline_ontology_development` | Primary app data (users, sessions, runs, sobjects, sfields, profiles, clusters, diffs, GoodJob queue) |
| `cashline_ontology_development_cache` | Solid Cache backend (Rails.cache; Salesforce token cache) |
| `cashline_ontology_development_audit` | Append-only `audit_events`; in production has separate Postgres roles (see `docs/runbook/audit-db.md`) |

Background jobs run on **GoodJob 4.x** (Postgres-native). Dashboard mounted at `/jobs`, gated to admin users via `AdminConstraint`.

Authorization via **Pundit**; policies live in `app/policies/`. The `User` model has a `role` enum (`read_only`, `analyst`, `admin`) plus a `sensitive_data_access` boolean — both audited on change.

Schema dumps use SQL format (`db/structure.sql`, `db/audit_structure.sql`) so custom Postgres DDL (the audit trigger) is preserved.

## Runbooks

- `docs/runbook/salesforce-connected-app.md` — External Client App + JWT cert setup, credentials format, smoke test
- `docs/runbook/audit-db.md` — Audit DB roles, provisioning, retention, tampering forensics
- `docs/runbook/run-storage.md` — Run directory layout, sensitive-run handling, retention, rebuild commands

## Tests

```bash
bin/rails test
```

## Operations cheat sheet

```bash
# Daily ops
bin/rails ontology:demo_data RESET=1          # reset + reseed demo runs
bin/rails sailfin:smoke                       # verify Salesforce connectivity
bin/rails sailfin:namespaces                  # inspect org's object namespaces
bin/rails sailfin:limits                      # current API quota
bin/rails users:create_admin EMAIL=...        # provision an admin
bin/rails users:list                          # list users + roles
bin/rails runs:rebuild_db RUN=<token>         # rebuild relational tables from on-disk JSONL

# Audit DB (production)
bin/rails audit:provision_roles               # create owner + writer roles
bin/rails audit:apply_writer_grants           # grant INSERT/SELECT only on audit_events
bin/rails audit:smoke                         # verify writer cannot UPDATE/DELETE
```
