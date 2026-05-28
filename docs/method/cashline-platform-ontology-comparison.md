# Sailfin vs cashline-platform — ontology comparison

A side-by-side read of the existing Sailfin / Salesforce ontology (documented in [sailfin-cluster-map.md](./sailfin-cluster-map.md)) against the in-progress work at `/Users/stephenparslow/Sites/cashline-platform`. The goal: give the team a shared map of where the two structures agree, where they diverge, and the dozen-or-so decisions still in the air.

**Status of the initial platform work.** A Rails 8 prototype with ~3 weeks of intense daily commits (May 19 → May 25 2026), 27 models, real CRUD, real UI, real ingestion pipeline, audit logging, and Devise + Pundit + Audited. Synthetic demo data only. It is explicitly *not* the final design — the architecture memo (`docs/Phase1/05_ARCHITECTURE_MEMO.md:58`) frames it as: *"The first platform should not try to replace Sailfin immediately. It should create the data and application substrate that makes future replacement possible."*

**Status of this document.** Living. Should be read alongside the cluster map, not in place of it.

**Scope of "ontology" in this document.** Where this document says "ontology" it means *the entity-relationship model* — the shape of the data, not the operational system that runs on top of it. Time tracking, workforce metrics, hours-per-invoice reporting, and SOC-2 attestation are out of scope. The boundary matters because several gaps below (communications ingestion, re-upload reconciliation) bleed into the operational layer; we surface them but classify them under that boundary rather than treating the data shape as the whole story.

---

## The 30-second summary

The **Parties** cluster (Client, Customer, Account) is structurally right in the initial platform work — and in a way that directly addresses the two biggest Sailfin pain points (Aethon-22x customer fragmentation, and the "where do internal divisions live" gap we identified in the cluster map). The *schema* is nearly 1:1 with the design we sketched. **Important caveat:** the bulk-ingest pipeline does not yet honour the schema's deduplication intent — `Customer::Organization` is only populated through a manual operator-resolution path, and there is no fuzzy-match safety net. The fix-in-design is real; the fix-in-runtime is not yet implemented.

The **invoice spine** is right at headline level — Invoice + InvoiceLineItem + InvoiceAttachment, money in integer cents, lean fields, JSONB for tenant extensibility.

The initial work introduces a **new capability with no Sailfin analog**: a self-service ingestion engine (Connector + MappingTemplate + FieldMapping + ImportBatch + ImportRecord + ValidationIssue + ResolutionDecision + CustomerAccountAlias) that lets a Client upload their aging reports and the operator map their columns into the canonical schema. This is the part of the platform that is most novel and closest to delivery.

The **cash side is not yet modelled**. There is no Payment, no PaymentLine, no PaymentBatch, no remittance, no bank-statement-to-invoice matching layer. Payment state is *inferred* from `Invoice.status` and `Invoice.balance_due_cents`. That works for an MVP that only watches the AR side, but it cannot survive contact with Cashline's actual operations — multi-invoice payments and payment batches are routine, not edge cases (the cluster map's sampling found roughly 13 payment-line allocations per payment and ~3,900 payment batches in Sailfin; these are headline ratios, not strict counts, but the shape is clear).

**Credit** (CreditApplication, CreditReview, Score, TradeReference) is also not yet modelled. Robert flagged credit as Cashline's 12-month priority. Material for ontology completeness; not a Week-1 blocker.

The cross-cutting design choice that matters most: **per-Client custom fields land in JSONB `metadata` columns**, not in a side-table keyed by Account. This is wrong for Cashline's domain. Collectors need to filter, validate, sort, and report on per-Client fields; JSONB makes all four painful. The right answer is a hybrid (JSONB for opaque source-system carry-over, plus a structured `ClientFieldDefinition` + `ClientFieldValue` for surfaced fields). See Gap 3.

---

## Side-by-side mapping

Cashline domain concept → Sailfin source → cashline-platform equivalent → status.

