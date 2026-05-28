# cashline-ontology

Rails 8 app for extracting, profiling, and visualizing the Sailfin (Salesforce-based AR) data model — input to the future cashline platform's ontology design.

See `docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md` for the product brief and `docs/plans/2026-05-23-001-feat-sailfin-extraction-and-phase-1-ui-plan.md` for the implementation plan.

## Current status

**Phases A–F complete** (all 21 implementation units from the plan) plus a polish pass that sharpens the manual-mapping workflow:

| Phase | Coverage |
|---|---|
| **A** Foundation | Rails 8 skeleton, session auth, role-based access (Pundit), append-only audit log (separate DB + trigger) |
| **B** Salesforce client | JWT Bearer auth via Restforce 8, token cache, API limits guard |
| **C** Extraction | `ExtractionRun` model, REST `describe` walker, Tooling API, JSONL run storage, relational loader |
| **D** Profiling | Sensitivity classifier (PII / financial), `ProfileObjectJob`, Bulk 2.0 sampling, redaction policy |
| **E** UI views | Runs / objects / ERDs (Mermaid) / `/visualizations` (force-directed graph + volume × centrality bubble chart + field-fill heatmap, all coloured by cluster, all sharing one JSON endpoint) / hub-orphan + unused-fields / mapping-order reports |
| **F** Diff | `DiffCalculator` + `ComputeDiffJob`, categorized diff UI, Markdown export |
| **Polish** | Sortable + type-filtered fields tables, click-to-expand field detail with prev/next walkthrough, filtered CSV exports pre-seeded with mapping columns, Sailfin scope preset, live profiling progress |

### Mapping workbench (Sailfin → cashline)

A single sortable/filterable grid (`/mappings`) maps the extracted Sailfin schema onto cashline-platform's forward-looking data model — one row per mapping *edge*. It ingests cashline-platform's current schema as a JSON **snapshot** (natural-key target references, so re-snapshotting a moving target doesn't orphan work), supports manual mapping (target picklist, 6-value mapping type, confidence, reviewed flag, notes, 1:N split), structured picklist value→enum mapping, a gap-discovery saved view, and gated CSV export for the downstream test-import loop. An API-free **heuristic matcher** (lexical + type + picklist-overlap) surfaces one-click suggestions, with optional **OpenAI + pgvector embedding** similarity layered on top when configured (see below).

Deferred (gated): the full snapshot-selection UI and categorized re-snapshot reconciliation (both gated on a second snapshot existing) — see `docs/plans/2026-05-27-001-feat-cashline-sailfin-mapping-workbench-plan.md`. The pre-workbench spreadsheet workflow is in [`docs/method/manual-mapping-stopgap.md`](docs/method/manual-mapping-stopgap.md).

#### Embedding suggestions (optional)

Embeddings are an *additive* signal — the heuristic matcher works without them. To enable:

1. **pgvector** must be installed in every Postgres the app touches:
   - dev (Homebrew PG14): `git clone --branch v0.8.2 https://github.com/pgvector/pgvector && cd pgvector && make && make install PG_CONFIG=$(brew --prefix postgresql@14)/bin/pg_config` (the Homebrew `pgvector` bottle ships PG17/18 only).
   - **CI and the production/Kamal Postgres image must also have pgvector** before `db/structure.sql` (which now `CREATE EXTENSION vector`) will load.
2. Add the OpenAI key: `bin/rails credentials:edit` →
   ```yaml
   openai:
     api_key: sk-...
   ```
3. With the key present, the "Compute suggestions" button chains `ComputeEmbeddingsJob` after the heuristic pass. Sensitive (`pii`/`financial`/`unknown_sensitivity`) fields are embedded **metadata-only** (api_name + type, never label/help/values); embeddings degrade to heuristic-only if the key is absent or OpenAI is unreachable.

368 tests, 1095 assertions, 0 failures.

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

## Method

- `docs/method/sailfin-cluster-map.md` — Plain-language guide to the 123 Sailfin objects, organised into 8 clusters with keep/cut judgments. Shareable artifact for talking through the ontology with stakeholders.
- `docs/method/manual-mapping-stopgap.md` — How to use Phases A–F + polish to author the first cashline ontology draft in a spreadsheet + text editor, ahead of the Phase 3 workbench

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

# Mapping workbench (Sailfin → cashline)
bin/rails cashline:export_schema              # (run in cashline-platform) export current schema → JSON + .sha256
bin/rails cashline:load_snapshot FILE=<path>  # ingest that JSON here (verifies the SHA-256 sidecar)
# then open /mappings; "Compute suggestions" runs the heuristic matcher

# Audit DB (production)
bin/rails audit:provision_roles               # create owner + writer roles
bin/rails audit:apply_writer_grants           # grant INSERT/SELECT only on audit_events
bin/rails audit:smoke                         # verify writer cannot UPDATE/DELETE
```
