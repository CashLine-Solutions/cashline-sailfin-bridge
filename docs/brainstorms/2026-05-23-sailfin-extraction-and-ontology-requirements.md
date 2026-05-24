---
date: 2026-05-23
topic: sailfin-extraction-and-ontology
---

# cashline-ontology: Sailfin Schema Extraction, Visualization, and Future Ontology Design

## Problem Frame

cashline is building a custom AR platform that will grow to handle **invoice submission workflows** and **credit rating management**. Sailfin — a Salesforce-based managed app — currently holds the operational business data: brands, customers, accounts, invoices, business details, email communication.

To design the future platform well, the team needs to:

1. Understand the existing data model in Sailfin: objects, fields, relationships, and the business logic embedded in formulas and validation rules.
2. Profile how that data is actually used in production — which fields are populated, what values appear, where the model is rich vs. sparse.
3. Use those two artifacts as input to design a clean target ontology that retains what's valuable, fixes what isn't, and extends to new domains.

This tool produces (1) and (2). (3) is downstream design work that consumes the outputs.

## Pipeline Overview

```
            ┌──────────────────────────┐
            │   Salesforce / Sailfin   │
            └────────────┬─────────────┘
                         │  REST describe + Tooling API
                         ▼
            ┌──────────────────────────┐
            │  Raw JSON per object     │ ◄── canonical source of truth
            └────────────┬─────────────┘
                         │
              ┌──────────┴──────────────┐
              ▼                         ▼
   ┌──────────────────┐      ┌─────────────────────┐
   │  SQLite (or PG)  │      │ Phase 2 data shape  │
   │ (objects, fields │      │ (counts, distinct,  │
   │  relationships,  │      │  top-N, ranges,     │
   │  picklists)      │      │  redacted samples)  │
   └────────┬─────────┘      └─────────┬───────────┘
            │                          │
            └────────────┬─────────────┘
                         │
                         ▼
            ┌──────────────────────────────────┐
            │  Rails web UI (primary surface)  │
            │   • Per-domain ERDs              │
            │   • Force-directed graph view    │
            │   • Per-object reference pages   │
            │   • Hub/orphan & usage reports   │
            │   • Phase 3 mapping workbench    │
            │     (kept/modified/dropped/new)  │
            └────────────┬─────────────────────┘
                         │   exports
                         ▼
            ┌──────────────────────────┐
            │  Target ontology (OWL)   │
            │  in OWL/Turtle, anchored │
            │  to schema.org + FIBO    │
            │  (selectively)           │
            └──────────────────────────┘
```

The Rails app is the primary deliverable. Static exports (Mermaid `.mmd`, Markdown summaries, Turtle `.ttl`) are generated **from** the UI on demand for sharing or version-controlling.

## Requirements

**Phase 1 — Extraction and Rails UI for schema exploration**

