# Target-ontology data architect review

Target-side architecture review of the in-progress `cashline-platform` ontology, paired with `docs/method/cashline-platform-ontology-comparison.md` ("comparison doc" below). Worked from the comparison doc, the cluster map, and the cashline-platform Rails 8 source at `/Users/stephenparslow/Sites/cashline-platform` (db/schema.rb @ 2026_05_25_090000 plus the `app/models/` files). Scope: forward-looking only; the source side is covered by other reviewers.

## Headline

- **The party model is structurally correct** (Operator → Client::Organization → Client::Group, with Customer::Organization as a normalized canonical record and Customer::Account as the per-Client link). It absorbs the Aethon-22x problem at the schema level and resolves the cluster-map's division/department open question with `Client::Group + group_label`. This is the strongest part of the design — and the part with the most load-bearing assumptions baked in. See "Operator/Client/Customer hierarchy stress test" below.
- **Five architectural omissions are not in the gap list and should be**: no explicit soft-delete / discard column on any operational model; no record-version / temporal-history primitive beyond the `audited` append log; no multi-currency rate or conversion model despite per-row `currency` columns existing on `Invoice` and `PaymentPromise`; no retention/PII classification on `Customer::Contact` data; no `ExternalRecordMapping` even as a stub on entities other than `Invoice` (only `Invoice.source_system + source_external_id` exists).
- **`CommunicationEvent` is the canary** for a relationship-shape problem that recurs in `OperationalTask` and to a lesser degree in `Invoice`. Risk 2 names the 6-optional-FK pattern but understates how often the same pattern repeats. `OperationalTask` has 9 optional FKs and 8 cross-context validators. The lookahead remediation should be a discriminator + nullable FK rule + a `subject_type/subject_id` polymorphic association for the *primary* subject, with the other FKs treated as denormalized context (with a "set by callback" provenance bit).
- **Lifecycle modeling is enum-only, not state-machine-explicit**, and there is no transition log entity. Gap 7 (9 → 15 invoice states) is on the radar; the *structural* fix — a `state_transition` event log per operational model — is not. Without it, the audit gem becomes the de facto state machine, which is fine until you need to query "how long did this invoice spend in `in_review`?" with reasonable performance.
- **Source-of-record (SoR) story is incomplete past the first SyncRun.** `Invoice.source_system + source_external_id` is the only place provenance lives. Once Sailfin invoices, AP-portal invoices, and per-Client ingestion files all land in the same table, the SoR question becomes per-field, not per-row — and the current model can't represent that.

---

## Entity model — what's right, what's load-bearing-but-fragile

### What's right

- **Money in integer cents** with per-row ISO-4217 currency (comparison §Design 4, lines 98–100), regex-enforced at `app/models/invoice.rb:44–48`.
- **`(client_group_id, invoice_number)` uniqueness** on `invoices` (schema.rb:465) — natural-key invariant at the right granularity. Not per-Client (wrong for the Houston/Midland desk case, lines 86–88), not global.
- **Operator-scoped uniqueness on `customer_organizations(operator_id, normalized_name)`** (schema.rb:222) — the schema lever that makes the Aethon-22x fix possible; comparison Gap 0 is right that runtime doesn't yet honour it.
- **`active_storage_attachments` polymorphism** flattens Salesforce's multi-table file model correctly (cluster-map.md:324–328).

### Load-bearing but fragile

1. **`Customer::Organization.normalized_name` is a single, lossy normalization** (`canonical_name.to_s.squish.downcase`, `app/models/customer/organization.rb:27–29`) and the only uniqueness key. There's no `legal_name`/`dba_name`/`aliases` separation (`legal_name` exists but is informational), no fuzzy-match column, no `pg_trgm` index, and no `canonical_organization_id` self-reference for merges. When dedup is discovered after 6 months, the merge has to update every `Customer::Account`, `Customer::Group`, and `Customer::Contact` row with no tombstone trail.

   **Recommendation:** add a `canonical_organization_id` self-FK (NULL = canonical; non-NULL = tombstone pointing at survivor) plus `merged_at`. Lookups union on `coalesce(canonical_organization_id, id)`. Costs one nullable column; saves a lot of pain.