| Concept | Sailfin | cashline-platform | Status |
|---|---|---|---|
| Tenant (Cashline + future portcos) | (single Salesforce org) | `Operator` | ✓ — multi-tenant from day one |
| Client | `Brand__c` (52 fields) | `Client::Organization` | ✓ — clean, renamed |
| Client division/department | (none — gap we identified) | `Client::Group` (with per-Client `group_label`) | ✓ — designed in |
| Customer (canonical, deduped) | `Account` (352 fields, fragmented Aethon-22x problem) | `Customer::Organization` (operator-scoped, `normalized_name` unique) | ⚠ — schema permits dedup; ingestion does not yet automate it (see Gap 0) |
| Customer-side division (e.g., "Corporate AP") | (none) | `Customer::Group` | ✓ — new, optional |
| Account (Client↔Customer link) | `Account_Brand_Association__c` (16 fields) | `Customer::Account` (carries both `client_organization_id` and `client_group_id`; `account_number` unique per client_organization) | ✓ — closely matches; subtle wrinkle below |
| Per-Client custom extensions on the master tables | tenant-leaked columns on `sfsrm__Transaction__c` (31 `Viking_*` fields) and `sfsrm__Dispute__c` (11 `Viking_*` fields) | `metadata` JSONB on `Invoice`, `InvoiceLineItem` | ⚠ — JSONB-only is insufficient for fields collectors operate on; see Gap 3 |
| Person at Client | (Contact at Brand) | `Client::Contact` (added May 25) | ✓ — fresh, may not be fully integrated yet |
| Person at Customer | `Contact` | `Customer::Contact` | ✓ |
| Cashline collector staffing | `Reporting_Client__c` (the misleadingly-named staffing bucket) | (absent — only `Client::Membership` + `OperationalTask.assigned_to_user_id`) | ✓ — correctly cut from ontology |
| Invoice | `sfsrm__Transaction__c` (438 fields) | `Invoice` (clean) | ✓ — concept kept, field shape not migrated |
| Invoice line | `sfsrm__Line_Item__c` | `InvoiceLineItem` | ✓ |
| Invoice attachment | `ContentDocument` + `ContentVersion` | `InvoiceAttachment` (Active Storage) | ✓ — much simpler than SF's multi-table model |
| Dispute | `sfsrm__Dispute__c` (76 fields) | `InvoiceDispute` (8-subtype enum, lean) | ✓ — leaner |
| **Payment (cash receipt)** | `sfsrm__Payment__c` (~20K records) | **missing** | ❌ — biggest single gap |
| **Payment-to-invoice allocation** | `sfsrm__Payment_Line__c` (~261K records, ~13 per payment) | **missing** | ❌ — multi-invoice payment is the norm, not an edge case |
| **Payment batch** | `sfcapp__Payment_Batch__c` (~3,900 records) | **missing** | ❌ — confirmed real in Sailfin |
| **Bank statement remittance** | `sfcapp__Bank_Statement_Remittance__c` (~12K records) | **missing** | ❌ — open question whether ontology models pre-applied cash |
| **GL account** | `sfcapp__GL_Account__c` | **missing** | ⚠ — only if ontology touches the ledger |
| Promise to pay | (embedded in `Task`/`sfsrm__*` fields) | `PaymentPromise` (open/kept/broken/canceled) | ✓ — first-class, cleaner than Sailfin |
| Activity / communication | `EmailMessage` (203K), `Task` (20K, deeply customized) | `CommunicationEvent` (6 channels × 3 directions, 6 optional FKs) | ◐ — first-class log model exists; no email ingestion yet |
| Operational task / exception case | `Task` (68 fields incl. Cashline custom) | `OperationalTask` (15-category enum unifying tasks + exceptions + follow-ups) | ✓ — unified model |
| Email template | `EmailTemplate` (~922) | **missing** | ⚠ — needed when communications go in-platform |
| **Credit application** | `sfsrm__Credit_Application__c` | **missing** | ❌ — Robert's 12-month priority |
| **Credit review** | `sfsrm__Credit_Review__c` | **missing** | ❌ |
| **Trade reference** | `sfsrm__Trade_Reference__c` | **missing** | ❌ |
| **Credit scorecard** | `sfsrm__Score_Card_Parameter__c` / `_Value__c` | **missing** | ⚠ — Cashline Score POC is a Phase-2 candidate |
| Collections treatment / dunning plan | `sfsrm__Treatment__c` | (no formal model — `OperationalTask` is the closest) | ◐ — depends on whether dunning workflow is in ontology scope |
| Forecast | `sfsrm__Collection_Forecast__c` | **missing** | ⚠ — operations layer, may not belong in ontology |
| Reporting snapshots | `DSO_Report__c`, `Weekly_AR_Snapshot__c`, `Open_Invoices__c` | (use queries — `OperatorKpis`, `ClientGroupKpis`, `Invoices::CollectionBucketResolver`) | ✓ — derived, not persisted (matches the cluster-map recommendation) |
| File-upload ingestion engine | (manual / no equivalent — files come via email/Dropbox) | `Ingestion::Connector` + `MappingTemplate` + `FieldMapping` + `ImportBatch` + `ImportRecord` + `ValidationIssue` + `ResolutionDecision` + `CustomerAccountAlias` | ✦ — new capability, no Sailfin equivalent |
| Sailfin-as-source-system sync | (n/a) | `Invoice.source_system` + `Invoice.source_external_id`; `Ingestion::Connector.kind` reserves `sailfin: 4` | ⚠ — placeholders exist; `SyncRun`/`ExternalRecordMapping` planned but not built |
| User auth | `User` (183 SF fields) | One Devise `User` for operators + client users + (future) customers | ✓ — clean |
| Role / permissions | Salesforce profiles + roles + sharing | `OperatorMembership.role` + `Client::Membership.role` + `member_type` + Pundit policies | ✓ |

Legend: ✓ matches design intent / ◐ partial / ⚠ design choice or open question / ❌ missing critical piece / ✦ net-new capability.

---

## Design decisions worth keeping

### 1. `Operator` as the top-level tenant

The cluster map didn't have an operator tier at all — it implicitly treated Cashline as singular. The platform models `Operator` from day one, with `Client::Organization`, `Customer::Organization`, `OperationalTask`, etc. all carrying `operator_id`. Per the architecture memo this anticipates **future Western Trail portfolio companies** running the same platform.

That's the right level to model tenancy at. It also means cross-portco analytics are designable later (which Western Trail will want).

### 2. `Client::Group` (divisions) is a first-class entity, not bolted on

The cluster map's open question 1 was: *"How does the new ontology model divisions/departments inside a Client — child-of-Client, attribute on Account, both?"* The platform's answer: **a child-of-Client entity, with a per-Client UI label** (`group_label` defaults to `"Group"` but a Client can call it Division / Department / Region / Company / Location).

This is sharper than the cluster-map sketch. The label-per-Client move means UX doesn't have to compromise across Clients that use different vocabulary (a construction client calls them "Regions"; an oil-and-gas client calls them "Areas"; etc.).

And critically — **`Customer::Account` carries both `client_organization_id` and `client_group_id`**, both required, with a validator that they agree. That means Acme Energy's Houston desk and Midland desk each have their own Customer::Account for Chevron, with their own portal credentials, payment terms, contacts, notes. This is how Cashline actually operates (per the discovery interviews: collectors are organized by Client+Group, not by Client+everything). `account_number` is unique per `client_organization`, not per `client_group` — worth noting; means a Client can't reuse the same external account number across two groups.

### 3. `Customer::Organization` is normalized — the *schema* is right

`Customer::Organization.normalized_name` is unique within an Operator (`app/models/customer/organization.rb:22-23`). One Aethon, one Chevron, one ProFrac at the schema level. The `Customer::Account` then provides the per-Client view.

