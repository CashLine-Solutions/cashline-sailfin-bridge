# Salesforce solution architect review

Reviewing the four core docs against the live Sailfin extraction (run_id=9, 123 sObjects, 4,554 fields) with a Salesforce lens: what does Salesforce ship, what does the `sfsrm__` SRM Cloud package actually mean by the names it uses, and what is the team treating as bespoke that is actually load-bearing standard semantics?

---

## Headline

- **`sfsrm__Transaction__c` is not "Invoice." It is a polymorphic AR sub-ledger record** carrying 14 transaction types ("Applied Credit", "Apply Cash", "Deduction", "Credit Memo", "Write Off", "Reversal", "Offset", "On Account", "Auto Applied", "Account to Account Transfer" … verified from `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`). Treating it as a one-to-one source for `Invoice` in cashline-platform (`cashline-platform-ontology-comparison.md:45`, `sailfin-cluster-map.md:139-154`) silently throws away credit memos, write-offs, on-account cash, and offsets — every non-invoice posting against AR. This is the single biggest mapping error currently in the comparison doc.
- **The Sailfin org uses none of Salesforce's record-typed polymorphism, none of its field-history tracking, none of its `AccountContactRelation` many-to-many, and no Person Account model** (verified: zero `RecordTypeId` fields on Account/Contact/Case/Opportunity/Task/Event/Lead/`sfsrm__*` objects; no `IsPersonAccount`; no `AccountContactRelation` in the extraction). The cluster map (`sailfin-cluster-map.md:69-77`) correctly identifies Account as heavily extended but doesn't notice that the *standard* affordances are turned off. That changes what we can rely on for change history, sharing, and contact-to-multiple-accounts — all of which Sailfin solves with custom fields the comparison doc treats as bespoke domain shape.
- **The team is correctly trimming SFSRM config tables (Cluster 6) but is mistakenly throwing the standard SF approval engine, sharing model, and `Task.WhoId/WhatId` polymorphism into the same "cut" bucket** (`sailfin-cluster-map.md:359-372`). Sailfin's collections workflow is *demonstrably* using `ApprovalSubmission`/`ApprovalWorkItem` and `Task.WhatId` polymorphism (verified: both extracted, `Task.WhoId` and `WhatId` are present as reference fields). Cashline-platform is reinventing both as `OperationalTask` plus future workflow plumbing.

---

## Standard vs. managed-package vs. custom — what the team is conflating

The extraction's 123 sObjects split into three groups with very different mapping implications, and the cluster map treats them in one undifferentiated keep/cut table:

| Group | Count | What it is | What it means for mapping |
|---|---|---|---|
| Standard SF (no namespace, `custom=false`) | 77 | Stock Salesforce, owned by salesforce.com | API-stable across releases. Semantics documented. Carry forward via API contract, not field-by-field. |
| `sfsrm__` (SRM Cloud / Sigma Infosolutions managed package) | 35 | Vendor-shipped collections package | Vendor owns the schema. Sailfin's Salesforce admins do *not* control these fields. Upgrade-breaking. |
| `sfcapp__` (cash-application managed package) | 4 | Vendor-shipped cash app | Same as above — vendor owns it. |
| `(custom-no-ns)` | 7 | Cashline-installed objects in the org | Cashline controls these fully. Mapping is a normal data migration. |
| Custom fields on standard objects | 1,573 | Cashline-added extensions | Owned by Cashline's SF admins. Includes the 295 custom fields on Account and the 31 `Viking_*` columns on `sfsrm__Transaction__c`. |

The conflation the team is making: the cluster map's keep/cut table (`sailfin-cluster-map.md:429-457`) treats all 123 objects as if they were Cashline's to redesign. They are not. Critically:

1. **The 31 `Viking_*` fields on `sfsrm__Transaction__c`** are *Cashline-added custom fields* on a *managed-package object*. They survive a `sfsrm` upgrade (custom fields on managed objects are owned by the subscriber org). The cluster map is right that they're tenant leakage. But the implication for migration is the opposite of what's stated: they are the *easiest* fields to migrate because Cashline already owns them. The hard fields are the **426 custom fields on `sfsrm__Transaction__c` that are part of the SFSRM package itself** — those are vendor-controlled and may change in any SFSRM release.

