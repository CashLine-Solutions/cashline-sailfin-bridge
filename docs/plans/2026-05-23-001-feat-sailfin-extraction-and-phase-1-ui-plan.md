---
title: "feat: Sailfin Schema Extraction, Profiling, and Phase 1 Visualization (cashline-ontology v0.1)"
type: feat
status: active
date: 2026-05-23
origin: docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md
---

# feat: Sailfin Schema Extraction, Profiling, and Phase 1 Visualization

## Overview

Stand up a new Rails 8 application — `cashline-ontology` — that extracts Sailfin's Salesforce data model, profiles its actual data shape, and exposes an interactive web UI for exploring objects, fields, and relationships. Each extraction is a versioned snapshot; the UI can diff snapshots to surface schema change over time.

This plan covers **Phase 1 (schema extraction + visualization)** and **Phase 2 (data shape profiling with sensitive-data protections)** from the origin requirements. **Phase 3 (the Phase 3 mapping workbench, FIBO suggestions, Turtle export, cross-check brief) is deferred to a separate plan** — it's significant work that benefits from being designed after the extraction/profiling layer is stable and the team has used it for a few weeks.

## Problem Frame

cashline is building a custom AR platform that will grow to handle invoice submission workflows and credit rating management. Sailfin — a Salesforce managed app — currently holds the operational business data (brands, customers, accounts, invoices, business details, email communication). To design the future platform well, the team needs to understand Sailfin's data model in depth and see how the data is actually used in production, not just how it's documented. That understanding is the input to the future Phase 3 ontology design (deferred).

The deliverable of this plan is the tool that produces that understanding: a Rails app that pulls Salesforce metadata, profiles production data (safely), and renders multiple lenses on the result (per-domain ERDs, force-directed graph, per-object reference pages, hub/orphan and usage reports).

(See origin: `docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md`.)

## Requirements Trace

Carried forward from the origin doc (using its stable IDs):

- **R1–R3** Extraction: REST `describe` + Tooling API, walking from a seed set with documented termination, persisting raw JSON in timestamped run directories.
- **R4** Relational store (Postgres in production, SQLite acceptable for local development) rebuilt deterministically from raw JSON.
- **R5–R8a** Rails UI views: per-domain ERDs (auto-cluster + interactive re-cluster), force-directed graph (server-rendered JSON, client-rendered layout), per-object reference pages with inline Phase 2 stats, hub/orphan and usage reports. Static exports for Phase 1: Mermaid `.mmd` and Markdown only. Turtle export is Phase 3 work (deferred).
- **R9–R12** Phase 2 data shape: record counts, null rates, distinct counts, top-N values, length/range stats, sample values.
- **R13** Statistically sound sampling for large objects (Bulk API 2.0 + Id-suffix hash filter as the planning default, with deterministic recovery).
- **R14, R14a, R14b** Sensitive-data classification + redaction by default; role-gated override for trigger and view, labeled and audited.
- **R20** Run-level idempotency via timestamped run directories; diff between runs is first-class.
- **R21** Salesforce API limits respected — `/services/data/vXX.X/limits` checked pre-job, bounded concurrency.
- **R22** OAuth JWT Bearer flow; cert/key in Rails encrypted credentials.
- **R23** Built as a Rails app in Ruby. Background jobs via GoodJob. Auth-gated UI.
- **R24** Financial-data classification extends the same role-gated rules as PII.

Phase 3 requirements (**R15–R19** and the Phase 3 Method section in the origin doc) are intentionally **not** in this plan's scope — see Scope Boundaries.

Success criteria from the origin doc that this plan satisfies:

- A reader unfamiliar with Sailfin can navigate the Rails UI and build a mental model without querying Salesforce.
- "Is this field used? What values appear?" answerable from per-object pages; sensitive fields show aggregates only.
- Re-running extraction produces a new run directory; the UI surfaces a diff between any two runs.

(The remaining success criteria — first-draft target ontology authoring, valid exported Turtle — depend on the Phase 3 workbench and are out of scope here.)

## Scope Boundaries

- **Not** modeling Sailfin as OWL/Turtle. Current state stays as schema (JSON + relational DB); no Turtle output in this plan.
- **Not** building the Phase 3 mapping workbench, the FIBO/schema.org suggestion engine, the cross-check brief, the migration-feasibility constraint capture, or the Turtle export.
- **Not** pulling layouts, profiles, permission sets, sharing rules, flows, triggers, or other non-schema Salesforce metadata.
- **Not** automating data migration from Sailfin to the future cashline platform.
- **Not** building external-user accounts, billing, or any public exposure. Internal tool only.

### Deferred to Separate Tasks

