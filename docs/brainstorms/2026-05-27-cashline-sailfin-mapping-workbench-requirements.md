---
date: 2026-05-27
topic: cashline-sailfin-mapping-workbench
---

# Cashline ⇄ Sailfin Mapping Workbench

## Problem Frame

cashline-platform is being designed as the **ideal forward-looking AR data model** — deliberately fixing Sailfin's structural problems, not inheriting them. The cashline structure is **still being designed**, and Sailfin's data is one of the inputs to that design.

The end-to-end process the workbench supports:

1. **Design support.** Use the extracted Sailfin schema + production profiles to inform the cashline structure — especially to surface **actively-used Sailfin data that hasn't come up in user interviews** (gap discovery). This is the *first* and *primary early* use.
2. **Mapping.** Once a piece of the cashline structure is settled, map the relevant Sailfin fields/values onto it.
3. **Test-import loop.** Export the mapping, run a test import into a copy of the cashline database, assess how well it worked, refine the mapping, re-import, reassess — loop until the import is clean.
4. **Ongoing sync.** Once structure + mapping are solid, stand up an ongoing Sailfin → cashline sync, until Sailfin is disconnected months later.

This brief covers the workbench for steps 1–2 and the artifact it hands to step 3. Steps 3–4 (the importer, the sync engine) are separate efforts in cashline-platform.

Because of the volume (~30+ objects, hundreds of fields, `sfsrm__Transaction__c` alone at 2.17M rows), **LLM-assisted candidate mapping that the user reviews is core to v1, not a later enhancement** — manual mapping at this scale is infeasible.

This brief supersedes the deferred Phase 3 brief in `docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md` (R15–R19), which assumed an OWL/Turtle authoring exercise.

## Key Framing Decisions (read first)

- **The cashline ontology is the cashline-platform Rails models** (introspected via snapshot), not an OWL/Turtle artifact authored here. No Turtle export in v1.
- **Map against what cashline-platform has *now*, and tolerate it evolving.** Today that is a flat `invoices` table (no STI). The current cashline schema is **mutable draft progress — not precious.** It is *expected* to change in response to what the mapping/gap-discovery work reveals: the workbench surfaces an actively-used Sailfin concept with no home → the team adjusts the cashline draft (a migration in cashline-platform) → re-snapshot → continue mapping. The target and the mapping **co-evolve**, which is exactly why re-snapshot + natural-key references are load-bearing rather than edge cases. As the design firms up — including any future refactor like the proposed `ARPosting` split — re-snapshot and the new classes/fields appear as ordinary targets. **The workbench does not hard-code, and is not built around, any specific or not-yet-existing target structure.**
- **No discriminator-conditional mapping in v1.** An earlier draft invented an `applies_when` predicate (e.g. "maps to `due_at` only when kind=invoice") to handle one Sailfin object splitting into multiple cashline subtypes by a derived discriminator. That target structure doesn't exist yet, the discriminator would be derived by the migration itself (chicken-and-egg), and it exploded the row count. Removed from v1. If the cashline design later introduces subtypes, conditional mapping is revisited then.
- **The workbench surfaces gaps; it does not author the cashline target.** New cashline classes/columns are created by writing migrations in cashline-platform and re-snapshotting.

## Approach

**A single sortable, filterable table — the mapping grid.** One row per *mapping edge*. Reuses the existing `/objects` filter-chip + sortable-table + field-detail infrastructure. One surface, not side-by-side panels.

Each row: Sailfin source, cashline target (set via a picklist), mapping type, confidence, notes, a `reviewed` flag, and an **LLM/heuristic suggestion button to the right** that applies a suggested target into the row's picklist. A row expands to a value-level sub-table when both sides are enumerated (picklist ⇄ enum).

## Mapping Cardinality

Real cases the store must support (all without a discriminator predicate):

- **N:1 collapse.** Many Sailfin fields → one cashline field (e.g. several overlapping date columns → one `expected_payment_at`; two `PO_Number` fields → one target, brand-chosen at import). Shows as multiple rows sharing a target; a group-by-target view makes the collapse visible.
- **1:N split.** One Sailfin field → multiple cashline fields (e.g. `sfsrm__Status__c` → an `approval_state` field *and* a `collections_state` field). Shows as multiple rows for the same source, added via a "split" affordance.
- **Value-level N:1 collapse.** Picklist *values* collapse (e.g. `Apply Cash` + `Auto Applied` + `Applied` → one target value + an `auto_applied` note). Captured in the value-level sub-table (M4).