2. **`Customer::Account.account_number` uniqueness scoped to `client_organization`** (schema.rb:176, comparison lines 86–88). Probably correct for Cashline, but will surface as a confusing validation error on the first real ingestion where a Client genuinely numbers per-group.

3. **No `customer_account_id` history on `Invoice`.** When a Client restructures desks, invoices silently move; the audit log captures it but there is no temporal join from "which account did this invoice belong to on 2026-03-15?" without Ruby reconstruction.

4. **`Invoice.balance_due_cents` is recomputed in a `before_validation` callback** (`app/models/invoice.rb:72–78`) but stored. Once `Payment` arrives, the recompute logic doesn't know about payments. A stored-derived field that gains new inputs is a deferred bug. Promote to a Postgres generated column or a single recompute service before Phase-1 stub `Payment` (comparison Decision 1, line 302) lands.

---

## Extensibility — JSONB, custom field metadata, tenant overlays

Comparison Gap 3 (lines 176–194) is right in direction, understated in urgency. The current shape is `metadata jsonb` on `invoices` and `invoice_line_items` only (schema.rb:454, 430). Sailfin has **45 `Viking_*` fields** across `Transaction__c` and `Dispute__c` (confirmed via `SELECT COUNT(*) FROM sfields WHERE api_name LIKE 'Viking_%'` against extraction run 9) plus Alpine and Casey Sprayberry leakage. JSONB-only is wrong because collectors *filter on* these fields.

### What's missing structurally