This is the *structural intent* that fixes the data-trust problem documented in the obsidian vault (Robert: *"The biggest problem we've had in Cashline is data"*). The cluster map identified the problem; the platform's schema is designed to absorb it.

**Caveat — the runtime doesn't yet honour the design.** See Gap 0 below. The bulk-ingest pipeline never touches `Customer::Organization`; only the manual "Create new customer account" controller path does. Normalization is a comparison of `squish.downcase`, so legal-suffix variation ("Aethon Energy LLC" vs "Aethon Energy") creates new orgs. The fix is small but not yet implemented.

### 4. Money in integer cents

No floating-point decimals. `subtotal_cents`, `tax_cents`, `total_cents`, `balance_due_cents`, `unit_price_cents`, `promised_amount_cents`. Currency stored separately as ISO 4217 with regex validation. This is right and would have been hard to retrofit later.

### 5. Unified `OperationalTask` with 15 category values

The cluster-map open question 4 was: *"Does the new ontology have one canonical Activity entity (with email/call/dunning-step as subtypes), or do Task and EmailMessage stay as separate entities?"* The platform splits the difference:
- **`OperationalTask`** for things-to-do (15 categories: invoice exceptions, dispute follow-up, broken-promise follow-up, payment follow-up, portal access, contact research, etc.)
- **`CommunicationEvent`** for things-that-happened (email / phone / portal / meeting / system / other × inbound / outbound / internal-note)

The two are linked via FKs (CommunicationEvent can point at a Task, Task can point at a CommunicationEvent). The Sailfin `Task` table had been overloaded for both purposes — the platform separates them cleanly.

### 6. `PaymentPromise` is first-class

Promise-to-pay was buried inside Sailfin's `Task` and `sfsrm__*` columns. The platform extracts it. PTPs are recorded with amount, currency, payment method (check/ACH/wire/credit_card/other), promise date, resolved-by-user, and a status enum (open → kept / broken / canceled). This is the right shape.

The platform's own summary flags this as deferred: PTPs are currently **invoice-level**, not account-level or multi-invoice. Reality: Customers say *"I'll send $50K next Tuesday covering these 8 invoices"* routinely. See Gap 6 below for the recommendation to promote this now.

### 7. Ingestion engine is a net-new capability, not a Sailfin port

Sailfin's data intake is email-forward + manual upload + Jason-the-contractor. The initial platform work includes a real ingestion pipeline: `Connector` (file-upload / manual / email-Dropbox / API / *sailfin*) → `MappingTemplate` (versioned, with `parser_settings` JSONB) → `FieldMapping` (per-column transforms, target-path routing, `metadata: true` for jsonb routing) → `ImportBatch` (one file run, SHA-256 dedupe, 10-state lifecycle) → `ImportRecord` (per-row staging) → `ValidationIssue` (8 types) → `ResolutionDecision` (5 decisions). Plus `CustomerAccountAlias` to learn that "Chevron - Acme Houston" in a file maps to a specific `Customer::Account`.

There is no Sailfin analog. This is genuinely new capability. The `datasamples/` directory has 10 real-shape AR file samples (xlsx + csv) the engine is being built against.

The `Ingestion::Connector.kind` enum already reserves `sailfin: 4` — the Sailfin sync is anticipated as a future connector kind, not a special case.

### 8. Audit logging via the `audited` gem

Every operational model (`Operator`, `OperatorMembership`, `Client::*`, `Customer::*`, `Invoice*`, `PaymentPromise`, `InvoiceDispute`, `CommunicationEvent`, `OperationalTask`, all `Ingestion::*`) is audited. JSONB `audited_changes`, polymorphic on `auditable_type`. Cashline's regulated context (PII, financial, brand-side CFO access) needs this.

---

## Gaps and risks

P-ratings below are based on **Week-1 pilot urgency** (does this need to be decided before real data starts flowing?), not on absolute size. A P0 gap blocks the pilot's stated deliverables; a P1 gap will hurt within 3 months if untreated; a P2 gap is real but can wait.

### Gap 0 (P0) — Customer dedup is not yet implemented in the runtime

The schema is right (see "Design decisions worth keeping", item 3). The runtime is not. Specifically:

- `Ingestion::CustomerAccountMatcher` and the rest of `app/services/ingestion/` never query `Customer::Organization`. They look for an existing `Customer::Account` (via `CustomerAccountAlias` or exact `display_name`/`account_number` match) and fall through to `needs_resolution` if nothing matches.
- The only code path that creates a `Customer::Organization` is the manual operator-resolution controller (`app/controllers/operator/import_records_controller.rb`), which uses `first_or_initialize` on `(operator, normalized_name)`. So dedup happens *only* when humans drive the "Create new customer account" workflow twice for the same operator.
- `normalized_name` is just `squish.downcase`. "Aethon Energy LLC" and "Aethon Energy" produce different normalizations and thus different Customer::Organizations.
- There is no fuzzy-match step, no review queue for near-duplicates, and no batch-ingest dedup against the canonical layer.

**Why this matters.** The Aethon-22x problem is the structural data-trust failure Robert and the team named most consistently. Shipping the pilot with the *schema* deduplicated but the *pipeline* silent on dedup will reproduce the failure in slow motion. The first weekly aging report that arrives with "Chevron - Acme Houston" will create one Account; the second week, if any character drifts, will create another.

**Recommendation.** Add a `Customer::Organization` lookup step to `Ingestion::CustomerAccountMatcher` before the `needs_resolution` fall-through: if `(operator, normalized_name)` matches an existing org, surface that match as a one-click resolution. Add a fuzzy-match suggestion (Postgres `pg_trgm` similarity ≥0.85) to the manual-resolution UI. Owner: Andreas / Stephen. Trigger: before first real client uploads. Default if not decided: leave as-is and accept that the pilot's "dedup story" is aspirational — that's not a non-decision, it's a no-fix.

### Gap 1 (P0) — No payment / cash side at all