**Grid read-model (resolve before planning, not a deferred detail):** the grid is `sfields LEFT JOIN mapping_entries` UNION the source-less `mapping_entries` (the `net_new` rows). A field with no mapping is one row, empty target. This join/union shape is the core read model and must be settled before M2.

## Pipeline Overview

```
┌──────────────────────────┐         ┌──────────────────────────────┐
│  cashline-ontology DB    │         │  cashline-platform (Rails)   │
│  Sailfin extraction +    │         │  bin/rails cashline:export   │
│  field_profiles populated│         │  AR introspection of CURRENT │
└────────────┬─────────────┘         │  schema → JSON: tables, cols,│
             │                       │  comments, AR enums, assoc   │
             │                       └────────────┬─────────────────┘
             │                                    │ JSON snapshot + SHA-256
             ▼                                    ▼
   ┌─────────────────────────────────────────────────────┐
   │  cashline-ontology DB (new)                         │
   │  • cashline_snapshots (schema_json jsonb, sha256)   │
   │  • mapping_entries (edge rows; natural-key target)  │
   │  • mapping_value_entries (picklist value ⇄ enum)    │
   │  • mapping_proposals (heuristic + pgvector embed)   │
   └────────────────────────────┬────────────────────────┘
                                │
                                ▼
   ┌─────────────────────────────────────────────────────┐
   │  /mappings — the mapping grid                       │
   │  • One sortable/filterable table, data-group column │
   │  • Picklist target + suggest button per row         │
   │  • Row expands → picklist value-level mapping       │
   │  • Gap-discovery view (design support)              │
   │  • CSV export → feeds the test-import loop          │
   └─────────────────────────────────────────────────────┘
```

## Requirements

### M1 — Cashline schema snapshot (current schema)

- **R1.** A rake task `bin/rails cashline:export_schema` in cashline-platform writes a timestamped JSON snapshot of the **current** schema via Active Record introspection (`Rails.application.eager_load!`), reading model + `db/schema.rb` state (cashline-platform uses the Ruby schema format, not `structure.sql`): table name, namespace (model dir), columns (name, sql_type, null, default, comment), Active Record enum mappings, and associations. **No STI / per-subtype handling in v1** — the current target has no STI; add it only if/when the design introduces it.
- **R2.** The exporter writes a sidecar SHA-256 manifest. The loader `bin/rails cashline:load_snapshot PATH=...` verifies the hash before inserting and records an `AuditEvent` (`cashline_snapshot.loaded`, `user: nil`, path + hash).
- **R3.** Loads into `cashline_snapshots(id, loaded_at, sha256, schema_json jsonb)` — a single JSONB document. `mapping_entries` reference targets by **natural key** `(class_name, field_name)`, never surrogate FK. Re-snapshotting is expected and frequent (the target is under active design). On re-snapshot, a mapping whose target natural key is absent from the new snapshot is flagged for review (a `reviewed=false` + `target_missing` state), surfaced in a banner on session open. (Note: a large rename — e.g. a future `invoices → ar_postings`/subtype refactor — will look like target deletion + creation; those mappings surface for re-review. Accepted tradeoff.)
- **R4.** A workbench session is `(sailfin_run_id, cashline_snapshot_id)`, selectable the way an `ExtractionRun` already is.

### M2 — The mapping grid

- **R5.** A view at `/mappings` renders one sortable, filterable table. Columns: **Data Group** (Sailfin cluster), Sailfin Object, Sailfin Field, **Population** (`field_profiles` null % + distinct count), **Mapping Type**, **Target** (cashline `class.field`, set via picklist), Confidence, **Reviewed**, Notes, **suggest button**.
- **R6.** The target picklist is populated from the active cashline snapshot, grouped by model namespace, **typeahead-filtered** (hundreds of fields), displaying `Class.field` plus the human label. When a previously-selected target is missing after re-snapshot, the cell shows the stale value with a "target missing — re-pick" state.
- **R7.** Clicking the suggest button applies the top suggested target into the row's picklist; the user keeps, changes, or clears it.
- **R8.** The existing `/objects` field-detail panel (population stats, picklist values, formula, sensitivity) is reachable inline from a row so the reviewer has full evidence without leaving the grid.
- **R9.** Default grouping/sort: Data Group → Sailfin Object. Every column sortable. **Group-by-target** is a view toggle that gives the N:1 collapse view. 1:N split rows are visually grouped under their shared source (row-span / indent) so sequential per-field review stays coherent.