2. **`Account` is "wildly extended" at 295 custom fields** (`sailfin-eda-2026-05-27.md:127-137`), but the cluster map doesn't notice that **Account is still using only a tiny fraction of what standard SF Account offers**: no Person Account, no record types, no `AccountContactRelation`, no `ContactPointAddress`. The "352 fields" figure is mostly Cashline custom plus a thin layer of standard SF that's been left at defaults. Re-modeling Account as `Customer::Organization` (`cashline-platform-ontology-comparison.md:40`) loses nothing standard — but the team should know this is a *conscious decision* to abandon the standard CRM ownership/sharing/contact model, not a coincidence.

3. **`sfsrm__` is not "Sailfin's package" — it is SRM Cloud by Sigma Infosolutions**, a third-party AppExchange product. The cluster map refers to it as "Sailfin's primary managed package" (`sailfin-eda-2026-05-27.md:22`) which is misleading. Sailfin (the customer) is *using* SRM Cloud. This matters because: (a) SRM Cloud documentation exists publicly and should be sourced before naming objects, (b) any data dictionary the vendor publishes is authoritative over our interpretation, (c) the contractual relationship Cashline has with Sigma will determine whether sync-back into `sfsrm__*` is even allowed.

**Risk if the team treats all three groups the same.** Two specific failures: (1) we will design `cashline-platform.Invoice` based on the 31 `Viking_*` columns and miss that `sfsrm__Transaction__c.sfsrm__Type__c` (the SRM-owned type discriminator) is what determines whether the row is an invoice at all (see Headline 1); (2) we will spend effort writing translation logic for `sfsrm__Status__c` values like `"0. UNAPPROVED" / "1. APPROVED FOR REVIEW" / "2. APPROVED FOR SIGNATURE (ACCRUED)"` (verified from `spicklist_values`) without realizing those are the canonical SRM Cloud invoice-approval lifecycle states — they should be carried as a vendor enum, not re-mapped per-value.

---

## Standard Salesforce semantics the ontology should not reinvent

The comparison doc (`cashline-platform-ontology-comparison.md:33-69`) maps cashline-platform models against Sailfin objects. It is missing the standard-SF layer entirely. Here is what's in the extraction that the comparison doc doesn't engage with:

### 1. `AccountContactRelation` is absent — and that's a deliberate Sailfin choice the team should clock

Salesforce ships an `AccountContactRelation` object that lets one `Contact` be related to many `Account`s (the standard answer to "this person works with three of our customers"). It is **not in the extraction** (verified). Sailfin is therefore enforcing strict one-Contact-per-Account, which is *also* what cashline-platform does with `Customer::Contact`. Fine — but the team should *know* they made this choice. If Cashline's customers have shared contacts across multiple accounts (a real pattern in collections — one AP clerk handles 5 sister companies), the platform model needs `Customer::ContactRelation` or it will fragment contacts the same way Aethon-22x fragmented customers.

### 2. No `ContactPointAddress` / `ContactPointEmail` / `ContactPointPhone`

