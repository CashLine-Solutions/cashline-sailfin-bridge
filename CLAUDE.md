# CLAUDE.md

Orientation for agents working in this repo. Keep it short; prefer the code and
`docs/solutions/` for detail.

## What this is

A Rails 8.1 "bridge" that imports Salesforce/**Sailfin** data into an **external
cashline-platform "sync" database**. The bridge reads `sf_records` (raw Sailfin
payloads per extraction run), lets an operator curate **customer groupings**
(parent roll-ups), then runs importers that write canonical rows into the sync DB
for the cashline-platform app to read.

## Architecture notes

- **Two databases.** The bridge's own primary/cache/audit DBs, plus a separate
  `cashline_sync` connection pointing at the external platform DB. `cashline_sync`
  is `database_tasks: false` (Rails never migrates or creates it; the platform owns
  its schema). Models under `CashlineSync::` (`CashlineSyncRecord` base) write there.
- **Importers** live under `app/services/sync/` (`Sync::AccountImporter`,
  `Sync::ContactImporter`, …) and run as a **per-operator full refresh in one
  transaction** (purge then rebuild) — re-runs are an exact mirror, no orphans.
- **Record collapse + crosswalk.** The Account importer collapses many Sailfin
  accounts into one `customer_account` (per customer×client pairing) and rolls
  accounts up under shared customers. It emits `SyncAccountCrosswalk` (every source
  account id → the `customer_account` it landed in) so downstream importers route
  to the correct rolled-up/merged customer. See the best-practices learning below.

## Commands

- `RUN=<id> bin/rails cashline_sync:import_all` — accounts → contacts in order (safe one-shot).
- `bin/rails -T cashline_sync` — all sync import/detect tasks.
- `bin/rails test` — full suite. Sync-DB integration tests self-skip unless
  `cashline_sailfin_sync_test` is provisioned (they don't run in CI by default).

## Documented Solutions

`docs/solutions/` — documented solutions to past problems (bugs, best practices,
workflow patterns), organized by category with YAML frontmatter (`module`, `tags`,
`problem_type`). Relevant when implementing or debugging in documented areas —
e.g. the importer crosswalk pattern and the multi-database test-fixtures gotcha
both live there.