There is no `ClientFieldDefinition` / `ClientFieldValue`. The right precedent is **not** EAV (anti-pattern for query-heavy workloads) and **not** pure JSONB-with-schema (solves storage but not the four collector concerns in Gap 3's table). It's a hybrid sidecar:

```
client_field_definitions
  id, client_organization_id, key, label, data_type (enum),
  required, allowed_values jsonb, target_entity (enum: invoice/customer_account/invoice_line_item),
  position, retired_at
client_field_values
  id, definition_id, owner_type, owner_id,
  value_string, value_number, value_date, value_boolean, value_text
  unique(definition_id, owner_type, owner_id)
```

Polymorphic `owner_type/owner_id` is appropriate here — sidecar, not primary FK. Indexes on `(definition_id, owner_id)` for "all Viking-PO-Number values" and `(owner_type, owner_id, definition_id)` for "all custom fields on this invoice."

### When JSONB becomes debt

Three triggers:

1. **First report filter on a metadata key.** Either a GIN expression index per key (expensive to maintain) or a structured column. Third time you do it, you're already retrofitting.
2. **First per-Client validation** ("Viking requires PO before submission") — app-level validators need a definition table they can read.
3. **First sync of Sailfin's 45 Viking fields into `invoice.metadata`** — Sailfin admins are inconsistent (`viking_po_number` vs `Viking_PO_Number` vs `vikingPONumber`). Without a definition layer, the normalization happens nowhere.

**Recommendation.** Build `ClientFieldDefinition` + `ClientFieldValue` before the first ingestion mapping is configured for any Client other than the pilot. Retrofitting later means migrating from JSONB to rows — doable, lossy, no test path.

---

## Polymorphic relationships — the CommunicationEvent shape

Risk 2 (comparison lines 290–292) flags `CommunicationEvent`'s 6 optional FKs. The shape repeats and is worse elsewhere:

| Model | Optional FKs | Required FKs | Cross-validators |
|---|---|---|---|
| `CommunicationEvent` | invoice, customer_account, customer_contact, operational_task, payment_promise, invoice_dispute (6) | client_group, created_by_user | 1 method, 6 records |
| `OperationalTask` | invoice, customer_account, customer_contact, customer_organization, payment_promise, invoice_dispute, communication_event, client_group, assigned_to_user (9) | operator, client_organization, created_by_user | 8 `*_matches_context` methods |
| `Invoice` | customer_group (1) | client_group, customer_account, created_by_user | 3 methods |

`OperationalTask` derives most of its FKs from whichever related record was set first (`app/models/operational_task.rb:55–94`). Two problems:

- A row with only `payment_promise_id` is functionally identical to one with only `invoice_id` — the callback walks the graph either way. The schema doesn't record *what the user was actually working on*.
- No "at least one of {invoice, customer_account, payment_promise, invoice_dispute} must be set" guard. A `CommunicationEvent` with only `client_group_id` is valid: a floating log entry linked to nothing operational.

### Redesign — discriminator + denormalized context

The cleanest shape (these are *activity records about a subject*):

```
operational_tasks
  subject_type    (enum: invoice / dispute / promise / customer_account / contact / standalone)
  subject_id      (polymorphic; null only when subject_type=standalone)
  client_group_id, customer_account_id, invoice_id   -- denormalized, set by callback
  context_derived_at, context_derived_from           -- provenance bit
```

Same for `CommunicationEvent`. Required `subject_type + subject_id` makes "no floating log entries" a schema-level invariant; denormalized context FKs preserve query performance; a single discriminator lets reporting `GROUP BY subject_type` honestly.

The alternatives — STI, abstract base + subclasses, join table per type — are wrong here. STI gives you 6 mostly-empty tables. Abstract base means changing the inheritance every time a new subject type appears. Join-table-per-type means 6 joins for "all activity for this customer." The discriminator pattern is what Salesforce's `WhatId`/`WhoId` settles on; it's the precedent worth following with better naming.

---

## Lifecycle, state, versioning

### State machines are implicit

Every operational model has a `status` enum; no model uses an explicit state-machine library. Transitions happen via direct assignment in `before_validation` callbacks (`payment_promise.rb:57–63`, `invoice_dispute.rb:63–69`, `operational_task.rb:96–102`). That works today but:

- **No `state_transition` log entity.** "When did this invoice go from `in_review` to `approved`, and who did it?" is answerable only via the `audits` table — which stores diffs, not transitions. Reconstruction is paginated and unindexable.
- **No transition guard.** The enum permits any-to-any. Callbacks enforce a few invariants (`resolved_at` consistency) but the transition graph is undocumented.
- **Gap 7 (9 → 15 invoice states)** is quantitative; the qualitative problem is that adding states without a library means every state-dependent UI/report/job has to learn them individually.

### Versioning

Only via `audited` (schema.rb:45–65). Append-only, good for compliance, but:

- **No record-level "published version" concept.** `MappingTemplate` has `version + activated_at + superseded_by_id` (schema.rb:329–349) — the right shape — but no other model has it. `ClientFieldDefinition` will need it; `Invoice` arguably needs it once Gap 10 re-upload reconciliation lands (is a changed amount a new version or an update?).
- **No temporal queries.** Postgres has `temporal_tables`; not used. Audit log answers "what did this look like on 2026-03-15" only via Ruby reconstruction.

### Recommendation

1. Add a `state_transitions` event log now (~80 LOC):
   ```
   state_transitions
     transitioner_type, transitioner_id (polymorphic),
     from_state, to_state, transitioned_at,
     transitioned_by_user_id, reason, metadata jsonb
   ```
   Wire to `after_update_commit` when `status_previously_changed?`. Best ROI move for answering business questions later.
2. Adopt `state_machines-activerecord` before Gap 7's 5-state migration.
3. Defer temporal-tables. Audit + state_transitions covers ~95% of "what changed when."

---

## Audit, sync, provenance, source-of-record

### Audit

`audited` is wired correctly across the 14 main models (Design 8, lines 124–127). Polymorphic on `auditable_type`, JSONB diffs, version column, request UUID, indexed sanely (schema.rb:60–64). Right baseline.

**Gap**: it's the *only* answer to "what changed when." Fine for investigation, awkward for operations ("alert me when an invoice is revised after submission"). The `state_transitions` table above is the operational complement.

### Sync (Gap 9, lines 243–248)

Today: `Invoice.source_system` + `Invoice.source_external_id`, unique together (schema.rb:472). Only on `Invoice`. `Ingestion::Connector.kind` reserves `sailfin: 4`. No `SyncRun`, no `ExternalRecordMapping`, no per-entity sync state. The right shape is straightforward; the comparison doc's prioritization is correct.

### Source-of-record per entity

The schema implicitly says: **Invoice's SoR is whoever wrote it last.** Wrong for collections.

| Entity | Likely SoR | Wired? |
|---|---|---|
| `Customer::Organization` | Operator-curated | Partial — manual UI only |
| `Customer::Account` | Client AP file (account number, balance) | No SoR column |
| `Invoice.amount/dates` | Client AR system | Partial — `source_system` exists |
| `Invoice.status` | cashline-platform | No conflict policy |
| `Invoice.metadata` | Client AR system | No structured mapping |
| `InvoiceDispute`, `PaymentPromise` | cashline-platform (born here) | N/A |
| `CommunicationEvent` (inbound email) | Email provider | No ingestion yet |
| `Payment` (when it exists) | Bank statement / cash app | N/A |

The question Gap 9 doesn't answer: **on re-upload (Gap 10), which fields can the AR file overwrite and which are locked because cashline now owns them?** There is no field-level provenance on `Invoice`.

**Recommendation**: a `field_provenance jsonb` on `Invoice`: `{ "amount": { "source": "sailfin", "synced_at": "..." }, "status": { "source": "cashline", "set_by_user_id": 42 } }`. The operational expression of "Sailfin owns amount; cashline owns status." Without it, Gap 10's re-upload semantics are ad hoc.

---

## Operator/Client/Customer hierarchy stress test

The three-level hierarchy is **correct for the next ~3 years**. Places it will hurt:

### What's right

- `Operator` at the top is the right tenancy level (Design 1, lines 76–81). Designing tenancy into year 1 saves a multi-quarter retrofit when Western Trail's second portco arrives.
- `Client::Group` first-class with `group_label` (Design 2, lines 82–88) is sharper than the cluster map's sketch — per-Client "Region/Area/Department" relabeling lands cleanly.
- Operator scoping is consistently applied (`client_organizations.operator_id`, `customer_organizations.operator_id`, `operational_tasks.operator_id`) and the `client_and_customer_share_operator` validator (`app/models/customer/account.rb:66–71`) enforces it.

### Where the assumptions will hurt

1. **Operator is a hard wall.** Schema assumes Operator-A and Operator-B never share data. Multi-portco shared services (a shared collections team; a shared credit-decisioning model) are impossible. Fix is a `Tenant::Group` above Operator — minor pain if added now, multi-week migration with real data later.

2. **`Client::Group` required on `Customer::Account`** (schema.rb:162, `null: false`). Bakes in "every Customer relationship is mediated by a Group." Low pain — handled by a per-Client "default group" sentinel.

3. **`Customer::Organization` is operator-scoped, not global.** Right default for tenancy isolation; means the same real-world Chevron appears as separate rows across operators. No cross-operator portfolio analytics. Solvable with a `global_organization_id` reference later, not pressing.

4. **No Customer-side visibility.** The brand-side CFO portal is on the roadmap; `client_visible` and the `visibility` enum exist. But there is no "what would a Customer themselves see if/when we surface a customer portal" layer. Significant later: adding a third visibility level to every model means re-evaluating what "internal" means.

---

## What's missing entirely

Beyond the comparison doc's gap list:

1. **Soft-delete / discard.** No `discarded_at` columns anywhere; `dependent: :destroy` on most associations. The first accidental delete of a `Client::Group` with 6,000 invoices is a recovery exercise via audit-log replay. **Add `discard` to every operational model now.**
2. **Multi-currency rate model.** `Invoice.currency` and `PaymentPromise.currency` are per-row strings with no `currencies` reference, no `exchange_rates`, no "Invoice in EUR, paid in USD" policy. Fine until the first international Client. **Add `currencies` + `currency_conversions` with date-bracketed rates before the first non-USD Invoice.**
3. **Retention / PII classification.** `Customer::Contact` and `Client::Contact` carry email, phone, names. No `pii_classification`, `retention_until`, or `consent_recorded_at`. Sailfin's `Individual` / `PartyConsent` were the source-side answer (cluster-map.md:120–122). Missing policy more than missing table — document the cut explicitly.
4. **Field-level provenance.** Restating from §SoR — no per-field provenance on any model.
5. **Idempotency keys on `Ingestion::ImportBatch`.** `source_sha256` (schema.rb:294) is a content fingerprint, not an idempotency key. Same file via two connectors = two batches; a retry can double-write. **Add `client_idempotency_key`.**
6. **Per-Operator settings.** `Operator` has only name/sector/slug/description. No `settings jsonb`, no per-Operator enum overrides. First non-Cashline Operator that doesn't use the 15th `OperationalTask` category has nowhere to express that.
7. **Outbox pattern for sync.** When `SyncRun` lands, the natural shape is `outbox` (records to push) + `inbox` (records pulled, pending processing). Neither exists. Without it, sync write-paths couple to remote-system availability.
8. **Notification / digest model.** Audit captures *what* happened; there's no `Notification` table for "this user should be told." Out-of-scope for Phase 1, in-scope by Phase 2 once the CFO portal is real.
9. **Cash side entire** — Gap 1 in the comparison doc, not re-litigated here.

---

## Year-3 stress test

Three plausible 3-year requirements, scored by migration pain:

### 1. Second receivables source (AP-portal scraper alongside the Sailfin sync + file uploads)

**Pain: Low.** `Ingestion::Connector.kind` already abstracts source type; `Invoice.source_system` is a string. Additive if Gap 9 lands first. The non-obvious bit: the AP portal will have **partial duplicates** with the Client's own AR-file uploads — same invoice, two channels. Without `field_provenance`, last-write-wins corrupts data. **The SoR work is the gating dependency. Easy if done; ugly if not.**

### 2. Marketplace Operator with sub-tenants (collections-PaaS hosting multiple agencies, each with their own Clients)

**Pain: High.** This is where "Operator as top-level tenant" hurts. Options:
- (a) `Tenant::Group` above Operator; every join updated to pass tenant-group scoping. Multi-week migration with real data behind it; every controller/policy/scope changes.
- (b) Repurpose `Operator` as the sub-tenant; add `MarketplaceOperator` above. Less invasive, semantically confusing.
- (c) Multiple databases per marketplace tenant. Trivial in concept; no cross-tenant analytics, separate deployments.

Cleanest path is (a). **The year-3 scenario that shouldn't be assumed away.** A `Tenant::Group` shell now (one table + nullable FK) is near-free; later it's a quarter of work. Worth a defensive design move.

### 3. Sanctions-screening flow (OFAC lookups, hold queue, clearance workflow)

**Pain: Medium.** Needs a `ScreeningResult` per `Customer::Organization` (operator-scoped normalization is exactly what makes this lookup tractable), a "held" state on `Invoice` / `Customer::Account`, and an auditable clearance workflow. The screening data is a clean sidecar; the painful part is teaching every "can I submit this invoice?" call site about a new state. **Exactly the scenario the state-machine library + state_transitions log pays for** — answer "what's blocking submission" structurally rather than by scan. Medium pain; lower if §Lifecycle groundwork is laid first.

---

## Closing

The party model and the ingestion engine are the strongest parts of the design. The comparison doc identifies most of the operational gaps correctly. The architectural moves not currently on the gap list — soft-delete, a `state_transitions` event log, field-level provenance, a `Tenant::Group` shell above Operator, the `ClientFieldDefinition + ClientFieldValue` extensibility pair, and the discriminator-based redesign of `CommunicationEvent` / `OperationalTask` — are the ones that quietly decide whether year 3 is a feature-velocity year or a migration year. None of them are expensive now. All are expensive later.