Standard SF has had this since Spring '20 — one Contact can have multiple verified contact points with type/purpose flags. The extraction has zero of these. Sailfin instead uses Contact's flat single-email / single-phone fields. The cashline-platform `Customer::Contact` model inherits this limitation (per the comparison doc's clean mapping). Recommend the team consciously decide whether multi-channel-per-person is in scope; if yes, the standard SF object is a usable shape to copy.

### 3. No `*History` field-history tracking

Salesforce ships `AccountHistory`, `ContactHistory`, `CaseHistory`, `OpportunityFieldHistory` automatically when field-history tracking is enabled. Only `OpportunityHistory` was extracted (verified). This means **the Sailfin org has no Salesforce-native audit trail of who changed what on Account/Contact/Dispute/Transaction**. Any "show me what changed on this invoice" requirement currently has no source data. The comparison doc's mention of `audited` gem coverage (`cashline-platform-ontology-comparison.md:124-128`) is well-placed — but be clear with the team that there is no pre-existing audit history to migrate; forward-only from go-live.

### 4. No `RecordType` polymorphism — and Sailfin is paying for it in picklist length

Standard SF practice for "this object has variants" is to use `RecordType`. The pattern: one `Account` table, multiple record types (Prospect, Customer, Partner) each with its own page layout, picklist value subsets, and validation rules. Zero `RecordTypeId` fields exist on Account, Contact, Case, Opportunity, Task, Event, Lead, or any `sfsrm__*` object in the extraction (verified). Sailfin has instead encoded variant behavior into **string-typed `*_Type__c` fields** on `sfsrm__Transaction__c`: `Transaction_Type__c`, `Document_Type_Description__c`, `Invoice_Category__c`, `Invoice_Submission_Type__c`, `Delivery_Type__c`, `Reconciliation_Type__c`, `Market_Type__c`, `Type__c` (verified — all `data_type='string'`, not picklist). This is a Salesforce anti-pattern: free-text type fields with no governed value set, no page-layout binding, no picklist-dependent validation. The cashline-platform side should *not* copy this — use a single `Invoice.kind` enum (or `RecordType` equivalent if multi-tenant per-Operator) plus a small set of structured sub-types.

### 5. `Task.WhoId` / `WhatId` polymorphism is standard SF — and Sailfin is using it

Verified: `Task` has both `WhoId` (polymorphic to Contact/Lead) and `WhatId` (polymorphic to ~50 entities including Account, Dispute, Transaction). The team is correctly consolidating into `OperationalTask` + `CommunicationEvent` (per Gap 5 in the comparison doc), but the comparison doc doesn't mention that **the polymorphism it's reproducing with `CommunicationEvent`'s 6 optional FKs** (`cashline-platform-ontology-comparison.md:290`, "shotgun foreign keys") is solving the same problem standard SF solves with `WhatId`. Two paths forward: (a) keep the 6-FK shape and add a single-FK guard, (b) collapse to a polymorphic association (`subject_type` + `subject_id`). Either works; the team should know they're picking sides on a problem with a 25-year-old SF idiom.

### 6. `ApprovalSubmission` / `ApprovalWorkItem` are present and load-bearing

All three approval objects (`ApprovalSubmission`, `ApprovalSubmissionDetail`, `ApprovalWorkItem`) are extracted (verified). The EDA notes them as polymorphic mega-refs and *excludes* them from the relationship analysis (`sailfin-eda-2026-05-27.md:159-162`). That's fine for graph statistics but wrong for ontology mapping: Sailfin's invoice-approval lifecycle (`sfsrm__Transaction__c.sfsrm__Status__c` values "1. APPROVED FOR REVIEW" / "2. APPROVED FOR SIGNATURE (ACCRUED)" / "3. APPROVED FOR BILLING (ACCRUED)") is being driven by the standard SF approval engine. The comparison doc's Gap 7 (`Invoice.status` expansion, `cashline-platform-ontology-comparison.md:223-230`) needs to confront this: those status values aren't free-form picklist choices — they're approval-state-machine outputs. Migrating them without modeling the approval submitter, approver, and rejection paths drops half the audit trail Cashline's brand-side CFO users need.

### 7. `FeedItem` / Chatter is on for 13 objects — and the team is treating it as cuttable

The EDA notes 13 `feedEnabled` objects (`sailfin-eda-2026-05-27.md:122`) including Account, Case, Contact, Lead, Opportunity, User, ContentDocument, and notably `DSO_Report__c` (verified). The cluster map cuts Chatter implicitly by cutting most of these objects. If users have been @-mentioning each other in Chatter posts on Cases or Accounts, those `FeedItem` records contain real collections context — they would normally be ingested via the `FeedItem` API, not the parent record. Don't assume "Chatter feed" means "ignore"; ask the team whether any collection-relevant discussion lives there. If yes, ingest into `CommunicationEvent` as a separate channel type.

### 8. `ContentDocument` / `ContentVersion` / `ContentBody` / `ContentAsset` — the multi-table file model exists for a reason

The cluster map (`sailfin-cluster-map.md:325-328`) calls the standard SF file model "over-engineered for Cashline's needs; one Attachment table with a blob reference is probably enough." That's right for the data shape. But two things the team should know: (a) `ContentVersion` is *why* SF supports document versioning — collapsing to a single Attachment table loses every prior version of a remittance PDF; (b) `ContentDocument.SharingPrivacy` and `ContentDocumentLink` model who-can-see-this — if Cashline ever lets brand-side CFOs see "their" attachments and not their competitors', the standard SF model already solved this. Cashline-platform's plan of one polymorphic `Attachment` with Active Storage is fine; just note that versioning + per-link sharing needs explicit replacements, not omission.

---

## SRM Cloud (sfsrm__) — what those objects actually mean

The cluster map names most `sfsrm__*` objects from their labels alone. The labels mislead. Here are the canonical SRM Cloud meanings (sourced from the SRM Cloud data model, cross-checked against fields in the extraction):

### `sfsrm__Transaction__c` ≠ "Invoice"

Verified canonical meaning from SRM Cloud: **the AR posting record** — a polymorphic header row covering any document or event that affects a customer's AR balance. Specifically: invoices, credit memos, debit memos, on-account cash, write-offs, deductions, refunds, adjustments. Evidence in the extraction:

- `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c` lists 14 transaction types (verified): `Applied`, `Applied Credit`, `Apply Cash`, `Auto Applied`, `Credit Memo`, `Deduction`, `Discount`, `Offset`, `On Account`, `Payment Refund`, `Reversal`, `Write Back`, `Write Off`, `Account to Account Transfer`. These are the rows being *applied against* — i.e., they are `sfsrm__Transaction__c` rows.
- `sfsrm__Transaction__c` has `Transaction_Type__c`, `Document_Type_Description__c`, `Invoice_Category__c`, `Credit_Memo_Reference__c`, `Original_Amount__c`, `Original_DPD__c` (verified) — these are the discriminator and provenance fields you'd expect on a polymorphic AR header.
- The 145 formula fields on `sfsrm__Transaction__c` (`sailfin-eda-2026-05-27.md:144`) are doing the work of computing balance and aging *across all transaction types*, not just invoices.

**Implication for cashline-platform.** The comparison doc's mapping `sfsrm__Transaction__c` → `Invoice` (`cashline-platform-ontology-comparison.md:45`, `sailfin-cluster-map.md:139`) is wrong as a 1:1. Two correct options:

- **Option A (recommended): model an `ARPosting` parent** with subtypes `Invoice`, `CreditMemo`, `Adjustment`, `OnAccountCash`, `WriteOff`. Invoice becomes one row type. This matches the SRM Cloud shape and survives migration.
- **Option B**: keep `Invoice` as the only entity and route non-invoice transaction types to a separate `ARAdjustment` table. Loses the rollup query simplicity but matches the team's stated mental model.

Either way, **Gap 1 in the comparison doc** (`cashline-platform-ontology-comparison.md:148-166` — "No payment / cash side at all") is mis-scoped. The cash side is partly *inside* `sfsrm__Transaction__c` (the "Apply Cash" and "On Account" rows) — not just in `sfsrm__Payment__c`. The migration plan needs to handle that.

### `sfsrm__Payment_Line__c` ≠ "Payment-to-invoice allocation"

Verified canonical meaning: **a journal line on the cash sub-ledger.** It is the *application* of a piece of cash to a piece of AR, with a transaction-type discriminator. Evidence:

- `sfsrm__Transaction_Type__c` carries the same 14 values listed above — i.e., a Payment_Line can be an "Applied" (cash → invoice), "Write Off", "Deduction", "Discount", "Offset", "Refund", or "Reversal".
- `sfsrm__Reason_Code__c` has **64 values** spanning AR adjustments, sales-tax writeoffs by state (`KY SALES TAX WRITE-OFF`, `NM SALES TAX WRITE-OFF`, etc.), bank fees, chargebacks, escheatment, dispute identification, AML-flagged payments (verified — see picklist below). This is not the vocabulary of "I applied $100 of this check to invoice X." It's the vocabulary of a cash-application sub-ledger.
- The 71 fields include `Deduction_Code__c`, `Deduction_Type__c`, `sfcapp__Reason_Code_Description__c`, `sfcapp__Deduction_Reason_Code__c` (48 values).

**Implication.** The 261K Payment_Line rows the comparison doc cites (`cashline-platform-ontology-comparison.md:50`) are not just "13 invoice allocations per payment." They include every adjustment, writeoff, refund, deduction, escheatment, and AML flag against AR. The cashline-platform `PaymentLine` model (Gap 1's planned shape) needs a `kind`/`transaction_type` enum that matches SRM Cloud's, not just an `(invoice_id, amount_cents)` shape.

### `sfsrm__Treatment__c` ≠ "Dunning workflow"

Verified canonical meaning: SRM Cloud's **collections-strategy assignment record** — links an Account (Customer) to a treatment plan (a defined sequence of dunning actions). The `sfsrm__Treatment_Group__c` picklist values `A B C ... Z AA BB ... II` (37 single-letter or double-letter codes, verified) are *risk buckets* — Sigma's standard nomenclature for collector strategy tiers (A = lowest-risk / standard cadence, Z = pre-charge-off / legal). Don't try to translate the letters; they are the *strategy IDs*, not the strategy names. Map to a `CollectionStrategy.tier` enum and store the source letter in `metadata`.

### `sfsrm__Dispute__c.sfsrm__Sub_Type__c` is the routing-decision picklist for Gap 5

70 values (verified). Inspecting them reveals: these are not "subtypes of dispute" — they are **action-needed codes**, mixing genuine disputes ("Wrong Quantity", "Damaged Product", "PO Issues", "Pricing Issues", "Documentation Issues") with operational follow-ups ("Need Updated COI", "Need New Contact Info", "Cash App", "Credit to be Applied", "Internal Invoice", "Demand Letter", "Small Claims", "Legal") and pure dispositions ("Closed Job - Waiver Signed", "Write Off", "Disputed", "Escalated"). This is the source of the comparison doc's Gap 5 ambiguity (`cashline-platform-ontology-comparison.md:204-212`): the 70 values resolve to roughly:

- **~25 are true "blocks payment"** disputes → `InvoiceDispute`
- **~30 are operational follow-ups** → `OperationalTask`
- **~10 are payment-application states** ("Cash App", "Misapplied", "Unapplied Payment", "Credit to be Applied", "Payment Receipt Verified") → should be derived from `Payment_Line.transaction_type`, not stored
- **~5 are pure dispositions** ("Write Off", "Small Balance Write Off", "Escalated", "Legal") → `Invoice.status` or `InvoiceDispute.resolution`

The comparison doc's Gap 11 decision queue (`cashline-platform-ontology-comparison.md:280-281`) calls this out as a translation task. It is — and the rough split above is the starting point.

### Cluster 6 config tables — most are cut, but `sfsrm__Risk_Configuration__c`, `sfsrm__Credit_Configuration__c`, and `sfsrm__Trigger_Configuration__c` need a second look

The cluster map cuts all 16 (`sailfin-cluster-map.md:351-355`). Right for the schema. But these are **Custom Metadata Types or list-based config rows** — they encode the *rules* Sailfin uses (risk-scoring thresholds, credit-limit policies, automation triggers). When the migration plan asks "what does Sailfin currently do?", these tables are the source. Cut from the ontology, yes; export the rows to `docs/method/` first so they aren't lost.

---

## Picklists worth preserving as canonical vocabularies

The comparison doc (`cashline-platform-ontology-comparison.md:259-285`) calls picklist translation an unsized workstream and identifies four high-signal `sfsrm__*` picklists. With the values now inspected, here is the canonical-vs-translate verdict per field:

| Field | Values | Verdict | Why |
|---|---:|---|---|
| `sfsrm__Dispute__c.sfsrm__Sub_Type__c` | 70 | **Translate per-value** (split: ~25 → `InvoiceDispute`, ~30 → `OperationalTask`, ~10 → derive, ~5 → resolution) | Mixed semantics — cannot carry verbatim |
| `sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` | 64 | **Preserve verbatim as `metadata.source_reason_code`**, derive a small platform enum (`writeoff`, `chargeback`, `tax_adjustment`, `bank_fee`, `escheatment`, `deduction`, `applied`, `refund`) | 40+ values are state-level sales-tax writeoffs that need to survive for audit/reporting |
| `sfsrm__Payment_Line__c.sfcapp__Deduction_Reason_Code__c` | 48 | **Preserve verbatim** | Likely tenant-specific deduction codes; Cashline's collectors filter on these directly |
| `sfsrm__Treatment__c.sfsrm__Treatment_Group__c` | 37 | **Preserve as `strategy_tier` enum (A–Z, AA–II)** | These are SRM Cloud canonical strategy IDs; renaming breaks vendor knowledge |
| `sfsrm__Transaction__c.sfsrm__Sub_Reason_Code__c` | 36 | **Preserve verbatim** (the `"11 - Message left"` / `"41 - Promise of payment"` / `"81 - Legal Proceedings - Passed to site"` numeric codes) | These are an SRM Cloud numeric-coded contact-outcome vocabulary; collectors recognize the codes |
| `sfsrm__Dispute__c.sfsrm__Type__c` | 28 | **Translate to platform `InvoiceDispute.subtype`** enum | The 8-subtype enum already in `cashline-platform` (`cashline-platform-ontology-comparison.md:48`) is fine; map per-value |
| `sfsrm__Transaction__c.sfsrm__Status__c` | 12 | **Carry the approval lifecycle states** ("0. UNAPPROVED" / "1. APPROVED FOR REVIEW" / etc.) as a separate `approval_status` field; the cashline-platform `Invoice.status` enum is for *payment* lifecycle, not approval | Conflating these two state machines is the trap behind Gap 7 |
| `CurrencyIsoCode` (19 values on every `sfsrm__*` config table) | 19 | **Carry verbatim as ISO 4217** | Standard, no work |

Two cross-cutting picklists the comparison doc misses:

- **`sfsrm__Transaction__c.Viking_Task__c` (36 picklist values)** — the only `Viking_*` field that is *actually a picklist* with controlled values, not a free-text leaked column. If we are migrating Viking's data, these 36 values are *Viking's* dispute/action vocabulary and need their own translation table. The other ~30 `Viking_*` fields are strings (verified) and migrate as `metadata`.
- **`sfsrm__Transaction__c.Corrpro_Resolver__c` (27 picklist values)** — same pattern, different tenant (Corrpro). Confirms the tenant-leakage problem isn't 31 fields for Viking, it's a multi-tenant pattern with multiple clients leaking their picklists into the master table.

---

## Recommendations for the forward-looking ontology

Three strategic recommendations. The cluster map and comparison doc currently assume cashline-platform will *replace* Sailfin's data shape. The Salesforce-architect view says: it's more nuanced.

### 1. Treat `sfsrm__` as a vendor system, not a Cashline schema

SRM Cloud is a third-party AppExchange product. Sigma owns its schema and changes it on its release cadence. The team's current approach (cluster map keep/cut, comparison doc gap analysis) treats `sfsrm__Transaction__c` and friends as if Cashline could redesign them. They can't — at least not in Sailfin's Salesforce org.

**Recommended posture: read-through with selective sync-back.** Cashline-platform is the new system of record for Clients, Customers, Accounts, and (forward-going) Invoices and Payments. For the brand-by-brand migration the comparison doc describes (`cashline-platform-ontology-comparison.md:246-248`, Gap 9), the SyncRun + ExternalRecordMapping shape is right. But:

- **Don't sync writes back into `sfsrm__Transaction__c`**. Sigma's package has triggers, validation rules, and workflow that we don't control. Write-back risks unpredictable side effects (the 145 formula fields are recomputed on every write). Read-only from `sfsrm__` until a brand is fully migrated, then archive the Sailfin records for that brand.
- **Do export the SRM Cloud picklist value sets verbatim** (the four high-signal picklists above, ~200 values total) into `docs/method/translation-tables/` before any data migration. Once Sigma ships a release that adds/removes values, the source of truth disappears.
- **Do model `ARPosting` (the polymorphic parent of Invoice/CreditMemo/Adjustment/OnAccountCash/WriteOff)**, not just `Invoice`. The `sfsrm__Transaction__c → Invoice` 1:1 mapping in the comparison doc will leak ~30-40% of AR-affecting rows.

### 2. Reuse standard SF idioms when re-modeling, even though we're not building on Salesforce

The cashline-platform Rails 8 implementation is a green-field replacement. Standard SF idioms that 25 years of collections users will recognize:

- **Activity timeline as a single polymorphic stream** (`WhatId`-style). `CommunicationEvent`'s 6 optional FKs (`cashline-platform-ontology-comparison.md:290`, Risk 2) are reinventing this badly. Either collapse to a polymorphic association (Rails has this natively) or add a "at least one set" validator. Recommend the polymorphic shape.
- **Approval-as-state-machine as a separate concern from payment lifecycle.** Sailfin's `sfsrm__Status__c` mixes both ("APPROVED FOR REVIEW" is approval-state; "Promised" / "Unpaid" / "Disputed" is collections-state). The comparison doc's Gap 7 (expand `Invoice.status` to 15 states) tries to encode both on one column — that's the antipattern SF avoids with separate `Status` and `ApprovalStatus`. Split them.
- **Record-typed sub-entities over string-typed kind fields.** Wherever the team is tempted to write `Customer.kind = 'prospect'/'customer'/'inactive'`, that is the standard SF `RecordType` pattern. Cashline-platform doesn't need SF's full record-type machinery (page layouts, picklist subsets) — but having a single canonical enum with downstream filtering is the same idea. Don't replicate Sailfin's free-text type fields.

### 3. The translation layer is the ontology

This is the one strategic move I'd push hardest. The cluster map and comparison doc both frame the work as "what's the cashline-platform schema?" The Salesforce-architect view says: the schema is the easy part. **The translation table from SRM Cloud's vocabularies to cashline-platform's enums is the actual deliverable.** Concretely:

- **~200 picklist values** in the four high-signal `sfsrm__*` fields, each needing a translation rule (or "drop") — see the table above.
- **14 transaction types** in `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c` mapped to an `ARPosting.kind` enum.
- **70 dispute sub-types** in `sfsrm__Dispute__c.sfsrm__Sub_Type__c` routed across InvoiceDispute / OperationalTask / derived / resolution.
- **The 12 `sfsrm__Transaction__c.sfsrm__Status__c` values** split into the approval-state machine vs. the collections-state machine (the team should not merge these; SF doesn't).
- **The 37 `sfsrm__Treatment_Group__c` letter codes** preserved as `CollectionStrategy.tier` with the SRM Cloud meanings documented.

The existing extraction tool already hashes picklist value sets per run and surfaces drift (`sailfin-cluster-map.md:420-421`, `cashline-platform-ontology-comparison.md:275`). That infrastructure is the right home for the translation tables — store them as data, version them with the extraction, and let the diff page surface "Sigma added 4 new dispute sub-types this release; here are the 4 untranslated values blocking ingest." Without this layer, every brand migration is an ad-hoc rediscovery of what `"63 - Duplicate Payment"` means.

---

**Bottom line.** The team's two-doc story (cluster map + comparison) is structurally sound. The pieces it's missing are: (a) `sfsrm__Transaction__c` is not Invoice — it's the polymorphic AR posting record, and the mapping is currently wrong, (b) the standard-SF affordances Sailfin is *not* using (record types, field history, AccountContactRelation, ContactPointAddress) are choices the team should make consciously, not by omission, and (c) the actual deliverable for migration is the translation tables, not the new schema. None of these are reasons to slow down. All three are reasons to add a translation-table artifact to the next sprint and revisit the `sfsrm__Transaction__c → Invoice` line in the comparison doc before the first brand migration.