*Extraction (one-shot or re-runnable jobs):*
- R1. Pull metadata from Salesforce for the operational business subgraph, starting from a seed set (Account, Contact, Sailfin's Invoice / Brand equivalents, etc.) and walking relationships outward. The walk has a documented termination rule (namespace + allowlist + max hop depth) so scope is deterministic.
- R2. Use the REST `describe` endpoint as the primary source; layer in the Tooling API to also capture formula source and validation rule logic for in-scope objects.
- R3. Persist raw extracts as one JSON document per object inside a timestamped run directory — the canonical source of truth, never edited by downstream steps. Successive runs produce successive directories, enabling diffs.

*Storage:*
- R4. Load extracts into a relational store (SQLite for development; Postgres in production alongside the rest of cashline) with normalized tables for objects, fields, relationships, and picklist values. Rebuilt deterministically from the JSON for the active run.

*Rails UI views (primary surface, all routes live in the Rails app):*
- R5. Per-domain ERDs view — auto-clustered from relationship density as a starting point, with the ability to rename clusters and reassign objects to clusters interactively. Saved per-user.
- R6. Force-directed graph view — server-rendered, filterable (by cluster, namespace, object subset). Not a single fat HTML file.
- R7. Per-object reference pages — fields with types, picklist values, relationships (as in-app links), descriptions, captured formula/validation logic. Phase 2 stats render inline.
- R8. Hub/orphan and usage report view — sortable/filterable tables: most-connected objects, isolated objects, fields with no inbound references in formulas/validation rules, unused fields once Phase 2 lands.

*Static exports (on-demand, generated from the UI):*
- R8a. Mermaid `.mmd` exports for per-domain ERDs, Markdown summaries for per-object pages, and Turtle `.ttl` for the target ontology. Used for sharing, versioning, and offline review.

**Phase 2 — Data shape profiling**

- R9. For each in-scope object: record count, plus per-field null rate.
- R10. For each field: distinct value count and top-N most frequent values with counts.
- R11. Length / range / type-tightening stats — min/max/avg text length, number ranges, date ranges.
- R12. A handful of sample values (e.g., 5-10) per field, used as concrete reference during ontology design.
- R13. Large objects are sampled (default threshold configurable, e.g., 100k records). Sampling strategy is statistically sound (not just `LIMIT`).
- R14. PII-sensitive fields — matched by a default blocklist plus Salesforce's `IsNameField` / `EncryptedField` flags — collect only aggregate stats: record count, null rate, distinct value count, and length/range stats. They do **not** collect top-N frequencies (which would expose real values) or sample values.
- R14a. A sensitive-data override exists for cases where seeing real samples is necessary for design. It is **not** a free flag; it is gated by the Rails app's authorization layer:
  - Only users with an explicit `sensitive_data_access` role can trigger an extraction with the override enabled.
  - Runs with the override are labeled in the UI (e.g., a `sensitive` tag on the run record) and stored in a separate logical area; they cannot be confused with redacted runs.
  - Viewing pages that surface real sensitive values requires the same role; other users see the same per-object pages with values redacted.
  - An audit log records who ran the extraction, who viewed sensitive pages, and when. The log lives in a separate store from the runs themselves so a user with the role cannot quietly delete their own trail.
  - Sensitive runs have a default retention policy (e.g., auto-purge after 30 days unless explicitly retained), so PII doesn't accumulate indefinitely.
- R14b. The same role-based gating applies to financial-sensitivity fields (R24).

**Phase 3 — Target ontology design (the Rails UI is the design surface)**

The Rails UI hosts a mapping workbench where the design team performs Phase 3. Hand-authored Turtle outside the tool is still allowed for edge cases, but the workbench is the primary path.

- R15. Mapping workbench view in the Rails UI: every in-scope Sailfin object and field has a row with `status` (kept / modified / dropped / new), `target IRI` (manual or suggested), and free-text rationale notes.
- R16. Schema.org class/property suggestions surface inline where applicable (`Organization`, `Person`, `EmailMessage`, `Invoice`, `Product`, etc.) so the designer can accept or override.
- R17. FIBO suggestions surface **selectively** for AR/credit-relevant fields (e.g., `TradeReceivable`, payment terms, counterparty roles, credit rating concepts). Adoption criterion: a FIBO term is suggested only when it maps to a retained or new Sailfin element — no purely-aspirational FIBO imports.
- R18. Net-new ontology entries can be created in the workbench for domains not present in Sailfin: **invoice submission workflow** (lifecycle states and transitions) and **credit rating management**. These are flagged as net-new vs. carried-over.
- R18a. Net-new entries are evidenced, not invented. Each net-new class or property requires at least one cited source — domain-expert interview notes, a referenced FIBO module/term, a regulatory document, or an analogous schema.org concept — captured in a sources field on the entry. The workbench rejects export to Turtle if any net-new entry has no source.
- R18b. Net-new domains have a separate input track from Sailfin extraction. For invoice submission workflow: lifecycle states drawn from cashline's intended product behavior plus FIBO's receivable-lifecycle concepts. For credit rating management: rating-source taxonomies (e.g., Experian/D&B/internal), score/grade representations, and the relationship between a rated business and its rating(s). These inputs are gathered before or in parallel with Sailfin extraction; they do not depend on it.
- R19. The workbench exports the curated mapping in two forms: a structured mapping artifact (JSON or TSV, suitable for diffing across runs) and an OWL/Turtle file representing the target ontology with its anchored vocabularies.

**Phase 3 — Method (how the workbench is actually used)**

The workbench is a tool; this section is the method that gives it leverage.

- *Designers.* The cashline team performs the design, with named domain owners per area (AR/invoicing, customer/business, credit ratings, communications). Each in-scope Sailfin object has exactly one assigned owner who decides its status.
- *Decision criteria per field.* For every field on every in-scope object:
  - `kept` — the field carries meaningful business state, is non-empty in production (Phase 2 confirms), maps cleanly to a target concept (or stays as-is under cashline's namespace).
  - `modified` — the field carries meaning but the shape, name, or type is wrong. Capture the proposed change.
  - `dropped` — null in production, redundant with another field, or an artifact of Sailfin's implementation.
  - `new` — required by cashline's intended capability but absent from Sailfin (e.g., credit rating fields, submission-workflow state).
- *Decision criteria per object.* Same statuses; if `dropped`, all its fields are dropped by default unless individually salvaged. If `modified`, capture whether the change is structural (split, merge, rename) or semantic (different role in the model).
- *Migration-feasibility constraint.* For every `kept` or `modified` entry, the workbench captures a transformation note: a one-line answer to "can this be populated from Sailfin data with reasonable transformation?" — Yes / Yes-with-cleanup / No / Unknown. Phase 3 design that produces too many "No" or "Unknown" entries gets re-examined; the ontology is supposed to be reachable from Sailfin, not orthogonal to it.
- *Sailfin-independent cross-check.* Before export, a separate brief lists the business areas the team thinks the platform must cover (e.g., "we must be able to reason about a customer's payment behavior over time"). Each area is mapped to ontology concepts that satisfy it. Gaps are surfaced. This catches Sailfin-imposed framing that the design has carried over unexamined.
- *Worked example before broad design.* The first object designed end-to-end is `Account` (or whichever Sailfin object owns the customer/business concept). Walking it through the full method validates that Phase 1/2 outputs are sufficient and that the workbench supports the workflow. If gaps appear, fix them before scaling out.
- *Acceptance gate for export.* The Turtle export is allowed when (a) every in-scope object has a status, (b) every `kept`/`modified` entry has a transformation note, (c) every `new` entry has at least one cited source, and (d) the cross-check brief has been reviewed.

**Non-functional**

- R20. Extraction is idempotent at the run level: each run produces its own timestamped directory of raw JSON; the DB is rebuilt from the active run. Comparing two runs is a first-class feature (schema diff between runs).
- R21. Respects Salesforce API limits — checks `/services/data/vXX.X/limits` before starting; bounds Bulk API job concurrency; halts cleanly with resumable state on quota exhaustion.
- R22. Auth to Salesforce via Connected App / External Client App (OAuth). Tokens stored via the Rails app's existing credential pattern (Rails encrypted credentials or env-managed secrets — confirm at planning), never on the command line or in plaintext config.
- R23. Built as a Rails app in Ruby — same stack as the rest of cashline. Extraction runs as background jobs (Sidekiq or similar) triggered from the UI or rake tasks. Web UI is the primary surface for exploration and Phase 3 design work. Auth-gated so artifact access can be controlled.
- R24. Sensitive-data classification extends beyond classical PII to include financial data categories — invoice amounts, credit ratings, payment terms, balances — which are also subject to no-sample / no-top-N rules by default and require the same role-gated override (R14a, R14b) to expose values.

## Success Criteria

- A reader unfamiliar with Sailfin can navigate the Rails UI (ERDs, force graph, per-object pages) and build a working mental model of the data domain, without querying Salesforce.
- "Is this field actually used?" and "What values appear in this field?" are answerable from per-object pages without re-extracting data; PII-flagged fields surface aggregate stats only.
- A first-draft target ontology can be authored end-to-end in the mapping workbench, with status, target IRI, and rationale captured per object/field.
- Re-running extraction against a changed Sailfin produces a new run directory; the UI surfaces a diff (added/removed/changed objects and fields) between any two runs.
- The exported Turtle ontology and the structured mapping artifact are valid, self-contained, and ready to inform the future cashline platform's data model.

## Scope Boundaries

- **Not** modeling the current Sailfin schema as OWL. Current state stays as schema (JSON + relational DB); only the target stays as an ontology. This avoids encoding Salesforce implementation accidents as semantic facts.
- **Not** pulling layouts, profiles, permission sets, sharing rules, flows, triggers, or other non-schema metadata.
- **Not** automating migration of data from Sailfin to the future cashline platform. That's a future project that the target ontology and mapping artifact will inform.
- **Not** in scope for the *first cut* of the Rails app: external user accounts, billing, public exposure. This is an internal design tool for the cashline team; auth is the simplest internal auth that works.

## Key Decisions

- **Current state = schema, target state = ontology.** Different representations because they serve different goals. Forcing the current schema into OWL would encode Salesforce-specific implementation as semantic facts and pollute the redesign.
- **REST describe + Tooling API, not full Metadata API.** Captures structural metadata and embedded business logic (formulas, validation rules) without pulling tens of thousands of lines of unrelated metadata (layouts, profiles, etc.).
- **Sample large objects + redact PII by default; CLI override available.** Avoids burning daily API limits, keeps the artifact distributable, and gives an explicit escape hatch when real sample values are needed.
- **schema.org as baseline, FIBO selectively.** schema.org is widely understood; FIBO is heavyweight but adds genuine rigor for receivables, payment terms, and credit assessment. Adopting FIBO wholesale would inflate the model far beyond cashline's needs.
- **Tool is read-only.** Never writes back to Salesforce. Removes a whole class of risk.
- **Ruby over Python, despite this being "data work".** Codebase consistency wins for an ongoing tool that will be re-run and likely integrated with the cashline platform. The Python ecosystem advantage is real but narrow (graph community detection, Jupyter notebooks) and isolated steps can shell out to a small helper if needed.
- **Rails web UI as the primary surface, not static artifacts.** Interactive exploration beats static for a design exercise. The UI also doubles as the Phase 3 mapping workbench (the producer of R19) and can grow into cashline's eventual data-model browser, making it a compounding investment rather than a throwaway script. Static exports (Mermaid, Markdown, Turtle) are generated from the UI on demand.

## Dependencies / Assumptions

- User has admin or sufficient API access to the Sailfin Salesforce org, and is provisioning a Connected App / External Client App.
- Ruby + Rails (cashline's current version) available locally; the new app shares conventions with the existing cashline codebase.
- Postgres available for production deployment; SQLite acceptable for local development.
- **[Unverified assumption]** Sailfin's managed-package objects use a known namespace prefix that we can use to scope the extraction. Confirm at planning time by listing all objects from the org and inspecting prefixes.
- **[Unverified assumption]** Sailfin formula fields and rollup summary fields are exposable via the Tooling API. Some categories of derived fields are not — confirm at planning.
- **[Unverified assumption]** The Salesforce Connected App can be configured for the OAuth flow we choose; specifically, Username-Password+Token has been progressively disabled by Salesforce in newer orgs. Confirm at planning by attempting an auth handshake before committing to a flow.

## Outstanding Questions

### Resolve Before Planning

(none — all blocking product decisions are resolved)

### Deferred to Planning

- **[Affects R1][Technical]** Exact seed-object list and walk termination rule — what does Sailfin call the equivalents of Invoice and Brand, and how far do we walk? Determine at planning by listing objects from the org and picking namespace + allowlist + max-hop bounds.
- **[Affects R5][Needs research]** Domain clustering algorithm — Louvain or label propagation are the usual choices. With the Rails UI letting users re-cluster interactively, the initial auto-cluster quality matters less. Options: a simple modularity-based implementation in Ruby, Graphviz cluster layout as a heuristic, or shelling out to a small Python helper. Confirm at planning.
- **[Affects R13][Technical]** Random sampling strategy that doesn't itself require a full-table scan — likely Bulk API with a deterministic hash filter on `Id` (e.g., `WHERE Id LIKE '%a'` for ~1/16 sample). Confirm at planning.
- **[Affects R21][Technical]** Bulk API behavior for formula/rollup fields — some derived fields aren't queryable in bulk; need a documented fallback to REST per-batch. Confirm during planning.
- **[Affects R22][Technical]** OAuth flow choice — JWT Bearer (cert-based, durable) is likely the right answer given that Username-Password has been progressively disabled. Confirm by handshake test at planning.
- **[Affects R14, R24][Technical]** Exact default sensitivity blocklist — PII (Email, Phone, *Name, address parts, `IsNameField` / `IsEncrypted`) plus financial categories (amounts, balances, credit/rating, payment, currency-typed fields). Refine at planning.
- **[Affects R23][Technical]** Rails auth approach for the internal tool — Devise + an org email allowlist, Google OAuth, or whatever cashline's existing pattern is. Decide at planning.
- **[Affects R23][Technical]** Hosting target — does this run on cashline's existing infrastructure (Heroku, Fly, Kamal, etc.), or stand alone? Decide at planning.
- **[Affects R3, R20][Technical]** Run storage layout — timestamped directory of raw JSON is the agreed pattern; confirm naming convention, retention policy, and whether the per-run DB is rebuilt from JSON or stored alongside.

## Next Steps

`-> /ce-plan` for structured implementation planning.