### M3 — Mapping records and types

- **R10.** Each `mapping_entry` is one edge: `source_field` (nullable — empty for `net_new`), `target` natural key (nullable — empty for `dropped`/`derived`/unreviewed), `mapping_type`, `confidence` (`low`/`medium`/`high`), `reviewed` (boolean), `transformation_note` (free text for the *transform*, never for value mappings), `source_citation` (optional), `needs_crosswalk` (boolean — per-tenant/brand resolution required at import).
- **R11.** `mapping_type` ∈ `direct` / `value_collapse` (N:1 values) / `split` (1:N) / `derived` (target computed, no stored source) / `dropped` (intentionally not migrated, e.g. formula fields) / `net_new` (cashline field with **no** Sailfin source). A row not yet worked has `reviewed=false` and (usually) no type — this replaces the previous `blocked`/`metadata_carry` types, which the `reviewed` flag + empty target + a note now cover.
- **R12.** `net_new` means **no** Sailfin source at all. A cashline field that has even a partial Sailfin source is an ordinary mapping (`direct`/`split`) whose coverage may be incomplete — note that in `transformation_note`. `source_citation` is required when `mapping_type = net_new`, since there's no source to evidence the field.
- **R13.** Every write path calls `AuditEvent.record!` explicitly (no `audited` gem here; `AuditEvent.record!(subject:)` already supports any `ApplicationRecord` — no schema change needed). Changing `mapping_type` to `dropped` on a PII/financial-sensitive Sailfin field uses a distinct audit action (`mapping.sensitivity_downgrade`) recording old/new type, sensitivity, and actor.

### M4 — Picklist value-level mapping (in v1, structured, no free text)

- **R14.** When a Sailfin field is a picklist and its target is an enum-bearing cashline field, the row expands to a value-mapping sub-table: one row per source value → target enum value, supporting N:1 and a `drop`/`derive` target for values with no enum home. Value mappings are **structured records, never free text**, so the import is deterministic. `mapping_value_entries` reference the target enum value by natural key and use the same re-snapshot reconciliation as R3 (a removed/renamed enum value flags the value row for re-review).
- **R15.** Source picklist values render with their in-data frequency (matched from `field_profiles.top_values`) so dead values (~91% of declared picklist values are unused) are de-prioritized and live ones (e.g. a 48-value deduction reason code) surface. In-data values that aren't in the declared picklist (restricted-vs-unrestricted, the "extra" status values) also get rows.

### M5 — Suggestions: heuristics first, embeddings second

- **R16.** **M5a (ships first):** cheap, no-API matching — lexical/token similarity on `(api_name, label)`, data-type compatibility, and picklist-value overlap. Stored in `mapping_proposals.signals`. This is the primary matcher because many real mappings are lexical (`Due Date` ⇄ `due_date`) and Sailfin managed-package api_names (`sfsrm__…__c`) carry weak semantic signal. It has no API dependency, no PII-transmission concern, and no embedding-storage decision — so it de-risks the whole feature.
- **R17.** **M5b (adds value if M5a leaves gaps):** OpenAI embeddings stored/queried via **pgvector**, over each side's `(api_name, label, data_type)` plus any field description (Sailfin help text pulled from `raw_describe`; cashline column comment where present). Top-N candidates per Sailfin field in `mapping_proposals`, keyed by `(sailfin_field_id, cashline_snapshot_id)`, with the heuristic signals as cross-check.
- **R18.** Suggestions never auto-apply (R7). Accepting promotes a proposal to the row's target; rejecting is recorded and suppressed from future passes. A **per-session proposal-acceptance counter** is displayed on the grid (this is the lightweight signal that tells us whether suggestions are pulling their weight; the real quality measure is the test-import loop, below).
- **R19.** Suggestions are suppressed on `net_new` targets (no source to match) and down-weighted on dead picklist values.
- **R20.** **PII/financial gate — covers labels, descriptions, AND values.** For Sailfin fields tagged `pii` or `financial`, neither the label/description (R17) nor the picklist *values* (R17 value-level suggestions, if built) are transmitted to OpenAI unless the user has `sensitive_data_access`; only structural metadata (api_name pattern, data_type, value cardinality) is used. The check is re-evaluated **at transmission time from the field's current sensitivity attribute**, not from a job-enqueue parameter (so it can't be bypassed by job replay or a privilege-change race). Embeddings cached for sensitive fields inherit the sensitive-run retention policy. **Value-level LLM suggestions are deferred** until field-level (R17) proves useful; the M4 value sub-table is manual + heuristic in v1.