- **Phase 3 mapping workbench, FIBO/schema.org suggestion engine, Turtle export, cross-check brief, Phase 3 method tooling** — Future plan. The deferral is **explicit and time-bound**:
  - Phase 3 plan to be authored within 4 weeks of Phase E (UI views) completion, conditional on at least one designer having walked one full Sailfin object (`Account` per origin doc's worked-example method) end-to-end through Phase 1/2 outputs using spreadsheet or text-editor Turtle as a stopgap mapping surface.
  - The stopgap is intentional: it surfaces what the workbench actually needs before we commit to its design.
  - **Acknowledgement:** the origin doc's full success criteria ("a first-draft target ontology can be authored using only Phase 1/2 artifacts", "valid exported Turtle") are **not satisfied by this plan alone**. They require the Phase 3 follow-on. This plan satisfies the navigation/exploration/profile success criteria; the ontology-authoring criteria are explicitly carried forward.
- **CI/CD pipeline, hosting infrastructure for the Rails app** — Out of scope here; handled separately by whoever runs cashline's deploys. This plan produces a local-runnable + production-ready app, not a deployment.

## Context & Research

### Relevant Code and Patterns

The repo is **greenfield** — no existing code beyond `.git` and `docs/brainstorms/`. The cashline Rails platform exists elsewhere and is not accessible from this working directory. Local conventions therefore default to Rails 8 idioms and what `restforce` / `good_job` / `pundit` documentation recommends.

### Institutional Learnings

`docs/solutions/` does not exist in this repo. Once the project has shipped a few iterations, learnings can land there.

### External References

From the research pass (full sources at bottom of this plan):

- **Restforce 8.0.1** is the current stable Salesforce client (Ruby 3.1+, Faraday 2). Pin Salesforce API to `v62.0` explicitly in the client — Restforce's default lags.
- **Restforce does NOT cache JWT-issued access tokens.** Every `Restforce.new` triggers a login round-trip; Salesforce rate-limits logins (~3,600/hour/org/Connected App). Use `authentication_callback:` to persist `access_token` + `instance_url` in Rails.cache between jobs.
- **Tooling API in Restforce 8 uses a separate factory:** `Restforce.tooling(...)`, returning a `Restforce::Tooling::Client`. Not a kwarg on the REST client.
- **Bulk API 2.0 is NOT supported natively by Restforce** — only Bulk 1.0. Either accept Bulk 1.0's job/batch CSV model, or hit Bulk 2.0 endpoints directly via Faraday using cached auth headers.
- **`describe` is cacheable** (Salesforce returns ETags). Cache per `(object, api_version)`.
- **Bulk API 2.0 silently drops formula and rollup-summary fields** in some org configurations. Cross-check Bulk output against REST describe; for formula fields, query via REST `query` in a second pass.
- **Managed-package field-level access:** a field with `namespacePrefix` may appear in describe but return `null` for every row if the Connected App user lacks FLS. `accessible: true` is necessary but not sufficient.
- **`/services/data/vXX.X/limits`** is accurate to ~5 minutes; consult it pre-job and persist budget into the run manifest. Cap Bulk query concurrency to 3–5 regardless of worker pool size.
- **JWT Bearer flow:** Username-Password is dead in 2026 (disabled by default). Pre-authorize the Connected App's integration user before the first JWT exchange — the #1 cause of `invalid_grant` errors. `aud` claim must be `https://test.salesforce.com` for sandboxes, `https://login.salesforce.com` for prod (Restforce does NOT set this automatically from `host:`). `exp` within 3 minutes of Salesforce's clock — NTP matters.
- **GoodJob 4.16** recommended over Sidekiq for this workload (Postgres-native, free concurrency control via `key:` + `total_limit`/`enqueue_limit`/`perform_limit`, Mission Control Jobs dashboard works against it).
- **Pundit 2.4** for authorization, scoped per-resource policies. Authorize in jobs, not only in controllers.
- **Audit events ≠ row versioning.** Roll our own `audit_events` table (`user_id, action, subject_type, subject_id, params_jsonb, ip, ua, created_at`) in a separate Postgres role with INSERT-only privileges. PaperTrail/Audited are for *row history*, not *who triggered what action*.
- **Cytoscape.js** preferred over vis-network for schema graphs (graph-theory primitives useful for hub/orphan analysis). COSE layout blocks main thread above ~3k nodes — `fcose` extension or server-precomputed positions for very large orgs.
- **Mermaid ERDs** explode visually above ~50 entities; generate one per cluster, not one mega-diagram.
- **Schema.org v30.0** (2026-03-19); use `https://schema.org/` IRIs. (Reference for Phase 3, not this plan.)
- **FIBO 2026 Q1** — relevant modules for AR/credit are FBC, FND/Accounting, BE, IND, LOAN. `TradeReceivable` was **not confirmed** in research — verify by grepping `edmcouncil/fibo` repo before the Phase 3 plan commits to that IRI. (Reference for Phase 3.)

## Key Technical Decisions

- **Rails 8.0.x + Ruby 3.3+** as the stack. Postgres in dev and prod (skip SQLite — Rails 8 default is Postgres, multi-DB support is first-class, GoodJob needs Postgres anyway, and matching prod in dev avoids divergence).
- **GoodJob over Sidekiq/Solid Queue.** Postgres-native, free concurrency control, no Redis dependency, history is queryable, fits a long-running profiling tool with hours-long jobs.
- **Pundit for authorization.** Explicit policy per resource (`RunPolicy`, `ObjectViewPolicy`, `FieldSamplePolicy`). `Sensitive_data_access` role checked in both controllers AND jobs.
- **Custom `AuditEvent` model**, separate Postgres role with INSERT-only on the events table, schema-level guard via a `BEFORE UPDATE OR DELETE` trigger. Not PaperTrail/Audited.
- **Salesforce API pinned to `v62.0`** in restforce client config. Bumping API version is a deliberate decision per upgrade.
- **JWT Bearer flow.** Cert + private key stored in Rails encrypted credentials. Access token cached via `authentication_callback:` in `Rails.cache` (Postgres-backed Solid Cache in Rails 8, or memory in dev).
- **One Connected App per environment** (sandbox vs prod). Two-cert rotation supported.
- **Two Restforce clients per run:** one REST (`Restforce.new`), one Tooling (`Restforce.tooling`). Both share cached creds.
- **Bulk API 1.0 via Restforce for routine profiling**; **Bulk API 2.0 via direct Faraday only above a configurable threshold (default 100,000 records)** where v2's cursor-based pagination matters. The threshold is consistent across plan, Key Decisions, and Unit 13.
- **Run storage:** `storage/runs/<ISO8601-timestamp>/` with one `.jsonl` per object, plus `_manifest.json` (api_version, started_at, completed_at, object_counts, limits_at_start/end, installed_packages). `storage/` gitignored. Postgres is a cache rebuilt from JSON; one rake task can rebuild it.
- **Per-domain clustering: simple modularity-greedy implementation in Ruby** — the in-scope graph is small (tens to low-hundreds of objects), so an O(n²) modularity algorithm in pure Ruby is plenty. Users can manually adjust clusters in the UI, so initial quality matters less than the API surface.
- **Visualization stack:** Cytoscape.js for force graph, Mermaid for ERDs (client-side render). Stimulus controllers hand-roll the data plumbing. Importmap-rails — no Node toolchain.
- **Sensitive-data classification at extraction time, not at view time.** The run's stored data already excludes the unsafe statistics for sensitive fields; the view layer never has the chance to leak them.
- **Sensitive runs (PII override enabled) are tagged on the `extraction_runs` record and live in a separate logical directory** (`storage/runs/sensitive/`), so a user with the role cannot accidentally publish a sensitive run to a non-sensitive consumer.
- ~~Migration-feasibility note in the data model for future Phase 3 use~~ — removed during plan review; the column shape belongs to the Phase 3 plan and a one-line `add_column` migration then is cheaper than committing to a shape now.

## Open Questions

### Verified at Review Time

- **Restforce 8.0.1 + `Restforce.tooling(...)` factory exist** — verified against `restforce/restforce@v8.0.1` (released 2025-12-29). `lib/restforce.rb` defines `def tooling(...); Restforce::Tooling::Client.new(...); end` and the `Restforce::Tooling` module is autoloaded. Plan-level uncertainty resolved.

### Resolved During Planning

- **Sampling strategy** → Bulk API 2.0 with `WHERE Id LIKE '%X'` hash filter, with the caveat that Salesforce Ids are weakly time-ordered (acceptable bias for redacted profiling; flagged in Risks). Below the large-object threshold, REST `query` with explicit `WHERE` filters or `MOD(...)` predicates.
- **OAuth flow** → JWT Bearer, cert + key in Rails encrypted credentials. Pre-authorization step documented in the operational runbook.
- **Background jobs** → GoodJob 4.x; ActiveJob adapter; concurrency keys scoped per `(salesforce_org, job_type)`.
- **Auth gem** → Rails 8 built-in `bin/rails generate authentication` (session-based, no JWT needed for the UI). Devise is overkill for an internal tool.
- **Audit log strategy** → Custom `AuditEvent` model in a second Postgres database, with INSERT-only role + DB trigger. Append-only enforced at the schema layer.
- **Visualization library** → Cytoscape.js (force graph) + Mermaid (ERDs), both client-rendered.
- **Clustering algorithm** → simple modularity-greedy in Ruby (no Python dependency); users can adjust manually.
- **Phase 3 scope** → out of this plan; separate plan to be created after this ships.

### Deferred to Implementation

- **Exact seed-object list** — depends on what Sailfin actually calls Invoice/Brand. The extraction harness is generic; the seed list is a config value. Discover at implementation time by listing all objects via the test handshake (Unit 6).
- **Bulk API 2.0 direct-Faraday helper shape** — exact method signatures will fall out of implementing it. Plan-time we know we need: submit job, poll status, fetch results, retry-on-transient. Implementer follows Salesforce's Bulk 2.0 REST contract.
- **Mermaid ERD client-side rendering quirks** — Mermaid's ER diagram syntax has rough edges around large relationship sets; concrete rendering tweaks happen during Unit 19.
- **Exact PII blocklist regex** — the planning default is `/email|phone|ssn|tax_id|dob|birth|first_name|last_name|address|postal|zip/i` plus `IsNameField`, `IsEncrypted`, and `ComplianceGroup`. Tune at implementation when we see real Sailfin field names.
- **Distinct-count suppression threshold** — research suggests suppress distinct counts < 5 on sensitive fields. Confirm at implementation; default to 5.
- **Run retention policy for sensitive runs** — research suggests default 30-day auto-purge. Confirm at implementation; default to 30 days unless explicitly retained.

## Output Structure

```
cashline-ontology/
├── Gemfile
├── Gemfile.lock
├── README.md                              # operator runbook (Connected App + JWT cert setup)
├── app/
│   ├── controllers/
│   │   ├── runs_controller.rb             # trigger / list / show
│   │   ├── objects_controller.rb          # per-object reference page
│   │   ├── erds_controller.rb             # per-cluster ERD view
│   │   ├── graph_controller.rb            # force-directed graph view
│   │   ├── reports_controller.rb          # hub/orphan/usage report
│   │   └── diffs_controller.rb            # run-to-run diff
│   ├── javascript/
│   │   └── controllers/
│   │       ├── graph_controller.js        # Stimulus + Cytoscape
│   │       └── erd_controller.js          # Stimulus + Mermaid
│   ├── jobs/
│   │   ├── extract_describe_job.rb        # REST describe + walk
│   │   ├── extract_tooling_job.rb         # Tooling formulas + validation
│   │   ├── profile_object_job.rb          # Phase 2 stats per object
│   │   └── compute_diff_job.rb            # run-to-run diff
│   ├── models/
│   │   ├── application_record.rb
│   │   ├── audit_record.rb                # abstract, connects to :audit DB
│   │   ├── audit_event.rb                 # append-only
│   │   ├── current.rb                     # Current.user, Current.run
│   │   ├── extraction_run.rb              # canonical run record
│   │   ├── sobject.rb                     # one row per Salesforce object per run
│   │   ├── sfield.rb                      # one row per field per object
│   │   ├── srelationship.rb               # one row per relationship
│   │   ├── spicklist_value.rb             # picklist values
│   │   ├── object_profile.rb              # Phase 2 per-object stats
│   │   ├── field_profile.rb               # Phase 2 per-field stats
│   │   ├── cluster.rb                     # domain cluster (auto or user-edited)
│   │   ├── run_diff.rb                    # cached diff result between two runs
│   │   └── user.rb
│   ├── policies/
│   │   ├── application_policy.rb
│   │   ├── extraction_run_policy.rb       # gates trigger_with_pii?
│   │   ├── object_view_policy.rb
│   │   └── field_sample_policy.rb         # gates show_sample_values?
│   ├── services/
│   │   ├── salesforce/
│   │   │   ├── client_factory.rb          # REST + Tooling, cached creds
│   │   │   ├── limits_check.rb            # pre-job limits poll
│   │   │   ├── describe_walker.rb         # seed + walk with termination
│   │   │   ├── tooling_fetcher.rb         # formula source, validation rules
│   │   │   ├── bulk_v1_runner.rb          # Restforce-backed Bulk 1.0
│   │   │   └── bulk_v2_runner.rb          # direct Faraday Bulk 2.0
│   │   ├── ontology/
│   │   │   ├── sensitivity_classifier.rb  # PII + financial
│   │   │   ├── relationship_graph.rb      # for clustering, hub/orphan
│   │   │   ├── modularity_clusterer.rb    # greedy modularity in Ruby
│   │   │   └── diff_calculator.rb         # categorized run-to-run diff
│   │   └── runs/
│   │       ├── run_directory.rb           # storage/runs/<ts>/ + manifest
│   │       └── relational_loader.rb       # JSON -> Postgres
│   └── views/
│       └── ...                            # erb partials, Turbo Frames
├── config/
│   ├── application.rb
│   ├── database.yml                       # primary + audit DBs
│   ├── credentials/                       # encrypted creds incl. SF cert/key
│   └── importmap.rb
├── db/
│   ├── migrate/                           # primary DB
│   ├── audit_migrate/                     # audit DB
│   ├── schema.rb
│   └── audit_schema.rb
├── docs/
│   ├── brainstorms/                       # existing
│   └── plans/                             # this plan + future Phase 3
├── lib/
│   └── tasks/
│       ├── extract.rake                   # rake extract:full
│       ├── rebuild_db.rake                # rebuild Postgres from JSON
│       └── audit.rake                     # ad-hoc audit queries
├── storage/                               # gitignored
│   └── runs/
│       ├── 2026-05-23T14-00-00Z/          # normal run
│       │   ├── _manifest.json
│       │   ├── Account.jsonl
│       │   └── ...
│       └── sensitive/                     # PII-included runs (separate)
│           └── 2026-05-23T15-00-00Z/
└── test/
    ├── models/
    ├── policies/
    ├── services/
    └── system/
```

The tree is directional. The implementer may collapse or rearrange files when implementation reveals a better layout. The per-unit `**Files:**` sections remain authoritative for what each unit creates.

## High-Level Technical Design

> *This section illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Component layout (post-extraction state):**

```
                ┌───────────────────────────────────────────┐
                │              Rails 8 app                  │
                │                                           │
   browser ◄───►│  Controllers + Turbo Frames + Stimulus    │
                │                                           │
                │  ┌──────────────┐    ┌─────────────────┐  │
                │  │  Services    │    │  GoodJob        │  │
                │  │  (Salesforce │◄──►│  workers        │  │
                │  │   + ontology │    │                 │  │
                │  │   + runs)    │    └────────┬────────┘  │
                │  └──────┬───────┘             │           │
                │         │                     │           │
                │         ▼                     ▼           │
                │  ┌──────────────┐    ┌─────────────────┐  │
                │  │  Primary DB  │    │  Audit DB       │  │
                │  │  (Postgres)  │    │  (Postgres,     │  │
                │  │              │    │   INSERT-only)  │  │
                │  └──────┬───────┘    └─────────────────┘  │
                │         │                                  │
                └─────────┼──────────────────────────────────┘
                          │
                          ▼
                ┌──────────────────────┐
                │  storage/runs/       │ ◄── canonical JSON
                │   <timestamp>/       │     (one .jsonl per object,
                │     *.jsonl          │      + _manifest.json)
                │     _manifest.json   │
                └──────────────────────┘
```

**Sequence — triggering a full extraction:**

```mermaid
sequenceDiagram
    autonumber
    participant U as User (analyst)
    participant C as Controller
    participant P as Pundit
    participant Q as GoodJob
    participant SF as Salesforce
    participant FS as storage/runs/
    participant DB as Primary DB
    participant AU as Audit DB

    U->>C: POST /runs (include_sensitive=true?)
    C->>P: authorize :create / :trigger_with_pii?
    P-->>C: ok / denied
    C->>AU: record AuditEvent(action=run.trigger)
    C->>Q: enqueue ExtractDescribeJob
    C-->>U: 202 + run id (Turbo redirect)
    Q->>SF: GET /limits
    SF-->>Q: budget
    Q->>SF: REST describe (seed + walk)
    SF-->>Q: object schemas
    Q->>FS: write .jsonl + manifest
    Q->>DB: load relational rows
    Q->>Q: enqueue ExtractToolingJob + ProfileObjectJobs (per object)
    Note over Q: ProfileObjectJob respects sensitivity classifier;<br/>sensitive runs land under storage/runs/sensitive/
    Q->>FS: write profile .jsonl
    Q->>DB: update profile rows
    Q->>AU: AuditEvent(action=run.complete)
```

This sketch is illustrative; the implementer will adjust transaction boundaries, retry policy, and exact job naming as the work proceeds.

## Implementation Units

Units are grouped into six phases by dependency. Within each phase, units are dependency-ordered.

### MVP Slice

The full plan is 21 units. Implementers should land an **MVP slice first** to enable end-to-end designer feedback before completing the rest:

**MVP = Units 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 16, 17.**

What MVP delivers: a Rails app with auth + roles + audit log, JWT-authenticated Salesforce client, REST `describe` extraction with relationship walking, normalized Postgres storage, sensitivity classification, basic profiling (counts, null rates, length stats — no top-N or samples), run lifecycle UI, per-object reference pages.

What MVP intentionally skips: Tooling API (Unit 10), Bulk 2.0 (Unit 15), ERDs (Unit 18), force graph (Unit 19), hub/orphan report (Unit 20), run-to-run diff (Unit 21).

After MVP ships and a designer has walked `Account` end-to-end, decide which of the remaining units is the next-most-valuable. The plan keeps all 21 units as a roadmap; what it should not do is treat them as a single delivery.

### Phase E Navigation Model

Phase E delivers six view groups (runs, objects, ERDs, graph, reports, diffs). They share a navigation shell:

- **Top nav (persistent):** Runs · Objects · ERDs · Graph · Reports · Diffs · (user menu)
- **Current-run context:** session-level concept set by selecting a run from `/runs/`. Visible as a chip in the top nav ("Active run: 2026-05-23T14:00:00Z · 3 days ago · 47 objects"). Clicking the chip opens a run-switcher dropdown.
- **URL override:** any view accepts `?run=<id>` to view a specific run without changing the active-run session value. Useful for sharing links.
- **Cross-links:** object page → its cluster ERD; ERD node → object page; graph node → object page; run page → all the above; reports → object pages.
- **Breadcrumbs** on detail views: `Runs / 2026-05-23T14-00-00Z / Objects / Account`.
- **First-time / zero-runs state:** `/runs` shows a guided empty state ("Run your first extraction to populate this view") with a single button that takes the user to `/runs/new`.
- **Loading states:** every long-lived job (extraction, profile, diff compute) shows progress in the run-detail panel via Turbo Stream broadcasts; long client-side computations (Cytoscape layout, Mermaid render) show a centered spinner over the canvas until ready.

### Sensitive-Data UX

The plan enforces sensitivity in code; the UI must surface it intelligibly:

- **Run list (`runs#index`):** sensitive runs render with a lock icon and an amber/red row border. Tooltip on the row: "Contains sensitive data — requires `sensitive_data_access` role." Users without the role see the runs in the list (so privilege boundary is visible), but the row's "view" action is disabled and clicking it opens a permission-required page with the support contact, not the run details.
- **Sensitive-run trigger (`runs#new`):** the `include_sensitive` toggle is hidden for users without the role (not just disabled — visibility communicates ineligibility).
- **Redacted cells (per-object pages, reports):** values redacted for the viewer render as a lock icon + the category label ("PII", "Financial", or "Unknown — pending classification") in muted gray. Hover tooltip: "Redacted for [category]. Requires `sensitive_data_access` role and a sensitive run to view real values. Contact [admin] for access." Aggregate stats (count, null rate, length range) render normally; only top-N and sample columns are redacted.
- **Run-status visibility:** users without the role see only the existence and status of sensitive runs in the list, not their error messages or per-object details.

### Phase A — Foundation

- [ ] **Unit 1: Rails 8 app skeleton**

**Goal:** Stand up a Rails 8 app with Postgres (primary + audit), Hotwire (Turbo + Stimulus + importmap), Tailwind (standalone CLI), and basic gem dependencies.

**Requirements:** R23

**Dependencies:** None.

**Files:**
- Create: `Gemfile`, `Gemfile.lock`, `config/application.rb`, `config/database.yml`, `config/importmap.rb`, `bin/setup`, `README.md`, `.gitignore` (including `storage/`)
- Create: `app/views/layouts/application.html.erb`, `app/controllers/application_controller.rb`

**Approach:**
- `rails new cashline-ontology --database=postgresql --css=tailwind --javascript=importmap` (with `--skip-asset-pipeline` since importmap covers JS and Tailwind has its own CLI).
- Gems added: `restforce ~> 8.0`, `jwt ~> 2.9`, `good_job ~> 4.16`, `pundit ~> 2.4`, `faraday ~> 2`, `mission_control-jobs`, `dotenv-rails` (optional, dev only).
- `config/database.yml`: two databases — `primary` and `audit` — under separate Postgres roles. `audit` role has INSERT/SELECT only on `audit_events`.
- `storage/` added to `.gitignore`. Empty `storage/runs/` is acceptable on first run; jobs create dated subdirs on demand.

**Patterns to follow:** Rails 8 default generators. Importmap config follows the `--javascript=importmap` defaults.

**Test scenarios:**
- *Happy path:* `bin/rails db:create db:migrate` succeeds against both databases.
- *Happy path:* `bin/rails server` boots, `/up` returns 200.
- *Integration:* GoodJob mounts at `/jobs` (gated by an admin policy added in Unit 3) and reports an empty queue.

**Verification:** App boots, both DBs present, GoodJob ready to accept jobs, no JS errors in the default layout.

- [ ] **Unit 2: User model + Rails 8 built-in authentication**

**Goal:** Provide session-based auth for the internal team. No external signup; users are created via rake task or seed.

**Requirements:** R23

**Dependencies:** Unit 1.

**Files:**
- Create: `app/models/user.rb`, `app/models/session.rb`, `app/controllers/sessions_controller.rb`, `app/views/sessions/`, `db/migrate/*_create_users.rb`, `db/migrate/*_create_sessions.rb`, `lib/tasks/users.rake`
- Test: `test/models/user_test.rb`, `test/system/sign_in_test.rb`

**Approach:**
- Use Rails 8's `bin/rails generate authentication` to scaffold session-based auth.
- Add a `role` enum to `User`: `admin`, `analyst`, `read_only`. Default `read_only`.
- Add a `sensitive_data_access` boolean column on `User`. Default `false`.
- Seed admin via `rake users:create_admin EMAIL=...`.

**Patterns to follow:** Rails 8 authentication generator output. No external auth gem.

**Test scenarios:**
- *Happy path:* User can sign in with valid credentials and reach a protected page.
- *Edge case:* Invalid credentials redirect back to sign-in with an error.
- *Edge case:* Sign-out clears the session.
- *Happy path:* `rake users:create_admin` creates an admin user with `role=admin` and `sensitive_data_access=true`.
- *Happy path:* Default new user has `role=read_only` and `sensitive_data_access=false`.

**Verification:** Sign-in works, signed-out requests to protected paths redirect to `/sessions/new`, role enum persists correctly.

- [ ] **Unit 3: Pundit + policy scaffolding**

**Goal:** Wire Pundit into the controller stack; add policies that gate sensitive trigger and view actions.

**Requirements:** R14a, R14b, R23, R24

**Dependencies:** Unit 2.

**Files:**
- Create: `app/policies/application_policy.rb`, `app/policies/extraction_run_policy.rb`, `app/policies/object_view_policy.rb`, `app/policies/field_sample_policy.rb`, `app/policies/admin_policy.rb`
- Modify: `app/controllers/application_controller.rb` (include Pundit, `after_action :verify_authorized`)
- Test: `test/policies/extraction_run_policy_test.rb`, `test/policies/field_sample_policy_test.rb`

**Approach:**
- Pundit baseline: every controller action requires `authorize` or `skip_authorization` explicitly.
- `ExtractionRunPolicy`:
  - `create?` → `analyst` or `admin`.
  - `trigger_with_pii?` → `user.sensitive_data_access? && (analyst || admin)`. Used both in the controller and re-checked in the extraction job before any sensitive write.
- `FieldSamplePolicy#show_sample_values?` → same check.
- `AdminPolicy#access?` → `admin` only; gates the GoodJob dashboard.

**Test scenarios:**
- *Happy path:* Analyst with `sensitive_data_access=true` is permitted to `trigger_with_pii?`.
- *Edge case:* Analyst without `sensitive_data_access=true` is denied.
- *Error path:* `read_only` user is denied `create?`.
- *Integration:* A controller action without `authorize` raises Pundit's verification error in test environment.

**Verification:** Policy unit tests pass; controllers wired up; admin can access GoodJob dashboard; read-only users cannot trigger runs.

- [ ] **Unit 4: AuditEvent model in a separate DB**

**Goal:** Append-only audit log for sensitive actions (run trigger, sample view, PII override usage, role changes).

**Requirements:** R14a, R14b, R23

**Dependencies:** Unit 1.

**Files:**
- Create: `app/models/audit_record.rb`, `app/models/audit_event.rb`
- Create: `db/audit_migrate/*_create_audit_events.rb`
- Create: `db/audit_seeds.sql` (Postgres role + trigger setup script)
- Create: `lib/tasks/audit.rake` (provision role, run trigger SQL, smoke-test)
- Test: `test/models/audit_event_test.rb`

**Approach:**
- **Two Postgres roles for the audit DB:** `cashline_audit_owner` owns the `audit_events` table and the `BEFORE UPDATE OR DELETE` trigger; this role runs migrations only. `cashline_audit_writer` is the Rails runtime role, granted only `INSERT, SELECT` on the table. The plan's `database.yml` configures the audit DB with `migrations_paths: db/audit_migrate` and uses the owner role for migrations and the writer role for the running app (Rails 8 multi-DB supports per-environment role separation). Without this split, migrations can't create the table or trigger in the first place.
- `AuditRecord < ActiveRecord::Base; self.abstract_class = true; connects_to database: { writing: :audit, reading: :audit }` — connects as `cashline_audit_writer`.
- **Audit role/permission changes on `User`.** Model-level `after_update_commit` hook on `User` writes an `AuditEvent` whenever `role` or `sensitive_data_access` changes, regardless of whether the change came from a controller, rake task, or `rails console`. Captures old/new values in `params`. Privilege escalation is the single most-audited action.
- `AuditEvent` schema: `id, user_id, action (string, indexed), subject_type, subject_id, params (jsonb), ip, user_agent, created_at`. Indexed `(user_id, created_at)`, `(action, created_at)`.
- `before_destroy { throw :abort }`, no `update` exposed (override `readonly?` to `persisted?`).
- DB-level guard: `BEFORE UPDATE OR DELETE ON audit_events` trigger raises an exception. Plus a Postgres role that has only `INSERT, SELECT` on the table for the Rails app user.
- `AuditEvent.record!(user:, action:, subject: nil, params: {}, request: nil)` class method as the public surface.

**Test scenarios:**
- *Happy path:* `AuditEvent.record!` inserts a row with all expected columns.
- *Error path:* Calling `event.update(action: "tampered")` raises (model + DB).
- *Error path:* Calling `event.destroy` raises (model + DB).
- *Edge case:* `user_id` may be nil for system-initiated events; schema permits.
- *Integration:* The audit DB role used by tests has correct privileges (smoke test in rake task).

**Verification:** Audit events can be inserted but not modified or deleted by the app's normal DB role; the model API is one method (`record!`) and read methods.

### Phase B — Salesforce Client and Secrets

- [ ] **Unit 5: Connected App + JWT cert provisioning (operational, documented)**

**Goal:** Document the operator runbook for setting up a Salesforce Connected App with JWT Bearer flow, generating a cert + private key, uploading the cert, and pre-authorizing the integration user. Persist cert + private key in Rails encrypted credentials.

**Requirements:** R22

**Dependencies:** Unit 1.

**Files:**
- Create: `README.md` (operator runbook section), `config/credentials/development.yml.enc`, `config/credentials/production.yml.enc`, `config/master.key` (gitignored), `docs/runbook/salesforce-connected-app.md`

**Approach:**
- Document: generate self-signed cert with `openssl req -x509 -nodes -newkey rsa:2048 -keyout sf_private.pem -out sf_cert.crt -days 365 -subj "/CN=cashline-ontology"`; convert cert to upload format if needed; create Connected App in Salesforce; upload public cert; configure scopes (`api`, `refresh_token`, plus `web` for the initial browser pre-auth); set the integration user; pre-authorize via browser one time per environment.
- Store in encrypted credentials under `salesforce.{consumer_key, username, private_key (PEM string), instance_url, sandbox: true|false}`.
- Sandbox `aud`: `https://test.salesforce.com`. Prod `aud`: `https://login.salesforce.com`.

**Patterns to follow:** Standard Rails 8 encrypted credentials; Salesforce-recommended JWT cert workflow.

**Test expectation: none — documentation and operator setup only.**

**Verification:** A teammate can follow `docs/runbook/salesforce-connected-app.md` end-to-end and produce a working set of credentials.

- [ ] **Unit 6: Salesforce client factory + JWT token caching**

**Goal:** Provide a `Salesforce::ClientFactory` that returns memoized REST and Tooling clients with cached access tokens, given an environment (dev/sandbox/prod).

**Requirements:** R22

**Dependencies:** Unit 5.

**Files:**
- Create: `app/services/salesforce/client_factory.rb`, `app/services/salesforce/token_cache.rb`
- Test: `test/services/salesforce/client_factory_test.rb`

**Approach:**
- `ClientFactory.rest` returns a `Restforce.new(api_version: "62.0", username:, client_id:, instance_url:, jwt_key:, authentication_callback: token_cache_callback)`.
- `ClientFactory.tooling` returns the parallel `Restforce.tooling(...)`.
- `TokenCache` stores `{access_token, instance_url, fetched_at}` in `Rails.cache` (Solid Cache in prod) keyed by `("sf-token", Rails.env, sandbox_flag, consumer_key_digest)`. TTL = `token_lifetime - 5.minutes`. If cache miss, the next `Restforce` call triggers a fresh JWT exchange, and `authentication_callback` writes to cache.
- **Single-flight protection.** With multiple GoodJob workers, a cold cache can produce a thundering herd of JWT exchanges. Wrap the cache miss with `Rails.cache.fetch(..., race_condition_ttl: 30)` plus a Postgres advisory lock (`pg_advisory_xact_lock` keyed on the cache key) so only one worker performs the exchange while others wait.
- **Sandbox refresh / instance migration handling.** Salesforce occasionally migrates orgs between PODs; the cached `instance_url` can go stale and produce 404s rather than 401s. On any 401/404 from Restforce, the wrapper invalidates the cache entry and retries once with a fresh exchange before failing.
- Sandbox vs prod: read from credentials; set `aud` claim accordingly (Restforce's JWT helper handles this when the right `host:` is passed; verify in test).
- Wrap with rescue for `Restforce::AuthenticationError`, log, raise a domain error.

**Test scenarios:**
- *Happy path:* First call triggers a JWT exchange (stubbed Faraday); subsequent calls within TTL reuse cached token (assert no new exchange).
- *Edge case:* Cache expires → triggers new exchange.
- *Error path:* Salesforce returns 401 → `Restforce::AuthenticationError` → mapped to a domain error.
- *Integration:* Sandbox config produces a client whose JWT `aud` is `https://test.salesforce.com`.

**Verification:** Stubbed-Faraday tests pass; manual handshake against a sandbox org succeeds; tokens are reused across worker invocations.

- [ ] **Unit 7: Limits check service**

**Goal:** Pre-job poll of `/services/data/v62.0/limits` so extraction can budget API call usage and refuse to start when near quota.

**Requirements:** R21

**Dependencies:** Unit 6.

**Files:**
- Create: `app/services/salesforce/limits_check.rb`
- Test: `test/services/salesforce/limits_check_test.rb`

**Approach:**
- `LimitsCheck.call(client)` returns a hash of relevant limits: `DailyApiRequests`, `DailyBulkApiBatches`, `DailyBulkV2QueryJobs`, `ConcurrentAsyncGetReportInstances`, with `Remaining` and `Max` for each.
- A guardrail method `LimitsCheck.guard!(client, threshold: 0.10, raise_below: 5)` that raises `Salesforce::QuotaExhausted` if relevant remaining buckets fall under a 10% threshold AND fewer than 5 absolute remaining.
- Result is persisted in `ExtractionRun#limits_at_start` (Unit 8).

**Test scenarios:**
- *Happy path:* Limits over threshold → `guard!` returns ok, persists snapshot.
- *Error path:* Limits under threshold → `guard!` raises.
- *Edge case:* Empty limits payload (Salesforce edge) → `guard!` raises with a descriptive error.

**Verification:** Stubbed responses produce expected guard outcomes; the snapshot shape matches what `ExtractionRun#limits_at_start` will consume.

### Phase C — Extraction Jobs and Run Storage

- [ ] **Unit 8: ExtractionRun model + run-directory service**

**Goal:** Canonical record of each extraction run; companion service that creates and writes to the timestamped run directory.

**Requirements:** R3, R20, R21

**Dependencies:** Unit 1, Unit 7.

**Files:**
- Create: `app/models/extraction_run.rb`, `app/services/runs/run_directory.rb`, `db/migrate/*_create_extraction_runs.rb`
- Test: `test/models/extraction_run_test.rb`, `test/services/runs/run_directory_test.rb`

**Approach:**
- `ExtractionRun` schema: `id, started_at, completed_at, api_version, status (enum: queued/extracting/profiling/complete/complete_with_warnings/failed), include_sensitive (bool), retained_until (datetime, null for non-sensitive runs), seed_objects (jsonb), walk_options (jsonb), limits_at_start (jsonb), limits_at_end (jsonb), installed_packages (jsonb), error_message (text), partial_failures (jsonb, list of {object_api_name, reason}), content_hash (text, SHA256 of manifest + sorted jsonl checksums computed at completion), user_id (FK)`. `include_sensitive=true` runs are tagged and have their directory under `sensitive/`.
- `canceled` was dropped from the status enum — no cancellation mechanism is in scope for v0.1 (GoodJob in-flight cancellation + Bulk job-abort is non-trivial and unused). Runs run to `complete`/`complete_with_warnings`/`failed`.
- `complete_with_warnings` is the run state when one or more per-object profile jobs failed but the extraction itself succeeded. The UI surfaces the list of failed objects from `partial_failures`.
- `content_hash` is verified by Unit 21 before computing any run-to-run diff; mismatch refuses diff and triggers a rebuild path so we never silently diff inconsistent state.
- `Runs::RunDirectory.for(run)` returns a struct with path helpers: `manifest_path`, `object_jsonl_path(object_api_name)`, `profile_jsonl_path(object_api_name)`, `sensitive?` flag.
- Run directory format: `storage/runs/2026-05-23T14-00-00Z/` (non-sensitive) or `storage/runs/sensitive/2026-05-23T14-00-00Z/`. Manifest file `_manifest.json` written at run start, updated at completion.
- **File-system permissions.** `storage/runs/sensitive/` is created with mode `0700`, owned by the Rails process user. `bin/setup` enforces this; a boot-time check refuses to start if `storage/runs/sensitive/` is group- or world-readable. The runbook calls out that backups or aggregation tools must respect these permissions.
- **Retention.** Sensitive runs default to 30-day auto-purge from `completed_at` unless explicitly retained (`extraction_run.retained_until`). A small GoodJob cron sweeper enqueued daily deletes expired sensitive runs (both DB rows and file-system directory) — this is part of v0.1, not deferred, because file-system data outliving policy decisions was flagged as a real risk by review.
- One `<object_api_name>.jsonl` per object, line-delimited JSON (one record/document per line). Survives partial failure; resumable.

**Test scenarios:**
- *Happy path:* `ExtractionRun.create!` produces a run record; `RunDirectory.for(run).manifest_path` returns a path under the correct subdirectory.
- *Edge case:* `include_sensitive=true` puts the run under `storage/runs/sensitive/`.
- *Happy path:* Manifest path is writable, `.jsonl` paths are writable.
- *Edge case:* Two runs started within the same second get distinct directories (timestamp + jitter or auto-suffix).

**Verification:** Run records persist; directories are created with correct sensitive/non-sensitive segregation.

- [ ] **Unit 9: ExtractDescribeJob — REST describe + relationship walker**

**Goal:** Per-run job that uses REST `describe` to pull schema for the configured seed set, walks relationships outward to the configured termination, and writes JSON to the run directory.

**Requirements:** R1, R2 (REST portion), R3

**Dependencies:** Unit 6, Unit 8, Unit 7.

**Files:**
- Create: `app/jobs/extract_describe_job.rb`, `app/services/salesforce/describe_walker.rb`
- Test: `test/jobs/extract_describe_job_test.rb`, `test/services/salesforce/describe_walker_test.rb`

**Approach:**
- Walker config: `seed_objects` (e.g., `["Account", "Contact", "<sailfin namespace>__Invoice__c", ...]`), `namespace_allowlist` (e.g., `["sailfin", ""]` for managed + standard), `standard_allowlist` (e.g., `["Account", "Contact", "User", "RecordType"]`), `max_hops` (e.g., `3`).
- BFS over relationships from describe payloads. Cross-edges only if both endpoints satisfy `(namespace ∈ allowlist) OR (api_name ∈ standard_allowlist)`. Stop at `max_hops`.
- For each in-scope object: fetch full describe via Restforce (`client.describe(name)`), write the JSON document to `<run>/<object>.jsonl` (single-line JSON for describe payloads), record visited set + edge list in the manifest.
- Capture flags per field: `name, label, type, length, nillable, calculated, calculatedFormula (boolean only — the source comes from Tooling later), encrypted, nameField, compoundFieldName, referenceTo, picklistValues (array of {value, label, active}), namespacePrefix, accessible, createable, updateable, filterable`.
- Re-cache describe results per `(object, api_version)` within the same run.

**Patterns to follow:** Standard ActiveJob; `perform_later` from the controller; GoodJob `concurrency: { key: -> { run.id } }`.

**Execution note:** Implement test-first against a stubbed describe payload so the walker behavior (allowlist, depth bound, edge crossing rules) is locked down before integrating with Restforce.

**Test scenarios:**
- *Happy path:* Walker with seed `[A]` and allowlisted relationship `A → B → C` produces `{A, B, C}` if `max_hops >= 2`.
- *Edge case:* `max_hops = 1` produces `{A, B}` only.
- *Edge case:* Relationship to an out-of-allowlist object terminates the walk at the gateway object (the gateway is included; the target is not).
- *Edge case:* Self-referential relationships do not infinite-loop.
- *Integration:* Job writes one `.jsonl` per in-scope object plus a `_manifest.json` listing visited objects and edges.
- *Error path:* `LimitsCheck.guard!` raises → job marks run failed, persists error message, writes partial manifest.

**Verification:** Walker behavior matches the configured termination rule; run directory contains expected files; manifest is complete.

- [ ] **Unit 10: ExtractToolingJob — formula source + validation rule logic**

**Goal:** Per-run job that, after `ExtractDescribeJob` completes, fetches formula source and validation rule logic for in-scope objects via the Tooling API.

**Requirements:** R2 (Tooling portion)

**Dependencies:** Unit 9.

**Files:**
- Create: `app/jobs/extract_tooling_job.rb`, `app/services/salesforce/tooling_fetcher.rb`
- Test: `test/jobs/extract_tooling_job_test.rb`, `test/services/salesforce/tooling_fetcher_test.rb`

**Approach:**
- Use `Restforce.tooling(...)` (separate client from REST).
- For each in-scope object: SOQL `SELECT Id, EntityDefinition.QualifiedApiName, DeveloperName, Metadata FROM CustomField WHERE EntityDefinition.QualifiedApiName = '<name>'`. Pull `Metadata.formula` for fields whose REST describe flagged `calculated: true`. Pull `Metadata.errorConditionFormula` from `ValidationRule` similarly.
- Batch queries (FieldDefinition is silently capped at ~2000 rows) — chunk by `QualifiedApiName IN (...)`.
- Append the formula source + validation logic to the existing per-object JSON as additional records (different `record_type` key, e.g., `{"record_type": "tooling_field_metadata", ...}`).
- Gracefully degrade: if Tooling returns null/empty for a field, log and continue. Managed-package fields often have no source.

**Test scenarios:**
- *Happy path:* For an object with two formula fields, `.jsonl` gains two `tooling_field_metadata` records with formula text.
- *Edge case:* Object with no formula fields produces no Tooling records (no .jsonl change).
- *Edge case:* Managed-package formula returns null → logged, no error.
- *Integration:* Job is enqueued by `ExtractDescribeJob` on success.

**Verification:** Formula + validation source appears in run JSON for fields that have it; missing source does not fail the run.

- [ ] **Unit 11: RelationalLoader — JSON → Postgres**

**Goal:** Convert a run's raw JSON into normalized rows in the primary DB so the UI can query SQL.

**Requirements:** R4

**Dependencies:** Unit 9 (and ideally Unit 10, but loader can run before Tooling completes — it loads what's present).

**Files:**
- Create: `app/services/runs/relational_loader.rb`
- Create: `db/migrate/*_create_sobjects.rb`, `*_create_sfields.rb`, `*_create_srelationships.rb`, `*_create_spicklist_values.rb`
- Modify: `app/models/sobject.rb`, `sfield.rb`, `srelationship.rb`, `spicklist_value.rb`
- Test: `test/services/runs/relational_loader_test.rb`

**Approach:**
- Schema: `sobjects(id, extraction_run_id, api_name, label, namespace_prefix, custom, is_name_field, raw_describe_jsonb, created_at)`. Indexed `(extraction_run_id, api_name)`.
- `sfields(id, sobject_id, api_name, label, data_type, length, nillable, calculated, calculated_formula, encrypted, name_field, compound_field_name, picklist_count, references_count, namespace_prefix, accessible, createable, updateable, filterable, raw_describe_jsonb, tooling_metadata_jsonb)`. Indexed `(sobject_id, api_name)`.
- `srelationships(id, extraction_run_id, source_sobject_id, target_sobject_id, source_field_id, relationship_name, cascade_delete, restricted_delete, polymorphic (bool), reference_to_api_names (jsonb))`.
- `spicklist_values(id, sfield_id, value, label, active, default_value)`.
- Loader is idempotent per run — `delete_all + insert_all` for that run only. Rebuild from JSON via `rake rebuild_db RUN=<timestamp>`.

**Test scenarios:**
- *Happy path:* Loading a run with 3 objects and 50 fields produces 3 `sobjects` rows, 50 `sfields` rows, and the right `srelationships` count.
- *Edge case:* Re-loading the same run replaces rows, does not duplicate.
- *Edge case:* Polymorphic lookup (multiple `referenceTo` targets) creates one relationship row with a polymorphic=true flag.
- *Integration:* `rake rebuild_db RUN=<timestamp>` against a saved run reconstructs all rows.

**Verification:** Rows persist with correct foreign keys; `rake rebuild_db` is the round-trip test.

### Phase D — Phase 2 Profiling and Sensitive-Data Handling

- [ ] **Unit 12: Sensitivity classifier**

**Goal:** Classify each field as `safe`, `pii`, `financial`, or `pii_and_financial` so downstream stats collection can redact accordingly.

**Requirements:** R14, R24

**Dependencies:** Unit 11.

**Files:**
- Create: `app/services/ontology/sensitivity_classifier.rb`, `db/migrate/*_add_sensitivity_to_sfields.rb`
- Test: `test/services/ontology/sensitivity_classifier_test.rb`

**Approach:**
- Multi-signal classifier. Input: a `sfield` row + its raw describe + (optional) `ComplianceGroup` value from Tooling. Output: a `sensitivity` enum on `sfield`.
- Signals (`pii`):
  - Salesforce native: `encrypted: true` → pii; `IsNameField: true` AND object has `FirstName` + `LastName` siblings → pii; `compoundFieldName: BillingAddress|MailingAddress|ShippingAddress|...` → pii.
  - Type: `email`, `phone` → pii.
  - Name patterns: `/email|phone|ssn|tax_id|dob|birth|first_name|last_name|address|postal|zip/i`.
  - `ComplianceGroup` from FieldDefinition contains `PII`, `PCI`, or `HIPAA` → pii (overrides safe).
- Signals (`financial`):
  - Type: `currency`, `percent`.
  - Name patterns: `/amount|balance|payment|credit|debit|rating|score|invoice|salary|wage|revenue/i`.
  - `ComplianceGroup` contains `Confidential` AND name matches financial pattern → financial.
- A field may be both; store as `pii_and_financial` enum value. Possible values: `safe`, `pii`, `financial`, `pii_and_financial`, `unknown_sensitivity`. Any non-`safe` value triggers the redaction path in Unit 14.
- The `migration_note` column on `sfields` was proposed for future Phase 3 use; review removed it. Phase 3 is deferred; the column shape will be decided when the workbench is designed, and a single `add_column` migration at that time is cheaper than committing to a shape now.

**Test scenarios:**
- *Happy path:* `Email` field → pii.
- *Happy path:* `BillingStreet` → pii (compound address).
- *Happy path:* `Amount__c` of type currency → financial.
- *Edge case:* `Account.Name` (business name, no FirstName/LastName siblings) → safe (not pii).
- *Edge case:* `Contact.LastName` (with FirstName sibling) → pii.
- *Edge case:* `Discount__c` of type currency → financial (cautious classification).
- *Edge case:* `ComplianceGroup=PII` override beats name pattern absence.
- *Error path:* Missing raw describe → classify as `unknown_sensitivity` (fail-closed) and block top-N + sample collection until a complete describe is available. Logged. The previous draft defaulted to `safe`; multiple reviewers correctly flagged that as inconsistent with the rest of the plan's threat model — every other layer defaults closed, this one should too.

**Verification:** Classifier output is reproducible per field; classifier results persisted to `sfields.sensitivity`.

- [ ] **Unit 13: ProfileObjectJob — record counts, null rates, distinct counts, length/range stats**

**Goal:** Per-object profiling job that computes per-field statistics, respecting sensitivity classification.

**Requirements:** R9, R10 (counts portion), R11, R14, R24

**Dependencies:** Unit 12, Unit 8.

**Files:**
- Create: `app/jobs/profile_object_job.rb`, `app/services/salesforce/profile_runner.rb`
- Create: `app/models/object_profile.rb`, `app/models/field_profile.rb`, `db/migrate/*_create_object_profiles.rb`, `*_create_field_profiles.rb`
- Test: `test/services/salesforce/profile_runner_test.rb`, `test/jobs/profile_object_job_test.rb`

**Approach:**
- For an in-scope object: get record count from Tooling's `EntityDefinition.RecordCount` (approximate, refreshed daily by Salesforce) rather than `SELECT COUNT()` — the synchronous query times out on objects above ~50M rows precisely when sampling is most needed. If `RecordCount > 100_000`, route to Unit 15's Bulk sampling path; otherwise scan via SOQL.
- For each field on the object: compute `null_rate`, `distinct_count` (with suppression: if sensitive AND distinct_count < 5, set distinct_count to nil and persist `distinct_count_suppressed=true`).
- For text fields: `min_length, max_length, avg_length`.
- For numeric (`int`, `double`, `currency`, `percent`): `min, max, mean, p50, p95`.
- For date/datetime: `min, max`.
- All stats stored as columns on `field_profiles`; the unsafe stats (top-N, samples) handled in Unit 14.
- `ObjectProfile` rolls up: `extraction_run_id, sobject_id, record_count, profiled_at, sampled (bool), sample_size`.

**Test scenarios:**
- *Happy path:* Field with 80% null rate produces `null_rate = 0.8`.
- *Edge case:* All-null field → `null_rate = 1.0, distinct_count = 0`.
- *Edge case:* Sensitive field with 3 distinct values → `distinct_count = nil, distinct_count_suppressed = true`.
- *Happy path:* Text field length stats reflect actual data.
- *Integration:* Stub Salesforce to return a fixed result set; assert all stats persisted correctly.
- *Error path:* SOQL error for one object → that profile marked failed, run continues.

**Verification:** Profiles persisted with correct values; sensitive-field suppression honored; one failure does not stop the whole run.

- [ ] **Unit 14: Top-N values + sample values (sensitivity-aware)**

**Goal:** Collect top-N most frequent values and a handful of sample values per field, with sensitivity gating.

**Requirements:** R10 (top-N), R12, R14, R14a, R24

**Dependencies:** Unit 13.

**Files:**
- Modify: `app/services/salesforce/profile_runner.rb` (extend with top-N + sample collection)
- Test: extend `profile_runner_test.rb`

**Approach:**
- For each `safe` field: SOQL aggregate `SELECT field, COUNT(Id) c FROM <obj> WHERE field != null GROUP BY field ORDER BY c DESC LIMIT N` (N default 10). Persist `field_profile.top_values_jsonb = [{value, count}, ...]`.
- For each `safe` field: sample 5 distinct values (via SOQL with `WHERE field != null LIMIT 5` after a deterministic ordering; not perfectly random but adequate for design-time inspection). Persist `field_profile.sample_values_jsonb`.
- For `pii` / `financial` / `pii_and_financial` fields: skip top-N AND samples entirely, unless `run.include_sensitive == true` AND `current user has sensitive_data_access` (re-checked in the job — never trust the controller).
- When the override is active: collect top-N + samples; tag the resulting `field_profile` row with `sensitive_override_used=true`.

**Test scenarios:**
- *Happy path:* Safe field → top-N populated, samples populated.
- *Happy path:* PII field, override OFF → top-N and samples both nil.
- *Happy path:* PII field, override ON (with role) → top-N and samples populated, `sensitive_override_used=true`.
- *Error path:* PII field, override ON but role missing → policy check fails inside job, run aborts with audit entry.
- *Integration:* Run-level `include_sensitive=true` propagates through the policy check at job time.
- *Edge case:* Top-N on a low-cardinality safe field returns all distinct values (fewer than N) — no padding.

**Verification:** Override gating works at job time; sensitive runs cannot leak samples without role; audit log entries exist for override usage.

- [ ] **Unit 15: Large-object sampling via Bulk API 2.0 (direct Faraday)**

**Goal:** For objects above the large-object threshold, sample via Bulk 2.0 with a deterministic Id-suffix filter so profiling does not require a full-table scan.

**Requirements:** R13, R21

**Dependencies:** Unit 13, Unit 6.

**Files:**
- Create: `app/services/salesforce/bulk_v2_runner.rb`
- Modify: `app/services/salesforce/profile_runner.rb` (route to v2 when over threshold)
- Test: `test/services/salesforce/bulk_v2_runner_test.rb`

**Approach:**
- `BulkV2Runner.query(object:, soql:, on_chunk:)` — submits a Bulk 2.0 query job via direct Faraday using the cached access token from `Salesforce::TokenCache`. **Reads the token from cache on every Faraday call** (submit, each poll, each result fetch) rather than capturing it at job submission — Bulk 2.0 jobs run for minutes-to-hours and may outlive the original token. On 401/404, invalidates the cache entry, triggers a fresh JWT exchange via `Salesforce::ClientFactory`, and retries once.
- Polls `state`; on `JobComplete`, fetches `results` chunks via `Sforce-Locator` cursor; yields each chunk's parsed CSV rows.
- Sampling SOQL: Salesforce rejects leading-wildcard `WHERE Id LIKE '%X'` as non-selective on large objects (and `MOD()` is not available on Id strings in SOQL). Use **`CreatedDate`-windowed scans** instead — partition the time range into N windows and pull all rows from one window per sampling pass, ordered by `CreatedDate ASC LIMIT M`. For a more uniform distribution across time, take multiple small windows spaced across the object's lifetime. Document the bias clearly (samples cluster by time window, not random across the population) so designers know what they're looking at.
- Concurrency cap: Bulk job submissions guarded by a GoodJob concurrency key `(salesforce_org, :bulk_v2)` with `total_limit: 3`.
- On `JobFailed`: surface Salesforce error message into `extraction_run.error_message`; don't retry blindly.
- Cross-check formula/rollup fields against the REST `describe` payload — if a field is `calculated: true` and Bulk returned null for it, log a `bulk_v2_dropped_calculated_field` event in the run manifest and fall back to REST for that field.

**Test scenarios:**
- *Happy path:* Bulk 2.0 job lifecycle (submit, poll → JobInProgress → JobComplete, fetch results) yields parsed rows.
- *Edge case:* Two result chunks via `Sforce-Locator` — both yielded.
- *Error path:* JobFailed → run captures error message, no retry.
- *Edge case:* Calculated field returns null in Bulk → fallback signal logged; REST `query` used in a follow-up.
- *Integration:* Concurrency key enforced — three jobs queued, two run concurrently, third waits.

**Verification:** Bulk 2.0 results flow into profiling; calculated-field fallback logged; concurrency cap honored.

### Phase E — Phase 1 UI Views

- [ ] **Unit 16: Run lifecycle UI (trigger, status, list)**

**Goal:** UI to trigger a new run (with optional sensitive override), watch progress, and list past runs.

**Requirements:** R20 (run lifecycle), R23

**Dependencies:** Unit 8, Unit 9, Unit 3, Unit 4.

**Files:**
- Create: `app/controllers/runs_controller.rb`, `app/views/runs/index.html.erb`, `app/views/runs/show.html.erb`, `app/views/runs/new.html.erb`
- Test: `test/system/runs_test.rb`, `test/controllers/runs_controller_test.rb`

**Approach:**
- `runs#new` form: choose seed-object set (presets + custom), max_hops, include_sensitive toggle (only shown to users with the role).
- `runs#create`: authorizes via Pundit; records audit event; enqueues `ExtractDescribeJob`.
- `runs#show`: live status via Turbo Stream broadcast from GoodJob job callbacks. **Channel scoped using `signed_stream_name([run, current_user])`** (Turbo's signed stream names) so only the originating user receives updates — a predictable channel name like `run_<id>` would let any authenticated user subscribe and see error messages or run metadata. Surfaces run manifest, object count, error messages, per-object failure list (for `complete_with_warnings`), and a link to "view extraction results."
- `runs#index`: filterable by status, include_sensitive, date range. Sensitive runs visually flagged.

**Patterns to follow:** Turbo Frame for the status panel; Turbo Stream broadcast from job completion.

**Test scenarios:**
- *Happy path:* Analyst creates a non-sensitive run; status moves queued → extracting → profiling → complete.
- *Edge case:* `read_only` user cannot reach `runs/new`.
- *Edge case:* Analyst without `sensitive_data_access=true` does not see the include_sensitive toggle.
- *Integration:* Audit log row exists for run.trigger with the right params.

**Verification:** Run lifecycle visible in the UI; policy enforced; audit log entries present.

- [ ] **Unit 17: Per-object reference pages**

**Goal:** One page per Salesforce object: fields with types, picklist values, relationships, Phase 2 stats (subject to sensitivity), formula source/validation rule logic when present.

**Requirements:** R7, R14b, R24

**Dependencies:** Unit 11, Unit 13, Unit 14.

**Files:**
- Create: `app/controllers/objects_controller.rb`, `app/views/objects/index.html.erb`, `app/views/objects/show.html.erb`
- Test: `test/system/object_pages_test.rb`, `test/controllers/objects_controller_test.rb`

**Approach:**
- `objects#index`: list all in-scope objects in the active run, with filters (namespace, has_records, has_orphan_fields).
- `objects#show`: header (api name, label, record count, namespace, custom flag); a "Fields" table (api name, type, length, nillable, calculated flag, sensitivity, null rate, distinct count, top values, sample values, picklist values, related-to); a "Relationships" section (inbound + outbound); a "Formulas / Validation" section if Tooling data is present.
- Sensitivity rendering: PII fields never render top-N or sample columns unless current user has `sensitive_data_access` AND the run is `include_sensitive`.
- Relationships rendered as in-page links to other object pages.

**Test scenarios:**
- *Happy path:* Object with 20 fields and 3 relationships renders correctly.
- *Edge case:* PII field shows "redacted" in top-N/samples columns for users without the role.
- *Edge case:* Sensitive run viewed by a user without role → top-N/samples columns hidden everywhere.
- *Integration:* Clicking a relationship link navigates to the referenced object's page (within the same run).

**Verification:** Reference pages render; sensitivity rendering enforced at the policy layer.

- [ ] **Unit 18: Per-domain ERDs (modularity clustering + Mermaid)**

**Goal:** Auto-cluster the schema's relationship graph into per-domain ERDs, render each cluster as Mermaid client-side, allow user re-clustering.

**Requirements:** R5, R8a (Mermaid export)

**Dependencies:** Unit 11.

**Files:**
- Create: `app/services/ontology/relationship_graph.rb`, `app/services/ontology/modularity_clusterer.rb`
- Create: `app/models/cluster.rb`, `app/models/cluster_assignment.rb`, `db/migrate/*_create_clusters.rb`, `*_create_cluster_assignments.rb`
- Create: `app/controllers/erds_controller.rb`, `app/views/erds/index.html.erb`, `app/views/erds/show.html.erb`
- Create: `app/javascript/controllers/erd_controller.js` (Stimulus + Mermaid)
- Test: `test/services/ontology/modularity_clusterer_test.rb`, `test/system/erds_test.rb`

**Approach:**
- `RelationshipGraph.build(extraction_run)` returns a graph (nodes = sobjects, edges = srelationships).
- `ModularityClusterer.cluster(graph)` returns clusters (a `[[node, node, ...], ...]` array). Simple greedy modularity:
  - Start with each node in its own cluster.
  - Iteratively merge the pair of clusters with the largest modularity gain until no positive gain.
  - This is O(n²) per iteration but n ≤ ~300 for typical Sailfin org sizes — acceptable.
- Persist cluster results in `clusters(name, extraction_run_id, color, created_by_user)` and `cluster_assignments(cluster_id, sobject_id)`.
- Cluster initial naming: by largest-object-in-cluster (label fallback to "Cluster A/B/C"). User can rename + reassign in the UI.
- Mermaid ER syntax generated server-side as text per cluster; rendered client-side by Stimulus controller wrapping mermaid.js. Server-side sanitization of Salesforce labels (quotes, brackets, Mermaid reserved words) before emission to prevent broken `.mmd` exports.
- **Re-cluster interaction surface:** Mermaid renders SVG with no drag support, so re-clustering happens on a **dedicated "Edit clusters" page** (separate from the ERD view itself), not on the diagrams. The edit page is a sidebar list of clusters (each renamable inline) with objects rendered as draggable chips that can be dragged between clusters. A "Reset to auto-cluster" button restores the algorithm's output (with a confirm). The ERD views are read-only renders of the persisted cluster assignments.
- **Clustering trigger:** computed once at extraction-completion time (post-Unit 11 load) and persisted to `clusters` + `cluster_assignments`. Manual edits modify the persisted assignments without re-running the algorithm. Never recomputed unless the user explicitly hits "Reset to auto-cluster" — keeps re-render cheap.
- Export `.mmd` text per cluster via a link.

**Test scenarios:**
- *Happy path:* A simple 6-node, 2-component graph clusters into the 2 components.
- *Edge case:* Disconnected node (no edges) gets its own cluster.
- *Edge case:* User renames a cluster → persists, survives re-render.
- *Edge case:* User reassigns an object to another cluster → persists.
- *Integration:* Mermaid renders client-side without console errors for a 20-object cluster.
- *Edge case:* Cluster with > 50 objects warns the user it may render poorly.

**Verification:** Clustering produces sensible groupings; UI allows manual override; Mermaid renders cleanly per cluster.

- [ ] **Unit 19: Force-directed graph view (Cytoscape.js)**

**Goal:** A whole-schema interactive force-directed graph with filtering by cluster, namespace, and object subset.

**Requirements:** R6

**Dependencies:** Unit 11, Unit 18 (for clusters).

**Files:**
- Create: `app/controllers/graph_controller.rb`, `app/views/graph/show.html.erb`
- Create: `app/javascript/controllers/graph_controller.js` (Stimulus + Cytoscape)
- Test: `test/system/graph_test.rb`

**Approach:**
- Controller emits a `{nodes: [{id, label, namespace, cluster, record_count}], edges: [{source, target, type, polymorphic}]}` JSON blob via a Turbo Frame'd JSON endpoint; the Stimulus controller fetches it lazily.
- Cytoscape's `fcose` layout (faster than COSE for our scale).
- Filters: cluster, namespace, sensitivity, record_count threshold. Filters apply client-side without re-fetching.
- Node click → navigate to the per-object reference page (Unit 17).

**Patterns to follow:** Stimulus + importmap + Cytoscape ESM bundle.

**Test scenarios:**
- *Happy path:* Graph renders with all in-scope nodes/edges.
- *Edge case:* Filter by namespace narrows the visible set.
- *Edge case:* Click node navigates to the object page.
- *Integration:* Graph data endpoint returns valid JSON for a small fixture run.

**Verification:** Interactive graph renders; filters work; navigation works.

- [ ] **Unit 20: Hub/orphan and usage report views**

**Goal:** Derived analytical views — most-connected objects (hubs), isolated objects (orphans), unused fields (per Phase 2 data).

**Requirements:** R8

**Dependencies:** Unit 11, Unit 13.

**Files:**
- Create: `app/controllers/reports_controller.rb`, `app/views/reports/hub_orphan.html.erb`, `app/views/reports/unused_fields.html.erb`
- Test: `test/system/reports_test.rb`

**Approach:**
- Hub/orphan: SQL aggregation over `srelationships` to compute inbound/outbound degree per object; render sortable Turbo-Frame'd table with filters.
- Unused-fields: SQL over `field_profiles` for fields with `null_rate = 1.0` (always null) or `null_rate > 0.99` (effectively unused).
- All views are sortable + filterable + downloadable as CSV via a Turbo Frame.

**Test scenarios:**
- *Happy path:* Hub report ranks objects by inbound degree descending.
- *Happy path:* Orphan report lists objects with 0 inbound and 0 outbound edges.
- *Happy path:* Unused-fields report respects the threshold (default 0.99).
- *Edge case:* Sensitive fields appear in unused-fields with type/name visible but values redacted.

**Verification:** Reports match SQL truth; sort/filter functional.

### Phase F — Run-to-Run Diff

- [ ] **Unit 21: ComputeDiffJob + RunDiff model + diff view**

**Goal:** Categorized diff between two extraction runs, persisted and viewable.

**Requirements:** R20, R8a (Markdown export of a diff)

**Dependencies:** Unit 11.

**Files:**
- Create: `app/jobs/compute_diff_job.rb`, `app/services/ontology/diff_calculator.rb`
- Create: `app/models/run_diff.rb`, `db/migrate/*_create_run_diffs.rb`
- Create: `app/controllers/diffs_controller.rb`, `app/views/diffs/new.html.erb`, `app/views/diffs/show.html.erb`
- Test: `test/services/ontology/diff_calculator_test.rb`, `test/system/diffs_test.rb`

**Approach:**
- `DiffCalculator.compute(run_a, run_b)` returns a structured diff jsonb keyed by category: `object_added`, `object_removed`, `field_added`, `field_removed`, `field_type_changed`, `field_length_changed`, `picklist_values_added`, `picklist_values_removed`, `relationship_added`, `relationship_removed`, `formula_logic_changed` (after whitespace normalization), `validation_rule_changed`.
- Field identity: `(object_qualified_name + namespace, field_qualified_name + namespace)`.
- Picklist hash: `SHA256(values.sort.join("|"))`. Surface added/removed lists when hash differs.
- Persist `RunDiff(run_a_id, run_b_id, computed_at, diff_jsonb)`. Deterministic — same pair always produces same result.
- API-version drift: if `run_a.api_version != run_b.api_version`, ignore field flags only present in one version (whitelist of stable flags compared cross-version).
- Annotate diff with `installed_package_changes` (from manifest) so large diffs can be explained by package upgrades.

**Test scenarios:**
- *Happy path:* Adding a new field between runs surfaces as `field_added` with the field's api_name.
- *Happy path:* Renamed picklist value → both `picklist_values_added` and `picklist_values_removed`.
- *Edge case:* Two runs with identical schema → empty diff.
- *Edge case:* Formula text differs only in whitespace → not flagged as changed.
- *Edge case:* Cross-API-version run pair → only stable flags compared.
- *Integration:* `diffs#show` renders the categorized diff with collapsible sections per category.
- *Edge case:* `installed_package_changes` surfaced when present.

**Verification:** Diffs are deterministic and re-runnable; UI renders meaningfully.

## System-Wide Impact

- **Interaction graph:** GoodJob workers ↔ Salesforce APIs; controllers ↔ services ↔ Postgres; jobs ↔ run-directory file system; controllers ↔ audit DB. Authorization is enforced at controller AND job entry points. Turbo Streams broadcast job-state transitions to the UI.
- **Error propagation:** Job-level exceptions captured in `extraction_run.error_message`; partial-run state preserved (JSON files for completed objects are kept). Salesforce auth errors map to a single domain error class so the UI can present a "re-authenticate" path. Bulk 2.0 failures captured per-object so one bad object doesn't fail the whole run.
- **State lifecycle risks:** Run directories may exist without DB rows if a worker crashes mid-write — the loader is idempotent and the manifest tells us what completed. A failed `relational_loader` does not delete prior runs' rows. Cluster assignments belong to a run and are deleted when the run is.
- **API surface parity:** N/A — no external API surface.
- **Integration coverage:** End-to-end test using stubbed Salesforce (vcr cassette or similar) for at least the extraction → load → profile → view flow. Audit-log end-to-end test from controller through to the audit DB.
- **Unchanged invariants:** The repo's only existing artifacts (`docs/brainstorms/`, `docs/plans/`) are untouched. No existing schema to preserve — this is a greenfield app.

## Risks & Dependencies

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Sailfin's managed-package namespace isn't well-bounded → walk pulls in too much or misses Invoice/Brand equivalents | Medium | Medium | Discoverable at Unit 6 implementation: run a handshake listing all objects, inspect prefixes, choose seed set + allowlist deliberately. Walk termination is configurable, not hard-coded. |
| Tooling API returns null for managed-package formulas → R2 partially fails | Medium | Low | Graceful degradation in Unit 10 — log and continue; per-field "no source captured" indication on per-object pages. |
| Bulk API 2.0 drops formula/rollup fields silently | High | Medium | Cross-check in Unit 15: if a `calculated:true` field returned null in Bulk, log it and follow up with a REST `query`. |
| Username-Password OAuth flow is dead, JWT setup is fiddly | High (known) | Low | Pre-authorize the Connected App in the runbook (Unit 5); document the most common error (`invalid_grant: user hasn't approved this consumer`). |
| Id-suffix hash sampling produces biased samples (Salesforce Ids are weakly time-ordered) | High | Low | Acknowledge in Risks and in field-level documentation that the sample distribution biases toward typical recent record patterns; sufficient for design-time inspection. If statistical rigor matters later, switch to `MOD(...)` or full extract for small objects. |
| Cytoscape COSE blocks the main thread above ~3k nodes | Low (Sailfin orgs ~100-300 objects) | Low | Use `fcose` layout extension; surface a graceful warning if node count > 1000. |
| Mermaid ERDs explode visually above ~50 entities per diagram | Medium | Medium | Per-cluster ERDs (Unit 18) keep each diagram small; warn on cluster > 50 objects. |
| Salesforce API limits hit mid-run | Medium | High | Pre-run `LimitsCheck.guard!` (Unit 7); bounded Bulk concurrency (3); resumable run state (file-system manifest survives crashes). |
| Audit DB grows unbounded | Medium | Low | Partition by month in a future iteration; default retention (e.g., 1 year) configurable. Out of scope for v0.1. |
| Postgres role privilege drift in dev/test → audit immutability not enforced | Medium | Medium | `lib/tasks/audit.rake` reapplies role grants; smoke-test in CI checks the role can't UPDATE/DELETE. |
| Plan scope is large (21 units, 6 phases) and a single PR would be huge | High | Medium | Land in dependency-ordered slices: Phase A in one PR; Phase B in one PR; Phase C-D as one PR (extraction + profiling are coupled); Phase E as one PR per view; Phase F as one PR. Each is independently mergeable. |

## Documentation / Operational Notes

- **`README.md`** — quickstart for dev: `bin/setup`, `bin/rails server`, sign-in seed, first extraction.
- **`docs/runbook/salesforce-connected-app.md`** — Connected App + JWT cert setup runbook, including the pre-authorization step.
- **`docs/runbook/audit-db.md`** — provisioning the audit Postgres role + applying the immutability trigger.
- **`docs/runbook/run-storage.md`** — what lives under `storage/runs/`, retention guidance, sensitive run handling.
- **GoodJob dashboard** at `/jobs`, gated by `AdminPolicy`.
- **Mission Control Jobs** as the queryable UI for job history.

This plan does not commit to a hosting/CI setup — that belongs to whoever runs cashline's deploys.

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md](../brainstorms/2026-05-23-sailfin-extraction-and-ontology-requirements.md)
- **Restforce:** https://github.com/restforce/restforce
- **Salesforce JWT Bearer Flow:** https://help.salesforce.com/s/articleView?id=xcloud.remoteaccess_oauth_jwt_flow.htm
- **Salesforce Bulk API 2.0 limits:** https://developer.salesforce.com/docs/atlas.en-us.api_asynch.meta/api_asynch/bulk_common_limits.htm
- **Tooling API FieldDefinition / EntityDefinition:** https://developer.salesforce.com/docs/atlas.en-us.api_tooling.meta/api_tooling/tooling_api_objects_fielddefinition.htm
- **Limits endpoint:** https://developer.salesforce.com/docs/atlas.en-us.api_rest.meta/api_rest/resources_limits.htm
- **GoodJob:** https://github.com/bensheldon/good_job
- **Pundit:** https://github.com/varvet/pundit
- **Cytoscape.js:** https://js.cytoscape.org/
- **Mermaid:** https://mermaid.js.org/
- **Hotwire (Turbo + Stimulus):** https://hotwired.dev/
- **Rails 8 authentication generator:** see Rails 8 release notes
- **Salesforce API EOL policy:** https://developer.salesforce.com/docs/atlas.en-us.api_rest.meta/api_rest/api_rest_eol.htm