This is the largest single departure from operational reality. The platform tracks invoices going *out*; it does not yet model cash coming *in*. The current "payment" representation is:

1. `Invoice.status` transitions to `partially_paid` or `paid`
2. `Invoice.paid_at` is set
3. `Invoice.balance_due_cents` is computed (forced to 0 when `paid` or `void`)

That's it. There is no `Payment` model, no `PaymentLine` (allocation), no `PaymentBatch`, no `BankStatementRemittance`, no `GLAccount`. No way to record:

- Cash received (when, how, from whom, reference number)
- A single payment applied across multiple invoices (the *typical* shape, not the edge case — Sailfin has ~13 invoice allocations per payment)
- Payment batches (~3,900 in Sailfin)
- Customer overpayments, short payments, prepayments
- Refunds
- The pre-applied state (cash arrived but not yet matched to invoices)

**Why this matters.** Cashline is a collections agency. Their work is fundamentally about getting cash applied to invoices. An ontology that can't represent the cash side is structurally incomplete for the business they're in.

**Recommendation.** Add Payment + PaymentLine + PaymentBatch as a next-epic. The shape is well-known from Sailfin and the cluster map. Discuss whether the bank-reconciliation layer (`BankStatementRemittance` analog) is in scope or lives in a separate cash-app system.

### Gap 2 (P2 for Week-1; P0 for ontology completeness) — No credit ontology

Sailfin has `CreditApplication`, `CreditReview`, `TradeReference`, and a configurable scorecard. The current schema has none.

**Why this matters.** Per Robert (vault discovery interview, May 5): *"Credit becomes bigger than collections — credit is Cashline's risk-management layer feeding collection cadence and bad-debt decisions."* This is the 12-month direction of the business, not a "nice to have." The "Cashline Score" POC is on the Phase-2 candidate list (6.71/10 score, per `/Users/stephenparslow/Sites/cashline/drafts/cashline-areas-of-focus-scored-2026-05-06.md`).

**Recommendation.** Block any work on the Cashline Score POC until `CreditApplication` + `CreditReview` + `TradeReference` are added to the schema. Shapes are well-understood from Sailfin's `sfsrm__Credit_*__c` tables. Owner: TBD. Trigger: at Phase 2 kickoff.

### Gap 3 (P1) — Tenant extensibility needs a structured layer alongside JSONB

The cluster map proposed: *"Per-Client custom extensions live on a side-table keyed by Client + Account, preserving normalization at the core and pushing tenant-specificity to the edge."*

The current implementation: **JSONB `metadata` columns on `Invoice` and `InvoiceLineItem`**, with `Ingestion::FieldMapping.metadata = true` routing arbitrary source columns into the jsonb at ingest time. No `CustomField` / `FieldDefinition` table.

**Why JSONB-only is wrong for this domain.** Robert (vault, May 5): *"Per-client custom fields — industry-nuance accommodation (retention vs. well data) is load-bearing for collection effectiveness."* Cashline does not just need to *carry* per-client fields — collectors need to *filter by, sort by, validate against, and report on* them. JSONB makes all four painful: GIN indexes on jsonb_path_ops are workable but not natural, validation lives only at the app layer, and there is no per-Client definition record so the UI cannot render a "manage your custom fields" surface without a side schema.

| Concern | JSONB metadata alone | Structured `ClientFieldDefinition` + `ClientFieldValue` |
|---|---|---|
| Schema overhead | None | One row per (Client, field-definition); one per value |
| Ingest flexibility | Excellent — anything goes | Requires field-definition before first ingest |
| Query / filter on a custom field | Painful | Native SQL |
| UI for "manage your custom fields" | Needs a separate definition layer anyway | Built directly off the table |
| Validation (required, type, allowed values) | Application-level only | Schema-level + application |
| Migration of Viking-style historical data | Easier (just stuff the keys in) | Requires definitions first; values follow |
| Audit history | Captured in `audited_changes` | Captured per-value-row |

**Recommendation.** Add a structured layer. Keep JSONB for opaque source-system carry-over (the Sailfin sync fills `metadata` for fields nobody has named yet); add `ClientFieldDefinition` + `ClientFieldValue` for fields a Client wants surfaced in the UI. `Ingestion::FieldMapping` routes per-column to either based on configuration. The two coexist. Owner: Andreas. Trigger: before any field-definition UI is scoped.

### Gap 4 (P1) — No communications ingestion

Sailfin has ~203K `EmailMessage` records, ~922 `EmailTemplate`s, ~138K `ContentDocument`s, and a Tara-side nightly contractor manually triaging 530 emails/day. The platform has `CommunicationEvent` (operator can log an event) but no email ingestion, no template library, no inbound-email parsing.

**Why this matters.** The pilot's stated dashboard features depend on showing the brand-side CFO recent activity — which means surfacing the email stream. And Phase 2's "AI email triage agent" candidate (7.14/10) explicitly builds on inbound email parsing.

**Recommendation.** Defer the email ingestion *implementation*; commit to the data shape now. Default position: **one `CommunicationEvent` row per inbound email**, with `channel: :email`, `direction: :inbound`, `body` holding the parsed text, and `ActiveStorage` attachments (made polymorphic to `CommunicationEvent`) for the source `.eml` and any attachments. The AI triage agent writes to the same table with `created_by_user_id` pointing at a system service-account user. Departing from this default needs an explicit reason — likely "we want a separate `Email` model with richer headers/threads/HTML." If the team takes that path, decide before the first inbound integration ships.

### Gap 5 (P2) — Task / Dispute overlap is not yet resolved (naming/policy, no schema cost)

`OperationalTask.category` includes `dispute_follow_up`, `broken_promise_follow_up`, `payment_follow_up`, `invoice_exception` — all of which could plausibly also live as `InvoiceDispute` rows or as nothing-extra-needed-on-a-Promise.

The platform's own summary flags this in `docs/CURRENT_APP_SUMMARY.md` (Likely Next Planning Areas): *"Exception case model versus compact `InvoiceDispute` plus `OperationalTask`."*