### M6 — Filtering, hiding, and gap discovery (design support)

- **R21.** Reuse `/objects` Sailfin-side chips (namespace, Custom only, Has PII/Financial, Min fields, data_type). Add grid chips that work from day one: `Reviewed` / `Unreviewed`, `Mapped` / `Unmapped`, `Net-new`, `Needs crosswalk`, `Has suggestion`, and filter by `mapping_type`. (Target-structure-specific filters — by subtype, state lane, etc. — are deferred until a target structure that needs them exists.)
- **R22.** **Gap-discovery view (primary early use).** A saved filter for **high `field_profiles` population AND reviewed=true AND no cashline home** (`dropped`/`net_new`-adjacent, or no candidate above threshold) — i.e. actively-used Sailfin data a human confirmed has no place in the current cashline design. This discriminates (unlike raw "unmapped", where every field starts unmapped) and is the signal that feeds back into cashline structure design. A companion "unreviewed, high-population" worklist prioritizes what to review next.
- **R23.** All filter combinations are URL-bookmarkable, matching `/objects`.

### M7 — Export (feeds the test-import loop)

- **R24.** One CSV per cashline model plus a combined CSV. Columns: `cashline_class`, `cashline_field`, `cashline_type`, `mapping_type`, `confidence`, `sailfin_object`, `sailfin_field`, `transformation_note`, `source_citation`, `needs_crosswalk`, `reviewed`, `last_updated_by`, `last_updated_at`. Value-level mappings export as a companion CSV (`cashline_class.field`, `source_value`, `target_enum_value`, `notes`).
- **R25.** Export is gated to `analyst`/`admin` and audit-logged. The **value-level companion CSV additionally requires `sensitive_data_access`** (it contains real in-data picklist values, which for a sensitive field can be sensitive content). The field-level CSV is structurally safe.
- **R26.** The CSV is the contract handed to the test-import loop (step 3). Its shape stays loosely compatible with cashline-platform's `docs/ontology/source_field_crosswalk.md` so docs could later be regenerated — a future opportunity, not a v1 requirement.

### Non-functional

- **R27.** Mapping store lives in cashline-ontology's Postgres (cashline-platform stays decoupled from its source-system inventory). The exported CSV is the cross-team artifact.
- **R28.** A new `MappingEntryPolicy` (Pundit): `analyst` creates/edits, `read_only` views, `admin` deletes. The scope MUST join through `extraction_runs.include_sensitive` (as `SobjectPolicy::Scope` does) so mappings touching sensitive-run Sailfin fields aren't visible without `sensitive_data_access`. **The scope must propagate to the `mapping_value_entries` child query**, so sensitive picklist values don't surface in an expanded row even when the parent row would be hidden.
- **R29.** Snapshot loading and proposal computation run as GoodJob jobs with the existing progress-strip pattern.
- **R30.** OpenAI calls degrade gracefully — the grid is fully usable with heuristic-only suggestions (M5a) and manual mapping if embeddings are unavailable. Before any embedding calls, confirm OpenAI zero-retention / DPA posture is acceptable for transmitting field metadata; record the determination.
- **R31.** **Sunset.** This surface serves a bounded migration. When Sailfin → cashline sync is complete and Sailfin is disconnected, the workbench and the cashline-platform export rake task are archived.

## Success Criteria

- **Design support:** the gap-discovery view surfaces actively-used Sailfin fields with no cashline home (e.g. tenant-leaked custom fields, live deduction reason codes, high-population fields no interview covered), and the team uses it to inform cashline structure decisions.
- **Mapping:** Stephen can walk a Sailfin object with suggestion assistance, accept/correct candidates, capture mapping type + structured value-level picklist mappings, and download a CSV.
- **The real quality measure is the test-import loop:** the exported mapping drives a test import into a copy of cashline; import success rate (rows landed cleanly, values resolved, errors) is what tells us the mapping is good, and refining-and-re-importing converges. (Proposal-acceptance rate, R18, is a secondary signal.)
- **Resilience:** re-snapshotting after a cashline-platform change does not orphan mappings silently (natural keys); targets that disappeared surface for re-review on session open.