**Why it matters.** Day-to-day collector workflow is ambiguous on these boundaries. The AI email-triage agent will need a routing rule.

**Recommendation.** Write the rule down. Default: **a `InvoiceDispute` is created when the inbound event intends to *block payment* on a specific invoice** (PO mismatch, missing documentation, quantity dispute, etc.). **An `OperationalTask` is created for *work the collector needs to do* that doesn't block payment** — contact research, portal access issues, follow-ups. The AI agent's mapping: if the email is a stated reason for non-payment → InvoiceDispute. Otherwise → OperationalTask (with an appropriate category) or CommunicationEvent (if no action needed). A Dispute *may* have Tasks attached; a Task may exist without a Dispute. Owner: Stephen + Andreas. Trigger: before the first AI-triage prototype.

### Gap 6 (P0 by reversal cost) — Promise model is invoice-level only

Per `docs/CURRENT_APP_SUMMARY.md:324` in the platform repo: *"The first wave keeps promises invoice-level. Future account-level or multi-invoice promises are intentionally deferred."*

**Why it matters.** Customers routinely promise lump sums covering multiple invoices. Inventing a workaround at the UI level ("create N PaymentPromise rows summing to the promised amount") loses the fact that the promise *was* singular. The cost of fixing this is approximately zero today (synthetic data only) and unbounded later (every existing promise becomes ambiguous).

**Recommendation.** Promote `PaymentPromise` to support a many-to-many with `Invoice` via a `PaymentPromiseAllocation` join model now, before any real data accumulates. Owner: Andreas. Trigger: before the first real Client uploads.

### Gap 7 (P1) — Invoice lifecycle is 9 states; PRD calls for ~15

Current `Invoice.status` enum: `draft / ready_to_submit / submitted / in_review / approved / partially_paid / paid / disputed / void`.

PRD-implied states not yet added: `received` (by AP portal), `rejected`, `scheduled_for_payment`, `short_paid`, `awaiting_documentation`.

**Why it matters.** Sailfin's `sfsrm__Transaction__c` has ~64 date columns precisely because the lifecycle is finely-resolved. The pilot dashboards show "where is this invoice right now" — which means the status column needs more granularity. Enum migrations after real data has accumulated mean backfill logic for every existing row.

**Recommendation.** Add the five missing states in a single migration before the first real Client uploads. Owner: Andreas. If the dashboards reveal that even more states are needed, add iteratively from there. If a view depends on enumerating all states (e.g., a status filter UI), have it read from the enum definition rather than hard-coding.

### Gap 8 (P2, scope-closing) — No formal staff-assignment matrix (and that's correct)

Sailfin had `Reporting_Client__c` (the misleadingly-named staffing bucket) and `Case_Manager` and `Collector_Productivity`. The cluster map flagged most of this as out-of-ontology (operational, not domain).

The platform's current model: `Client::Membership` rows (with `member_type: :operator`) tell you who's *assigned* to a client_group. `OperationalTask.assigned_to_user_id` tells you who owns *this specific task*. There is no weekly portfolio snapshot, no hours / time tracking, no primary vs secondary collector, no capacity / target hours.

**Why it matters.** Bryce's 12-month north star (per the obsidian vault) is *"reduce hours-per-invoice (currently 33x spread across brands)"*. That metric can't be computed without time tracking — but time tracking doesn't belong in the data-shape ontology. Workforce metrics live in a separate operational layer (Sailfin's `Collector_Productivity__c` is an example of *what not to do* — it conflated operational state with domain data).

**Recommendation.** Treat this as decided: the ontology models the data, not the people working it. Workforce metrics, time tracking, and hours-per-invoice reporting live in a separate system or query layer that reads from `OperationalTask` + `CommunicationEvent` + `Client::Membership`. Document the decision so it doesn't keep coming up.

### Gap 9 (P1) — No `SyncRun` / `ExternalRecordMapping`

Planned in the architecture memo (Phase 6) but not yet built. The `source_system` + `source_external_id` columns on `Invoice` are placeholders.

**Why it matters.** Brand-by-brand Sailfin migration is the pilot's deliverable #3. Without a sync substrate, every brand migration is a one-off script with no audit trail of what was synced when.

**Recommendation.** Stand this up before the first real Sailfin sync. Shape is well-known (sync run → record-level outcomes → external-ID mapping table); a few days of work. Owner: Andreas. Trigger: before first real Sailfin sync.

### Gap 10 (P0) — Re-uploads of aging reports don't yet update existing invoices

The "Likely Next Planning Areas" section of the platform's own summary doc flags *"Repeated aging report reconciliation/update behavior after duplicate-blocking v1."* Currently the ingestion engine de-dupes via SHA-256 of the source file. But two file uploads with the same invoices in different states (Tuesday's aging report vs. next Tuesday's) should *update*, not skip. That's not yet implemented.

**Why it matters.** Cashline gets weekly aging reports per Client. The dashboards cannot show "where this invoice is today" if Tuesday's data is silently dropped because Monday's file already covered the same invoice numbers. This is the operational equivalent of dedup at the file level instead of the record level.

**Recommendation.** Build the per-record reconciliation pass before the first real Client uploads its second weekly file. Match on `(client_group, invoice_number)`; update the existing `Invoice` if the incoming row has changed; flag the change in the `ImportRecord` so the operator can audit. Owner: Andreas. Trigger: before the first Client's second weekly upload.

### Gap 11 (P1) — Picklist value translation is an unsized workstream

The Sailfin org has **366 picklist fields holding ~8,000 distinct values**. Once you strip out the 13 platform-supplied mega-picklists (`TimeZoneSidKey`, `LocaleSidKey`, `RelatedEntityType`, `SobjectType`, etc. — ~3,700 values, all carried verbatim from Salesforce), the **business-meaningful surface is ~342 fields and ~4,300 values**, concentrated on the `sfsrm__*` collections objects:

| Field | Values |
|---|---:|
| `sfsrm__Dispute__c.sfsrm__Sub_Type__c` | 70 |
| `sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` | 64 |
| `sfsrm__Treatment__c.sfsrm__Treatment_Group__c` | 37 |
| `sfsrm__Transaction__c.sfsrm__Sub_Reason_Code__c` | 36 |
| (~340 more, mostly 2–20 values each) | |

Every one of these is a vocabulary decision waiting to happen. The current platform enums (Invoice.status, PaymentPromise.status, OperationalTask.category, InvoiceDispute subtypes) carry between 6 and 15 values each. Mapping ~4,300 source values into a platform vocabulary of order ~100 values means **most mappings are many-to-one collapses or "drop"** — and someone has to make the call per value.

**Why it matters.** This is the work that turns a Sailfin extraction into Cashline platform records. It's also the work that hides silently:
- Gap 5 (Dispute vs Task boundary) depends on knowing which `sfsrm__Dispute__c.sfsrm__Sub_Type__c` values mean "blocks payment" (→ `InvoiceDispute`) vs "needs follow-up" (→ `OperationalTask`).
- Gap 7 (Invoice lifecycle states) calls for adding 5 platform states, but Sailfin's lifecycle is encoded across multiple picklist fields *plus* the 64 date columns on `Transaction`. The state additions are necessary but not sufficient — the source-to-platform state derivation rule is the real work.
- Decision #5 (migration fidelity) is undecidable without knowing what fraction of source picklist values survive vs get dropped. "Lossless per-field" is a different commitment when 30% of values map to `null`.
- Salesforce admins add picklist options through the UI with no commit trail. The Sailfin extraction tool already SHA256-hashes each picklist's value set per run and surfaces additions/removals on the diff page — use that as the canary for translation-table maintenance after the initial mapping.
- **Picklist availability *can* be record-type-scoped — but this org isn't.** Where an object has real record types, the global value set on a field overstates what any one subtype can use, so the extraction tool captures per-record-type availability from the describe/layouts endpoint into `srecord_types.picklist_values` (viewable at `/reports/record_types`). The full re-extraction (run 11, 2026-05-28) found **zero non-Master record types across all 123 in-scope objects** — every `recordTypeInfos` entry is the Master pseudo-type. So for the current Sailfin scope the global value set *is* the usable set, `/reports/record_types` is empty, and you can size the translation work **per field**, not per (record type × field). (Earlier drafts of this doc assumed `Dispute.Sub_Type`'s 70 values were split across record types; the data shows they are not.) Re-check this report if brands or future scope introduce record types.

**Recommendation.** Three steps, none of them large:

1. **Inventory.** Use `/reports/picklists` (added alongside this doc) to export the substantive ~342 fields with their values. (`/reports/record_types` would show per-subtype scoping, but it is empty for the current scope — no object uses record types; see Gap 11.) Owner: Stephen. Trigger: this week.
2. **Decide a target vocabulary for the four high-signal `sfsrm__*` fields** (Dispute.Sub_Type, Payment_Line.Reason_Code, Treatment_Group, Transaction.Sub_Reason_Code) before the first brand migration. These four hold ~200 values and feed Gaps 5 and 7. Owner: Stephen + Andreas. Trigger: before first real Sailfin sync.
3. **Defer the long tail.** The remaining ~340 fields are mostly 2–20-value picklists on standard objects (Lead.Industry, Contract.CurrencyIsoCode). Treat as carry-over via `Invoice.metadata` / JSONB until a use case forces a platform decision. Owner: Andreas. Trigger: per-field as needs arise.

**What this is *not*.** It's not a request to model all 4,300 values in the platform schema — it's a request to *write down the translation table* per substantive field, so the ingest pipeline has somewhere to look up "Sailfin says X → platform should record Y (or drop)."

### Risk 1 — `Operator::UserAccount` is not persisted

This is a Ruby `ActiveModel::Model` form-object wrapper around `(operator, user)`, with no table. It is a temporary scaffold. Either persist it or make it a true value object — leaving it in this hybrid state will trip up someone six months from now.

### Risk 2 — `CommunicationEvent` has 6 optional FKs (with no "at least one" guard)

This is a "shotgun foreign keys" pattern. Validation forces all set FKs to share `client_group`, but doesn't enforce that at least one is set. A `CommunicationEvent` with only `client_group_id` and `created_by_user_id` is currently valid — it becomes a floating log entry linked to nothing operational. May or may not be intentional; worth deciding explicitly.

The five-lens review (2026-05-27) found the same pattern recurs and worsens on `OperationalTask` (9 optional FKs, 8 cross-context validators). See [`./reviews/03-data-architect.md`](./reviews/03-data-architect.md#polymorphic-relationships--the-communicationevent-shape) for the discriminator + denormalized-context redesign.

### Gap 12 (P0) — `sfsrm__Transaction__c → Invoice` 1:1 mapping is wrong

The current side-by-side mapping (line 45) treats `sfsrm__Transaction__c` as a 1:1 source for `Invoice`. SRM Cloud's actual model: `sfsrm__Transaction__c` is the **polymorphic AR posting record**, carrying 14 transaction types (verified via `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`): `Invoice / Credit Memo / On Account / Apply Cash / Write Off / Write Back / Reversal / Offset / Auto Applied / Account to Account Transfer / Payment Refund / Deduction / Applied Credit / Discount`.

**Why it matters.** Mapping 1:1 to `Invoice` silently drops ~30–40% of AR-affecting rows (every credit memo, write-off, on-account cash, offset, deduction). Also re-frames Gap 1: the cash side is partly *inside* `sfsrm__Transaction__c`, not just in `sfsrm__Payment__c`.

**Recommendation.** Model `ARPosting` as the polymorphic parent with `kind` enum (`invoice / credit_memo / on_account / write_off / write_back / reversal / offset / applied_credit / payment_refund / deduction / discount / account_transfer`). `Invoice` becomes one subtype. Aligns with SRM Cloud's actual data model and gives Gap 1 a coherent landing zone. See [`./reviews/01-salesforce-architect.md`](./reviews/01-salesforce-architect.md#sfsrm_transaction__c--invoice) for the verification SQL and rationale.

### Gap 13 (P1) — PII sensitivity classifier misses banking/credentials/EIN

Independent finding from the data analyst review: [`app/services/ontology/sensitivity_classifier.rb:91`](../../app/services/ontology/sensitivity_classifier.rb)'s `PII_NAME_PATTERN` is missing `aba|routing|bank_account|iban|swift|ein|password|secret|token`, and the snake_case alternations (`first_name`, `last_name`) don't match Salesforce's camelCase (`FirstName`, `LastName`).

**Verified affected fields in run 9** (all currently classified `safe`):

- `sfsrm__EIN_or_Social_Security_Numbre_s__c` (note the typo — survives any regex looking for `social_security_number`)
- `sfsrm__Archival_Password__c`
- `Contact.FirstName`, `Contact.LastName` (only the compound `Contact.Name` is marked PII)
- `ABA`, `Routing`, `Bank_Account_No`, `IBAN` fields wherever they appear

**Why it matters.** Run 9 carried `top_values` for `Account.Name`, `Brand_Region__c`, `sfcapp__Bank_Name__c` containing real customer/bank/person names because the upstream classifier marked those fields `safe`. The `include_sensitive=false` guarantee is structurally broken.

**Recommendation.** Extend `PII_NAME_PATTERN` to include the banking and credentials vocabulary; add explicit camelCase variants or normalize input before matching. Re-run the classifier against run 9 and re-profile to scrub leaked `top_values` / `sample_values`. See [`./reviews/00-synthesis.md`](./reviews/00-synthesis.md#p01--pii-classifier-lets-bankingcredentialsein-through-as-safe) for the exact fix.

**Status.** The name-pattern fix shipped. The classifier now also consumes the *authoritative* signal it previously ignored: admin-declared `FieldDefinition.ComplianceGroup` (PII/PCI/HIPAA → `pii`) and `SecurityClassification` (Confidential/Restricted/MissionCritical → suppressed), pulled per field via the Tooling API and stored on `sfields.compliance_group` / `sfields.security_classification`. **Verified live against a fresh full re-extraction (run 11, 2026-05-28):** the per-field Tooling pull works end-to-end, but the Sailfin admins populate Data Classification on almost nothing — exactly **one** field across all 123 objects carries it (`sfsrm__Collection_Forecast__c.sfsrm__Friday_Collection__c` = `GDPR`; zero fields carry a `SecurityClassification`). So the authoritative signal is wired in but near-empty in this org: the name/type heuristics remain the load-bearing defence for the other ~4,557 fields, the opposite of the hoped-for split. Run 9's classification gap is superseded by run 11. (Caveat: run 11 was an `include_sensitive` run, so it does *not* by itself re-establish a clean non-sensitive canonical dataset — that still wants an `include_sensitive=false` re-extraction on the corrected classifier.)

### Gap 14 (P1) — Multi-currency + signed amounts contradict Design 4

Design Decision 4 ("money in integer cents", line 98) assumes a single currency and non-negative amounts. The data has Accounts holding balances in **10 currencies** (USD, CAD, BRL, GBP, EUR, AUD, ARS, NOK, COP, TTD) — some with different minor units (JPY=0, TND=3) — and every receivables-side amount has negative values (credits, reversals, refunds).

**Recommendation.** Add a `currencies` reference table with per-currency `subunits` (cents/fils/none), and a `currency_conversions` table with date-bracketed rates. Switch the `*_cents` columns from unsigned to signed before the first non-USD invoice lands. See [`./reviews/05-general-data-analyst.md`](./reviews/05-general-data-analyst.md#hidden-assumptions-in-the-cashline-platform-ontology) for the data-backed currency distribution.

### Gap 15 (P1) — Five architectural omissions: soft-delete, state log, provenance, tenant shell, structured extensibility

From the data-architect review ([`./reviews/03-data-architect.md`](./reviews/03-data-architect.md#whats-missing-entirely)):

1. **No `discarded_at` on any operational model.** First accidental delete is an audit-log replay exercise. Add to every operational model now.
2. **No `state_transitions` event log.** "How long did this invoice spend in `in_review`?" is answerable only via Ruby reconstruction over `audited_changes`. One ~80-LOC polymorphic table + `after_update_commit` hook covers this.
3. **No field-level provenance.** `Invoice.source_system` is row-level only. Gap 10's re-upload reconciliation needs to answer "Sailfin owns amount; cashline owns status" per field. Add `field_provenance jsonb`.
4. **No `Tenant::Group` shell above `Operator`.** Year-3 marketplace scenario (collections-PaaS hosting multiple agencies) becomes a multi-week migration. Pre-empting is one nullable FK; near-free now.
5. **No `ClientFieldDefinition + ClientFieldValue` structured-extensibility pair.** JSONB-only metadata fails the four collector concerns Gap 3 names (filter, sort, validate, report). Build the sidecar pair before the first non-pilot Client ingestion is configured.

### Gap 16 (P1) — Missing operational entities a real collections shop expects

From the collections domain expert review ([`./reviews/02-collections-domain-expert.md`](./reviews/02-collections-domain-expert.md#missing-operational-entities)):

1. **Credit Hold / Watchlist** — `CreditHold { customer_account_id, started_at, ended_at, reason, authorized_by_user_id, lifted_by_user_id }` + `Customer::Account.credit_limit_cents`, `dunning_enabled`.
2. **Customer Hierarchy / Parent-Pay** — two distinct FKs on `Customer::Organization`: `parent_organization_id` (org chart) and `pays_through_organization_id` (treasury arrangement).
3. **Dunning Strategy / Cadence** — `DunningStrategy { client_organization_id, name, rules: jsonb }` + `Customer::Account.dunning_strategy_id`. Configuration belongs in the ontology even if execution doesn't.
4. **Aging Bucket Definition** — `AgingBucketDefinition { client_organization_id, buckets: jsonb }` (Client-configurable, not hardcoded 30/60/90).
5. **Statement of Account** — most common dispute trigger; store the rendered PDF rather than re-deriving line items.
6. **Collection note routing** — notes belong on `Customer::Account` or `PaymentPromise`, not embedded on the triggering invoice.

---

## Decisions for Week 1

Six decisions, prioritised, with named owners and a default that ships if the meeting deadlocks. Pulled from the gaps above (P0/P1 only) plus the structural questions the cluster map left open.

| # | Decision | Default if undecided | Owner | Trigger |
|---|---|---|---|---|
| 1 | **Cash-side scope.** Model `Payment` + `PaymentLine` + `PaymentBatch` in the pilot, or defer? If deferred, what does the dashboard's "paid" cell read from? | Defer the full cash side; commit *now* to a stub `Payment` model carrying `invoice_id`, `amount_cents`, `received_at`, `method` so dashboards have a real read source. Allocations come in Phase 2. | Stephen + Andreas | Pilot kickoff |
| 2 | **Tenant extensibility model.** JSONB-only, or add `ClientFieldDefinition` + `ClientFieldValue` for surfaced fields? (See Gap 3.) | Hybrid: JSONB stays for opaque source-system carry-over; structured layer added for any field exposed in the operator UI. | Andreas + Stephen | Before first field-definition UI |
| 3 | **Customer dedup in the bulk ingest path.** (See Gap 0.) | Add a `Customer::Organization` lookup step + fuzzy-match suggestion to `Ingestion::CustomerAccountMatcher`. Without it the pilot reproduces Aethon-22x in slow motion. | Andreas | Before first real Client uploads |
| 4 | **Aging-report re-upload semantics.** (See Gap 10.) | Build per-record reconciliation against `(client_group, invoice_number)` before the second weekly upload. | Andreas | Before first Client's second upload |
| 5 | **Migration fidelity from Sailfin.** Lossless per-field, subset of fields, or forward-only from a cutover date? This decision drives the JSONB/side-table call, the lifecycle-state expansion, and the SyncRun design. | Subset of fields tied to Phase-1 dashboard needs; rest carried in `Invoice.metadata` for Phase 2. Cutover dates negotiated brand-by-brand. | Bryce + Stephen | Pilot Week 1 |
| 6 | **Promise model granularity.** Multi-invoice promises now, or invoice-level through pilot? (See Gap 6.) | Promote to many-to-many now via `PaymentPromiseAllocation`. The cost is near-zero today and unbounded later. | Andreas | Before any real promise data lands |
| 7 | **Picklist translation tables.** Write target-vocabulary tables for the four high-signal `sfsrm__*` picklists before the first brand migration. (See Gap 11.) | Decide target values for Dispute.Sub_Type (70), Payment_Line.Reason_Code (64), Treatment_Group (37), Transaction.Sub_Reason_Code (36); defer the long tail to JSONB. | Stephen + Andreas | Before first real Sailfin sync |

Decisions deliberately *not* on this list:

- **Communications ingestion shape** (Gap 4) — the default is "one CommunicationEvent per inbound email." Don't litigate unless a stakeholder objects.
- **Dispute vs Task boundary** (Gap 5) — the rule is "Disputes block payment; Tasks are work." Write it down, move on.
- **Workforce / staff-assignment scope** (Gap 8) — closed: ontology models data, not workforce.
- **Invoice lifecycle states** (Gap 7) — add the five missing states in a single migration. No discussion needed.
- **Credit ontology** (Gap 2) — Phase 2 trigger; no Week-1 action.
- **`Client::Group` for division-less Clients** — UX friction only.

---

## How to use this document

1. **For the Week-1 pilot kickoff:** open this side by side with `sailfin-cluster-map.md`. Use the side-by-side mapping table as the meeting agenda; use the "Decisions for Week 1" table as the topic queue.
2. **For roadmap planning:** the "Gaps and risks" section grades each gap P0 / P1 / P2 by Week-1 pilot urgency. P0s are immediate next-epic work; P2s can wait.
3. **As a living document:** update as decisions get made. Pair with the cluster map; both should drift together as the ontology takes shape.
4. **Deeper review (2026-05-27):** five independent specialist reviews live in [`./reviews/`](./reviews/). [`00-synthesis.md`](./reviews/00-synthesis.md) is the entry point. Gaps 12–16 above were derived from those reviews; the individual reviews carry the supporting SQL and citations.

---

## Sources

- Initial platform work: `/Users/stephenparslow/Sites/cashline-platform` (Rails 8, 27 models, 27 migrations dated 2026-05-19 → 2026-05-25). Key docs: `docs/CURRENT_APP_SUMMARY.md`, `docs/Phase1/05_ARCHITECTURE_MEMO.md`, `docs/Phase2/*`, `docs/context/*`.
- Sailfin cluster map: [`./sailfin-cluster-map.md`](./sailfin-cluster-map.md) (paired document).
- Discovery & strategic context: `/Users/stephenparslow/Sites/cashline` Obsidian vault — `resources/business/sailfin.md`, `drafts/cashline-revised-pilot-proposal-2026-05-14.md`, `raw/2026-05-05-cashline-robert-cameron-discovery-call.md`, `raw/2026-05-04-cashline-tara-discovery-call.md`, `drafts/cashline-areas-of-focus-scored-2026-05-06.md`.
- Sailfin extraction run: `2026-05-24T23-27-12Z-be06` (123 sobjects, ~4,800 fields).
- EDA report: [`./sailfin-eda-2026-05-27.md`](./sailfin-eda-2026-05-27.md) — schema-shape stats, namespace/relationship analysis, picklist counts.