## Scope Boundaries

- **Not** in v1: discriminator-conditional mapping (`applies_when`), STI / per-subtype handling, side-by-side panels, agent-as-host, Turtle export, value-level LLM suggestions, scheduled snapshot refresh, the importer and the sync engine themselves (those are cashline-platform efforts), write-back to either app.
- **Not** authoring cashline classes/columns — those are migrations in cashline-platform, surfaced here via re-snapshot.
- **Not** resolving per-tenant/brand crosswalks globally — flagged `needs_crosswalk`, resolved per import.

## Key Decisions

- **Map against the current cashline schema and tolerate evolution; do not pre-build for a not-yet-existing target.** The earlier draft baked in a proposed `ARPosting` STI refactor with a derived discriminator — a structure that doesn't exist in cashline-platform yet (verified: flat `invoices`, no STI). That created a fragile chain (chicken-and-egg discriminator, per-object row explosion, unverifiable per-subtype export, natural-key breakage on rename). v1 drops all of it. Re-snapshot handles structure changes as ordinary new targets.
- **N:1 and 1:N are supported; discriminator-conditional is not.** The former are real, common, and cheap (one row per edge). The latter is premature.
- **Heuristic matcher before embeddings.** Lexical/type/picklist matching ships first as the primary matcher (cheap, no API, no PII exposure); OpenAI+pgvector embeddings are added only if heuristics leave a meaningful gap. The doc's own evidence is that embeddings are weak on managed-package field names.
- **LLM assist is core to v1** (manual mapping is infeasible at volume), but architected as a non-blocking accelerant (R30) — the grid works without it.
- **Picklist value mapping is structured and in v1** (no free text), so the test import is deterministic. Value-level *LLM* suggestions are deferred.
- **The test-import loop is the success metric.** Mapping quality is measured by how cleanly the export imports into a cashline copy, not by a UI-internal proxy.
- **Single sortable/filterable table**, reusing `/objects` infrastructure.

## Dependencies / Assumptions

- The user has OpenAI API keys; embeddings stored via **pgvector** (extension to be added; not currently installed).
- The cashline structure is actively being designed; the snapshot target will change, so re-snapshot + natural keys are load-bearing.
- The importer and sync engine (steps 3–4) are built in cashline-platform and consume the exported CSV; they are out of scope here.
- cashline-platform uses idiomatic Rails (flat models today, `audited` gem, namespaced paths like `Customer::Account`, AR enums) and the Ruby schema format (`db/schema.rb`).
- **[Resolved]** `audit_events` already supports a polymorphic `mapping_entry` subject via `AuditEvent.record!(subject:)` — no schema change.

## Outstanding Questions

### Resolve Before Planning

- **[Affects M2]** The grid read-model (how rows are materialized from `sfields LEFT JOIN mapping_entries` UNION source-less `net_new` entries, including how a 1:N split row is created and how `net_new` rows sort within a source-oriented grid). This shapes the data model and must be settled before M2, not deferred as an interaction detail.

### Deferred to Planning

- **[Affects R17]** OpenAI embedding model choice (`text-embedding-3-small` vs `-large`), pgvector index type, and caching/cost strategy.
- **[Affects R1]** Exact JSON snapshot schema (a versioned JSON Schema shared across both repos) and which infra tables to exclude (Active Storage, Solid*, GoodJob, schema_migrations, `audited`).
- **[Affects R5, R14]** Grid micro-interactions to settle while building: create/edit/delete affordances, the value sub-table expansion, loading state while proposals compute, the target-missing re-pick state.
- **[Affects R16/R17]** Heuristic-vs-embedding signal weighting — tune after the first real session's acceptance data and the first test-import results.

## Next Steps

`-> /ce-plan` for structured implementation planning. Suggested milestone order: **M1 → M2 → M3 → M5a → M4 → M7**, delivering a heuristic-assisted, value-aware walkthrough whose CSV feeds a first test import; then **M5b** (embeddings) and **M6** (filters/gap-discovery) as data and need accrue. Settle the grid read-model (Resolve Before Planning) before starting M2.
