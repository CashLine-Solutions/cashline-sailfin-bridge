# Sailfin / Salesforce ontology — cluster map

A plain-language guide to the 123 objects in the Sailfin Salesforce org, organised into eight clusters. The point of this document is not to be exhaustive — it's to give the team (Andreas, Bryce, and everyone else weighing in on the new ontology) a single place to see what the existing data shape is, what's load-bearing, and what is almost certainly noise we don't need to carry into the new Cashline ontology.

Read top to bottom on first pass. The big-picture summary, the open questions, and the keep/cut table at the end are the parts you should re-read together when you're making mapping decisions.

**Source data:** extraction run `2026-05-24T23-27-12Z-be06`, 123 sobjects, 4,800-ish fields total. Field counts and relationship metrics come from that run; explore live at `/runs`.

---

## The 30-second summary

The Salesforce org has three layers piled on top of each other:

1. A **collections engine** sold as a managed package — `sfsrm__*` for the core AR/dunning logic, `sfcapp__*` for the cash-application piece. About a third of the objects.
2. **Cashline's own custom objects** dropped into the standard namespace — `Brand__c`, `Reporting_Client__c`, `Account_Brand_Association__c`, `DSO_Report__c`, `Open_Invoices__c`, etc. About a tenth of the objects.
3. **The rest of stock Salesforce** — CRM (Account, Contact, Lead, Opportunity, Case), platform plumbing (User, Profile, Network, Site), content management, marketing, partner programs, work badges, profile skills. More than half of the objects.

Cashline's domain (Clients, Customers, Accounts as link records, invoicing, payments, collections) lives almost entirely in layers 1 and 2. Layer 3 is largely either supporting infrastructure (User/Profile for identity), unused CRM remnants (Opportunity, Campaign, partner programs), or generic Salesforce features that don't reflect Cashline's business.

The clusters that matter most for the new ontology are **Parties** (clients, customers, links), **Receivables** (invoices, payments, disputes), and **Communication & activity** (emails and tasks — Cashline plans to integrate these in the near term, and the Sailfin org already uses them heavily). The rest is either supporting infrastructure or candidates for cutting.

**One cross-cutting design problem worth flagging early.** The existing model has *per-client custom fields baked into shared master tables*. The Invoice table (`sfsrm__Transaction__c`) carries 31 `Viking_*` fields plus separate columns for Alpine and Casey Sprayberry. The Dispute table has similar leakage. The new ontology resolves this in two coordinated ways:

1. **Normalize the Customer side.** One canonical Customer record (e.g. *Viking*) is linked to every Client that does business with it via `Account` (the link record). This gives Cashline a corporate-knowledge view of a Customer across clients, while each Client still sees their own Account view of that Customer.
2. **Provide a per-Client extension seam.** The team has confirmed that some genuinely per-client custom fields on customers will still be needed. Those will live on a side-table keyed by Client + Account (not added to the master Invoice or Customer), preserving normalization at the core and pushing tenant-specificity to the edge.

See [Cluster 2](#cluster-2--receivables-invoices-line-items-disputes-credit) for the field-level evidence of why this matters.

### Quick navigation

| # | Cluster | Substantive? | Object count |
|---|---|---|---|
| 1 | [Parties (Clients, Customers, links)](#cluster-1--parties-clients-customers-and-how-theyre-linked) | Yes | 8 |
| 2 | [Receivables (invoices, line items, disputes, credit)](#cluster-2--receivables-invoices-line-items-disputes-credit) | Yes | 13 |
| 3 | [Collections operations (treatments, forecasting, productivity)](#cluster-3--collections-operations-treatments-forecasting-productivity) | Partial | 7 |
| 4 | [Banking & cash application](#cluster-4--banking--cash-application) | Partial | 5 |
| 5 | [Communication & activity](#cluster-5--communication--activity-emails-tasks-content) | Yes (forward-going) | 17 |
| 6 | [SFSRM configuration tables](#cluster-6--sfsrm-configuration-tables) | Cut | 16 |
| 7 | [Salesforce platform scaffolding](#cluster-7--salesforce-platform-scaffolding) | Cut | 19 |
| 8 | [CRM / sales / service remnants](#cluster-8--crm--sales--service-remnants-the-unused-half-of-salesforce) | Cut | 38 |
| — | [Cross-cutting: picklists (controlled vocabularies)](#cross-cutting-picklists-controlled-vocabularies) | Translation surface | 342 fields |

---

## Cluster 1 — Parties (Clients, Customers, and how they're linked)

**Plain-language summary.** Who is in the system, and who is who. Cashline's clients, their customers, the people who work at either side, and the records that link a client to a particular customer of theirs.

This is the cluster where the keep/cut decisions land closest to the new ontology. **Three of the existing objects already line up cleanly with the new model:** `Brand__c` is the Client, `Account` is the Customer, and `Account_Brand_Association__c` is the link record (what the new ontology calls "Account"). All three need renaming and trimming, but the shape is right. The fourth interesting object in this cluster, `Reporting_Client__c`, was initially confused for a parent-Client concept — investigation shows it's actually Cashline's internal collector-staffing bucket and likely doesn't belong in the ontology at all (see its section below).

**New requirement to design for: divisions/departments inside a Client.** The team has confirmed that a single Client may operate with Cashline through multiple internal divisions or departments that act largely independently of each other. The new ontology needs to model this — probably as a child-of-Client structure (e.g., `ClientDivision`) rather than reusing `Brand__c`-style records. This is distinct from `Reporting_Client__c` (which is on Cashline's staffing side, not the Client's org-structure side).

There are also three different objects in this cluster with the word "Brand" in them, all carrying different meanings: the custom `Brand__c` (Client), the custom `Account_Brand_Association__c` (Client↔Customer link), and the stock Salesforce `AccountBrand` (branded customer-service feature, unused). Any ontology design around "Brand" should disambiguate explicitly.

### `Brand__c` — this is your Client (52 fields)

The field list makes this unambiguous. `Brand__c` carries the things you'd only carry about *the company Cashline is serving*:

- **How they get paid:** `ABA__c`, `Bank_Account_No__c`, `Bank_Name__c`, `Bank_Address__c`, `Routing_No__c`, `Lockbox_Details__c`.
- **Who they are:** full street/city/state/postal/country, `Brand_Email__c`, `Brand_Phone__c`, `Brand_Manager__c`, `IT_Contact__c`, `DUNS_Number__c`, `Industry__c`, `Revenue__c`, `ERP_System__c`.
- **How Cashline operates for them:** `Accounts_Receivable__c`, `DSO_Net__c`, `Target_Collectors__c`, `Target_Weekly_Hours__c`, `File_Upload_Cadence__c`, `Open_Invoice_API_Last_Action_Days__c`, `First_Invoice_Created_Date__c`.

A Customer would never have a banking lockbox or a target collector headcount. A Client would. This is your Client.

**Verdict:** Keep, rename to `Client`. The 52 fields will likely trim to ~30 once you drop Salesforce ownership scaffolding and obsolete operational metrics (file-upload cadence, ERP system, etc., depending on which still apply).

### `Account` — this is your Customer (352 fields)

The standard Salesforce `Account` object, used here as the *paying side*. It points at `Brand__c` (the client this customer belongs to in legacy single-client usage), at `sfsrm__Transaction__c` (the invoice/receivable), and at `sfsrm__Treatment__c` (the dunning workflow). It's pointed at by `sfsrm__Payment__c` (incoming money), and is by far the most-referenced object in the domain (45 incoming references — second only to `User`, which is referenced everywhere as the owner of every record).

The 352-field count is misleading: most of those are stock Salesforce fields (sales, marketing, support, partner programs, work orders) that aren't used in a collections workflow. Cashline-relevant fields are probably a few dozen.

One semantic caveat worth flagging: the existing graph has `Account` linked to *exactly one* `Brand__c` via `Account_Brand_Association__c`. The new ontology says a Customer can be linked to multiple Clients. If any business logic in the SFSRM package assumes `Account.Brand__c` is single-valued, that assumption will not survive.

**Verdict:** Keep, rename to `Customer`. Trim aggressively — the unused-fields report is the right tool for this. Expect ~30-50 fields to survive.

### `Account_Brand_Association__c` — this is already your Account (link), 16 fields

This is the closest thing in Sailfin to your new `Account` linking object. It has:

- `Account__c` reference (→ the Customer)
- `Brand__c` reference (→ the Client)
- `Account_ID__c`, `Brand_ID__c` (external IDs)
- `Account_Total_AR__c`, `Total_AR_Static__c` (rolled-up amount owed on this specific Client-Customer pair)

It implements exactly the relationship the new ontology describes: one Customer can be linked to many Clients, with a per-link receivables balance.

**Verdict:** Keep, rename to `Account`. Schema is already close. Discuss with the team whether per-link AR rollups belong on the link or computed off invoices.

### `Reporting_Client__c` — collector staffing bucket (17 fields, only 4 substantive)

Looking at the field list resolves what this object actually is. The non-stock fields are:

- `Name` (the reporting client name)
- `Hours_Worked__c` (collector hours logged against this reporting client)
- `Latest_File_Date__c` (last data file received from / processed for this reporting client)
- `Target_Collectors__c` (target headcount of Cashline collectors assigned)
- `Target_Weekly_Hours__c` (target weekly collector hours)

It's referenced by `Brand__c.Reporting_Client__c` and `sfsrm__Transaction__c.Reporting_Client__c`.

There is no identity, contact, banking, or org-structure information on this record. Every field is about *how Cashline staffs work for this reporting unit*. The label `Reporting_Client__c` is misleading — this isn't a Client object at all. It's a **collector-staffing-allocation bucket** that groups one or more Brands under a single staffing assignment.

In practice it's most likely a grouping that lets multiple Brands share collector targets and hours (e.g., a single Cashline collector team works across a set of related Brands, and `Reporting_Client__c` is the bookkeeping record that aggregates that staffing). The operations side of the team will know the exact rules.

**Verdict:** This is Cashline's internal staffing/workforce data, not a domain entity. **Cut from the ontology**; the workforce-management concern lives in operational infrastructure, not in the data model that describes Clients/Customers/Invoices. If staffing rollups are useful, regenerate them off Tasks and User assignments at query time.

**Not to be confused with** the new ontology's "divisions/departments inside a Client" concept — that's a Client-side org-structure feature (child-of-Brand), whereas `Reporting_Client__c` is on Cashline's staffing side (parent-of-Brand for staffing only).

### `AccountBrand` (standard Salesforce) — distinct from `Brand__c` (28 fields)

Salesforce ships a stock `AccountBrand` object for branded service interactions (different from the custom `Brand__c`). It carries address/contact/logo for a brand attached to an `Account`. It is currently a top-level orphan in the run — referenced by nothing custom (in=0).

**Verdict:** Cut. It's standard-Salesforce machinery for a feature Cashline isn't using, and the org already has `Brand__c` doing the actual Client job.

### Supporting party objects

- **`Contact` (76 fields)** — a person at an Account (Customer). Standard Salesforce. **Keep, scope to people on the Customer side, trim.**
- **`Individual` (34 fields)** — Salesforce's GDPR/consent record, attached to Contacts and Leads and User records. **Carry only if you need a consent layer; otherwise cut.**
- **`Business_Entity__c` (10 fields, mostly stock)** — almost no content. **Likely cut after a one-line check with the team.**

### Open questions for this cluster

1. Where do **divisions / departments inside a Client** sit in the new ontology — as a `ClientDivision` child of `Client`, as an attribute on `Account` (the Client↔Customer link), or both? This affects whether a Customer's relationship is with a Client or with a specific division of a Client.
2. Confirm `Reporting_Client__c` is purely Cashline's collector-staffing bookkeeping (the operations side of the team will know best). If yes, cut entirely. If it carries any client-side semantics we haven't spotted, surface them before cutting.
3. Are Contacts modeled as a separate entity in the new ontology, or folded into Customer?
4. Where do banking details belong — on Client, or on a separate `PayoutMethod` entity?
5. Is there any reason to preserve `AccountBrand` (the standard Salesforce one) or is it safely cuttable?

---

## Cluster 2 — Receivables (invoices, line items, disputes, credit)

**Plain-language summary.** The money owed. Every invoice Cashline tracks, every line item on those invoices, every dispute that's been raised against one, and the credit assessments that determine how much credit a Customer can carry. This is the second cluster where keep/cut matters most.

The hub here is `sfsrm__Transaction__c` — Sailfin's name for "Invoice". It's also the largest single object in the org at 438 fields, and the field list reveals a significant data-hygiene issue worth raising before you finalise the new ontology (see warning below).

### `sfsrm__Transaction__c` — this is your Invoice (438 fields)

The field list confirms this is the invoice record:

- **Identity and amount:** `Account_Number__c`, `Brand_Code__c`, `Amount_Outstanding__c`, `Amount_Due_30__c`, `Amount_Due_90__c`, `Amount_Due_Over_90__c`, `AR_30_Days_Past_Due__c`, `Discount_Amount__c`.
- **Lifecycle dates:** 64 fields with "date" in the name — invoice date, due date, paid date, promise dates, dispute dates, approval dates.
- **Aging:** `Days_Outstanding__c`, `Days_Past_Promise_Date__c`, `Days_to_Paid__c`, `Days_to_Pay__c`.
- **Dispute linkage:** `Dispute_Lookup__c`, `Dispute_Status__c`, `Dispute_Number__c`, `Dispute_Notes__c`.

⚠️ **The tenant-leakage problem in the wild.** Among the 438 fields are:
- **31 `Viking_*__c` fields** — tenant-specific (a Cashline client named Viking has had its custom fields baked into the master Invoice table).
- **`Alpine_Combined_Invoice_Number__c`**, **`Casey_Sprayberry_Accounts__c`** — same pattern, different tenants.

This is the per-client field-leakage problem the [30-second summary](#the-30-second-summary) calls out. The new ontology addresses it through the normalization-plus-side-table approach: one canonical Customer (e.g. Viking) linked to multiple Clients via `Account`, with any genuinely Client-specific extensions living on a side-table keyed by `Account`, not added to the master Invoice. Migrating the existing data will require splitting these leaked columns out by Client and re-attaching them at the side-table level.

**Verdict:** Keep the *concept* as `Invoice`. Do not migrate the field shape — there are probably 50–80 fields here worth carrying into the new model, the tenant-leakage fields move to the per-Client extension side-table, and the computed/aging fields should be derived rather than stored.

### `sfsrm__Line_Item__c` — line items on an invoice (27 fields)

Classic invoice-line shape:
- Identifier: `sfsrm__Item_Number__c`, `sfsrm__Line_Key__c`
- Pricing: `sfsrm__Quantity__c`, `sfsrm__Unit_Price__c`, `sfsrm__List_Price__c`, `sfsrm__Discount__c`, `sfsrm__Line_Total__c`
- Context: `sfsrm__Description__c`, `sfsrm__Service_Date__c`, `sfsrm__Account__c`, `sfsrm__Transaction__c`
- Dispute-aware: `sfsrm__Disputed_Amount__c`, `sfsrm__Flags__c`

**Verdict:** Keep as `InvoiceLine`. Schema is clean and standard.

### `sfsrm__Payment_Line__c` — payment-to-invoice allocations (71 fields)

The mirror of line items, on the cash-receipt side. Links a payment to one or more invoices.

**Verdict:** Keep as `PaymentAllocation` (or similar — defer to the team's preferred term). Schema is healthy.

### `sfsrm__Dispute__c` — disputes (76 fields)

Rich dispute lifecycle:
- Identity/linkage: `sfsrm__Account__c`, `sfsrm__Transaction__c`, `sfsrm__Status__c`
- Classification: `sfsrm__Reason_Code__c`, `sfsrm__Resolution_Code__c`, `sfsrm__Type__c`, `sfsrm__Sub_Type__c`
- Lifecycle timing: `sfsrm__Days_To_Identify__c`, `sfsrm__Days_To_Resolve__c`, `sfsrm__Close_Date__c`, `sfsrm__Dispute_Close_DateTime__c`, `sfsrm__Total_Dispute_TAT__c`
- Risk scoring: `sfsrm__Dispute_Risk__c`, `sfsrm__Risk_Due_To_Amount__c`, `sfsrm__Risk_Due_To_Dispute_DPD__c`, `sfsrm__Risk_Due_To_Not_Contact__c`
- Notes & escalation: extensive note/email/escalation tracking fields

⚠️ Same tenant-leakage problem: 11 `Viking_*__c` fields on this table. They migrate to the per-Client extension side-table per the normalization decision in the [30-second summary](#the-30-second-summary).

**Verdict:** Keep as `Dispute`. Schema is solid.

### `sfsrm__Credit_Application__c` — credit application onboarding (31 fields)

Onboarding-form data captured when a Customer applies for credit: legal name, EIN, parent company, business type, tax exempt status, estimated monthly purchases, contact details.

**Verdict:** Keep as `CreditApplication`. This is pre-Customer onboarding state and is meaningfully separate from the Customer record itself.

### `sfsrm__Credit_Review__c` — credit assessment outcomes (29 fields)

The result of a credit application — D&B/DUNS lookups, Paydex scores, country scores, recommended vs approved credit limits.

**Verdict:** Keep as `CreditReview`. Pair with `CreditApplication`.

### `sfsrm__Trade_Reference__c` (15 fields)

Trade references provided as part of credit applications. Schema not yet inspected; surface shape is small enough that it likely just keeps as-is.

**Verdict:** Likely keep as `TradeReference`. Confirm.

### `sfsrm__Score_Card_Parameter__c` (18 fields) and `sfsrm__Score_Card_Parameter_Value__c` (17 fields)

A credit scorecard configuration table and its values. Configuration for the credit-decisioning model.

**Verdict:** Investigate. If Cashline uses a different scorecard model in the new system, cut. If reusing this one, keep both.

### Reporting tables in this cluster (likely all derivable, candidates for cut)

These look like *materialized reporting tables* rather than master data:

- **`Open_Invoices__c` (16 fields)** — looks like a per-invoice approval-tracking sidecar. Investigate whether this is reporting or operational state.
- **`DSO_Report__c` (37 fields)** — Days Sales Outstanding rollup by Brand, by month/week. Pure reporting.
- **`Weekly_AR_Snapshot__c` (27 fields)** — weekly AR snapshot per invoice.
- **`sfsrm__Collection_Detail__c` (11 fields)** — collection detail rollup.

**Verdict:** Likely all cut in the new ontology — these should be views or queries over the master tables, not separate persisted tables. Confirm before cutting since they may be the only place that historical snapshots are stored.

### Open questions for this cluster

1. Are the reporting tables (`DSO_Report__c`, `Weekly_AR_Snapshot__c`, `Open_Invoices__c`) historical archives that need to be preserved, or can they be regenerated from the master tables?
2. Is `Cashline's credit-decisioning model` the same as `sfsrm__Score_Card_*` or different?
3. **Extensibility side-table:** what is the canonical shape — keyed by `Account` (Client↔Customer link), by `Client` alone, by `Customer` alone, or some combination? This determines where Viking-style extensions land.

---

## Cluster 3 — Collections operations (treatments, forecasting, productivity)

**Plain-language summary.** How money actually gets collected. This cluster covers the dunning workflow (what action to take on which invoice, by which collector, on which date), forecasting (when will the money come in), and collector productivity tracking. It's "the operational layer that runs on top of the receivables data."

The hubs are smaller and more numerous here than in Receivables — no single dominant object, instead a set of medium-sized tables that together implement the collections process.

### Hubs and their roles

| Object | Fields | Role |
|---|---|---|
| `sfsrm__Treatment__c` | 34 | The dunning treatment / collections action plan. Linked to `Account`, with `Event` and `Task` activities scheduled against it. |
| `sfsrm__Collection_Forecast__c` | 65 | Cash forecasting — when collections expect money to arrive. Self-referential (forecasts can have parents). |
| `sfsrm__Collector_Productivity__c` | 40 | Per-collector productivity metrics. |
| `sfsrm__Collector_Target__c` | 21 | Per-collector collection targets. |
| `sfsrm__Cash_Monitoring__c` | 19 | Cash-arrival monitoring. |
| `sfsrm__Case_Manager__c` | 19 | Case manager assignments (the human collector assigned to a Customer/Brand combination). |
| `sfsrm__Data_Load_Batch__c` | 32 | ETL batch records — tracks data loads from client ERP systems into Sailfin. |

### Verdict for this cluster

**Keep selectively.** This whole cluster is operational — the *process* of collecting, not the *facts* being collected. The new ontology's job is mostly the facts side. Some of these objects (Treatment, Collector_Target) will likely have analogs in the new model; others (Data_Load_Batch — purely an ETL audit log) probably don't belong in the ontology at all and live in operational infrastructure.

**Recommended approach:** discuss with the team which of these concepts the new ontology models explicitly. For ones that aren't modeled, those are operational state that lives outside the ontology — don't try to carry them forward.

### Open question

Is "collections operations" *in scope* for the new ontology, or is the ontology only modeling the data facts (Client, Customer, Invoice, Payment, Account) and leaving operational state to a separate system?

---

## Cluster 4 — Banking & cash application

**Plain-language summary.** Where the money goes when it arrives. This is the bridge between the bank (the actual cash) and the receivables ledger (what invoices the cash should be applied to). The `sfcapp__*` namespace is Sailfin's "cash application" managed package.

The volume here confirms what the team described about how Customers pay: **multi-invoice payments are the norm.** Sampling shows roughly 20,000 payments allocated across roughly 261,000 payment lines (about 13 invoice allocations per payment on average), grouped into ~3,900 payment batches (so payments are themselves batched, ~5 per batch). The new ontology needs to model Payment as a *header*, with `PaymentLine` (or `PaymentAllocation`) carrying the per-invoice split, and `PaymentBatch` grouping payments that are processed together.

| Object | Fields | Role | Notes |
|---|---|---|---|
| `sfsrm__Payment__c` | 63 | Incoming payment from a Customer (the cash receipt itself). | ~20K records sampled. |
| `sfsrm__Payment_Line__c` | 71 | The per-invoice split inside a payment. | ~261K records sampled — high cardinality confirms multi-invoice payments. Listed in Cluster 2 with the receivables side. |
| `sfcapp__Payment_Batch__c` | 39 | A batch of payments processed together. | ~3.9K records — actively used. |
| `sfcapp__Bank_Statement_Remittance__c` | 67 | Raw remittance data from bank statements — the unprocessed cash items before they're matched to payments. | ~12K records — actively used. |
| `sfcapp__GL_Account__c` | 20 | General-ledger account mapping for payments. | Investigate usage. |
| `sfcapp__Cash_App_Configuration__c` | 18 | Cash-app config. | Cut — pure config. |

### Verdict

- **`Payment`, `PaymentLine`, `PaymentBatch`** — all keep. The team confirms multi-invoice payments are how Customers actually pay, and the data backs this up. These three together are the canonical pattern for representing receipts in the new ontology.
- **`Bank_Statement_Remittance__c`** — keep if the new ontology models the bank-reconciliation layer (i.e., the gap between cash arriving and cash being applied). Discuss with the team whether reconciliation is in scope.
- **`GL_Account__c`** — if the new ontology touches the general ledger at all, it maps here. Otherwise cut.
- **`Cash_App_Configuration__c`** — cut. It's package config.

---

## Cluster 5 — Communication & activity (emails, tasks, content)

**Plain-language summary.** Everything humans say, send, or do. Emails sent to Customers, calls logged, tasks tracked against Accounts, files attached to invoices. The team has confirmed this cluster *is in scope* — Cashline plans to ingest communications and tasks alongside Clients, Customers, Accounts, and Invoices in the near term. The existing Salesforce data shows this layer is already heavily used and already domain-customized.

Sampled volume from this run, sorted by actual usage:

| Object | Fields | Sample volume | Status |
|---|---|---|---|
| `ContentVersion` | 47 | ~324K records | In use — file revisions |
| `EmailMessage` | 86 | ~203K records | In use — sent/received emails |
| `ContentDocument` | 26 | ~138K records | In use — file metadata |
| `Task` | 68 | ~20K Account-linked records | In use — heavily customized for collections (see below) |
| `EmailTemplate` | 29 | ~922 templates | In use — dunning correspondence |
| `sfsrm__Email_Log_Monitor__c` | 17 | ~53 records | Lightly used |
| `ContentAsset` | 13 | ~70 records | Lightly used |
| `ContentFolder` / `ContentWorkspace` | 11 / 19 | <10 records | Lightly used |
| `ListEmail` | 24 | ~6 records | Effectively unused |
| `Event` | 77 | 0 records sampled | Not in use |
| `SocialPost` | 67 | 0 records sampled | Not in use |
| `OutgoingEmail` | 15 | 0 records sampled | Not in use |
| `EnhancedLetterhead` / `Image` / `CallCenter` | 13 / 21 / 11 | 0 records sampled | Not in use |

### `Task` — the central collections activity log (68 fields, heavily customized)

This is the most interesting object in the cluster. The standard Salesforce `Task` has been deeply extended by the SFSRM package plus Cashline custom fields. It carries:

- **Activity routing:** `sfsrm__Contact_Method__c` (email / phone / fax / etc.), `sfsrm__Call_Status__c`, `sfsrm__IsFax__c`.
- **Email payload (overlap with EmailMessage):** `sfsrm__From__c`, `sfsrm__To__c`, `sfsrm__Cc__c`, `sfsrm__Bcc__c`, `sfsrm__Notes__c`.
- **Dunning lifecycle:** `sfsrm__Treatment__c` (FK to the Treatment), `sfsrm__Treatment_Stage__c`, `sfsrm__Dunning_Status__c`, `sfsrm__Days_Since_Open__c`, `sfsrm__Closed_Date__c`.
- **AR snapshot at task time:** `sfsrm__Total_Past_Due__c`, `Total_AR__c`.
- **Cashline-added context:** `CashLine_Employee__c`, `CashLine_Task__c`, `Account_Num__c`, `Brand_Name__c`, `Open_Tasks__c`, `Completed_Tasks__c`.

In effect, Task has been used as a **unified activity record** across emails, calls, and dunning steps — not just a to-do list. There's some overlap with `EmailMessage` (Task carries its own email From/To/Cc/Bcc), which suggests two different paths recorded the same fact. The new ontology should pick one canonical activity model and route emails to it explicitly.

**Verdict:** Keep as the basis for the new `Activity` (or `CollectionsActivity`) entity. Plan to consolidate Task and EmailMessage into a single activity stream rather than carrying both.

### `EmailMessage` and `EmailTemplate` — communications data already at scale

~203K email records and ~922 templates. This is real operational history that the new ontology will want to ingest, not just observe. Likely shape: emails are first-class records linked to Client / Customer / Account / Invoice / Dispute as appropriate, with templates as a separate library entity.

**Verdict:** Keep both. Decide whether to ingest existing historical emails or only forward-going traffic — that's a data-migration question for the team.

### `ContentDocument` / `ContentVersion` — file attachments at scale

~138K file metadata records, ~324K versions. Files are heavily attached to records here, almost certainly to invoices and disputes. The new ontology needs a file/attachment story.

**Verdict:** Keep the *concept* (an Attachment entity linked polymorphically to Invoice, Dispute, Account, etc.). The Salesforce-specific multi-table file model (`ContentDocument` + `ContentVersion` + `ContentBody` + `ContentAsset`) is over-engineered for Cashline's needs; one Attachment table with a blob reference is probably enough.

### `Event`, `SocialPost`, `OutgoingEmail`, `EnhancedLetterhead`, `Image`, `CallCenter`, `ListEmail`

Sampled at zero or near-zero records. None of these are being used in this org.

**Verdict:** Cut.

### Open questions for this cluster

1. **Task vs EmailMessage overlap** — does the new ontology have one canonical Activity entity (with email as a subtype), or do Email and Task stay as separate entities? Same question for calls.
2. **Historical email ingestion** — are the ~203K existing EmailMessage records being migrated, or does the new system start from scratch on forward-going traffic?
3. **File model** — does Cashline need anything richer than a single Attachment entity (e.g., file versioning, libraries, folders)?
4. **Notes on Disputes** — disputes have rich note fields embedded (`sfsrm__Latest_Note__c`, `sfsrm__Notes__c`, `sfsrm__Treatment_Notes__c`). Are these first-class Activity records or stay as embedded text on the Dispute?

---

## Cluster 6 — SFSRM configuration tables

**Plain-language summary.** Configuration tables shipped with the Sailfin managed package. None of these are domain entities — they're knobs that control how Sailfin behaves.

Sixteen objects, all `sfsrm__*`-prefixed, all small (11-30 fields), all with `in=0` (nothing in the data points at them — they're consumed by code, not data).

`sfsrm__WCM_Configuration__c`, `sfsrm__Trigger_Configuration__c`, `sfsrm__Risk_Configuration__c`, `sfsrm__Object_Configuration__c`, `sfsrm__Custom_List_View__c`, `sfsrm__User_Preference__c`, `sfsrm__Archival_Configuration__c`, `sfsrm__Archival_Setup__c`, `sfsrm__Forecast_Configuration__c`, `sfsrm__Golden_Gate_Configuration__c`, `sfsrm__Credit_Configuration__c`, `sfsrm__Screens__c`, `sfsrm__SourceSystemNotifierConfiguration__c`, `sfsrm__Data_Service__c`, `sfsrm__Temp_Object_Holder__c`, `sfsrm__CurrencyCode_Symbols__c`.

### Verdict

**Cut all of these.** They are managed-package internals. If Cashline keeps using the SFSRM package, these come along automatically. If Cashline is migrating off it, none of these survive — they describe how SFSRM is configured, not the underlying domain.

---

## Cluster 7 — Salesforce platform scaffolding

**Plain-language summary.** Standard Salesforce platform machinery — users, roles, permissions, networks, profiles, approvals, reports, dashboards. Required for Salesforce to function, mostly not domain data.

Twenty-ish objects covering:

- **Identity & access:** `User` (183 fields, 278 inbound refs — the most-referenced object in the org because every record has owner/created/modified fields pointing at it), `UserRole`, `UserLicense`, `Profile`, `Group`, `CollaborationGroup`, `Organization`, `Network`, `Site`, `Topic`.
- **Approvals:** `ApprovalSubmission`, `ApprovalSubmissionDetail`, `ApprovalWorkItem`.
- **Metadata:** `RecordType`, `BusinessProcess`, `ExternalDataSource`.
- **Analytics:** `Dashboard`, `DashboardComponent`, `Report`.

### Verdict

**Cut all of these from the domain ontology.** They are platform infrastructure, not Cashline's domain. The one exception is `User` — if the new ontology models "the human collector or account manager assigned to a Client/Customer/Account", you'll need a `User` (or `Person`) entity, but it should be a clean small model, not the 183-field Salesforce User.

---

## Cluster 8 — CRM / sales / service remnants (the unused half of Salesforce)

**Plain-language summary.** All the parts of Salesforce that come along when you buy the platform but aren't actually used by Cashline. Sales pipeline, service cases, work orders, marketing campaigns, partner programs, product catalogs, channel programs, work badges, profile skills, communication subscriptions.

These are mostly objects with low or zero usage in the Sailfin run. They're in the org because Salesforce ships them or because someone enabled a feature once and never used it.

| Subgroup | Objects |
|---|---|
| Sales pipeline | `Opportunity`, `OpportunityHistory`, `Lead` |
| Service | `Case`, `Solution` |
| Work orders | `WorkOrder`, `WorkOrderLineItem`, `Asset`, `AssetRelationship` |
| Sales process | `Contract`, `SalesforceContract`, `SalesforceQuote`, `SalesforceInvoice`, `Order`, `OrderItem`, `Product2`, `Pricebook2` |
| Marketing | `Campaign`, `PartnerMarketingBudget`, `PartnerFundAllocation`, `PartnerFundRequest`, `PartnerFundClaim` |
| Channel programs | `ChannelProgram`, `ChannelProgramLevel`, `ChannelProgramMember`, `EngagementChannelType` |
| Skills/badges | `ProfileSkill`, `ProfileSkillUser`, `ProfileSkillEndorsement`, `WorkBadgeDefinition` |
| Consent/comms | `CommSubscription`, `CommSubscriptionChannelType`, `CommSubscriptionConsent`, `CommSubscriptionTiming`, `PartyConsent`, `AuthorizationFormText`, `DelegatedAccount`, `Location` |

### Verdict

**Cut all of these.** None of them belong in the new ontology. Spot-check one or two with the team just to confirm none have been quietly co-opted for domain use (the most likely candidate would be `Contract` if Cashline has a master-services-agreement concept, or `Location` if customers have shipping addresses tracked separately).

---

## Cross-cutting: picklists (controlled vocabularies)

Picklists are Salesforce's name for dropdown fields — the value must be one of a fixed list of admin-defined options. They cut across every cluster, so they don't belong to any one of them, but they're a real translation workload on the way to the new ontology.

**The numbers:** 366 picklist/multipicklist fields across the 123 objects, holding ~8,000 distinct values. ~3,700 of those values are in 13 platform-supplied mega-picklists (`TimeZoneSidKey`, `LocaleSidKey`, `RelatedEntityType`, `SobjectType`, etc.) that carry over verbatim and don't need ontology decisions. **The substantive surface is ~342 fields and ~4,300 values.**

Concentration is the story. The substantive picklist load lives almost entirely in **Cluster 2 (Receivables)** and **Cluster 3 (Collections operations)**:

| Field | Values | Why it matters |
|---|---:|---|
| `sfsrm__Dispute__c.sfsrm__Sub_Type__c` | 70 | Drives the Dispute-vs-Task routing rule (see [comparison Gap 5](./cashline-platform-ontology-comparison.md)) |
| `sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` | 64 | Short-pay / write-off / dispute reasons |
| `sfsrm__Treatment__c.sfsrm__Treatment_Group__c` | 37 | Dunning workflow groups |
| `sfsrm__Transaction__c.sfsrm__Sub_Reason_Code__c` | 36 | Invoice exception sub-classification |

These four fields alone hold ~200 values that feed lifecycle / classification decisions in the new ontology. The rest of the substantive picklists are smaller (mostly 2–20 values) and live on **Cluster 5 (Communication & activity)** for status/type fields and on standard objects (Lead.Industry, Contract.CurrencyIsoCode) where they're typically carry-over.

**Picklists are *not* in:**
- **Cluster 6 (SFSRM configuration tables)** — single-row admin records, the few picklists they have are settings, not domain vocabularies.
- **Cluster 7 (Salesforce platform scaffolding)** — what's there is the TZ/Locale/SObjectType mega-picklists, all carry-over.
- **Cluster 8 (CRM remnants)** — picklists exist but the objects themselves are being cut.

**Implication for the new ontology.** Mapping ~4,300 source values into platform enums of order ~100 total values is mostly many-to-one collapses or explicit drops. The mapping table — not new schema — is the artifact you need. The Sailfin extraction tool already hashes each picklist's active value set per run and shows additions/removals on the diff page, so once a translation table exists, drift is detectable.

For the full per-field inventory (sortable, exportable to CSV), use **`/reports/picklists`** in the app. For the raw counts and the namespace breakdown, see [`./sailfin-eda-2026-05-27.md`](./sailfin-eda-2026-05-27.md).

---

## The keep / cut summary table

| Cashline concept | Sailfin source | Action |
|---|---|---|
| Client | `Brand__c` | Keep, rename, trim ~40% |
| ClientDivision (new — internal departments inside a Client) | (no direct source) | Design fresh in the new ontology |
| Customer | `Account` | Keep, rename, trim ~85%, normalize to 1 canonical record per real-world customer |
| Account (Client↔Customer link) | `Account_Brand_Association__c` | Keep, rename, becomes the per-Client view of a Customer |
| Per-Client custom extensions | (tenant-leaked columns on `sfsrm__Transaction__c`, `sfsrm__Dispute__c`) | Move to extension side-table keyed by `Account` |
| Cashline collector staffing | `Reporting_Client__c` | Cut from ontology (operational, not domain) |
| Invoice | `sfsrm__Transaction__c` | Keep concept, do not migrate field shape |
| InvoiceLine | `sfsrm__Line_Item__c` | Keep |
| Payment (header) | `sfsrm__Payment__c` | Keep |
| PaymentLine (per-invoice split) | `sfsrm__Payment_Line__c` | Keep — multi-invoice payments are the norm |
| PaymentBatch | `sfcapp__Payment_Batch__c` | Keep |
| Dispute | `sfsrm__Dispute__c` | Keep |
| CreditApplication | `sfsrm__Credit_Application__c` | Keep |
| CreditReview | `sfsrm__Credit_Review__c` | Keep |
| TradeReference | `sfsrm__Trade_Reference__c` | Likely keep |
| Person at Customer | `Contact` | Keep, scope, trim |
| Consent | `Individual` + `PartyConsent` + `CommSubscriptionConsent` | Carry only if GDPR layer is in scope |
| Bank reconciliation | `sfcapp__Bank_Statement_Remittance__c`, `sfcapp__GL_Account__c` | Depends on whether ontology models pre-applied cash |
| Collections operations | `sfsrm__Treatment__c`, `sfsrm__Collector_Target__c`, etc. | Depends on ontology scope |
| Reporting snapshots | `DSO_Report__c`, `Weekly_AR_Snapshot__c`, `Open_Invoices__c` | Likely cut (regenerable from masters) |
| **Activity / dunning history** | `Task`, `EmailMessage`, `EmailTemplate` | **Keep — in scope per team direction; consolidate Task + EmailMessage into one Activity model** |
| Files & attachments | `ContentDocument`, `ContentVersion` | Keep concept as a single `Attachment` entity; drop the multi-table SF file model |
| Unused activity surfaces | `Event`, `SocialPost`, `OutgoingEmail`, `ListEmail`, `EnhancedLetterhead`, `Image`, `CallCenter` | Cut (zero or near-zero usage) |
| SFSRM config tables | 16 `sfsrm__*Configuration*` tables | Cut |
| Salesforce platform | `User`, `Profile`, `Network`, `Site`, `Group`, etc. | Cut (except a minimal `User` if Cashline models assignment) |
| CRM remnants | `Opportunity`, `Lead`, `Campaign`, `Case`, `WorkOrder`, partner programs, channel programs, skills, badges, etc. | Cut |
| Standard SF `AccountBrand` | `AccountBrand` | Cut |

---

## Top open questions for the team

1. **`ClientDivision` design** — how does the new ontology model divisions/departments inside a Client (child-of-Client, attribute on Account, both)?
2. **Extensibility side-table** — what is the canonical key for the per-Client extension table that absorbs Viking-style custom fields (keyed by `Account`, by `Client`, by `Customer`)?
3. **Reporting_Client__c** — confirm with the operations side of the team that this is purely Cashline's collector-staffing bookkeeping and can be cut from the ontology.
4. **Activity model** — does the new ontology have one canonical `Activity` entity (with email/call/dunning-step as subtypes), or do `Task` and `EmailMessage` stay as separate entities?
5. **Historical email ingestion** — migrate the ~203K existing EmailMessage records, or start fresh on forward-going traffic?
6. **Scope of collections operations** — does the ontology model only the data facts (Client, Customer, Account, Invoice, Payment), or does it also model operations (Treatment, Forecast, Collector_Target)?
7. **Reporting snapshots** — are `DSO_Report__c`, `Weekly_AR_Snapshot__c`, `Open_Invoices__c` historical archives we need to preserve, or can they be regenerated from the master tables?
8. **Cash application layer** — does the new ontology stop at "Payment" (already-applied cash), or does it also model the bank-statement-remittance → payment-batch matching layer?
9. **People** — Contacts and Individuals: separate entities in the new ontology, or folded into Customer?
10. **Notes** — are dispute/treatment notes first-class Activity records or embedded text fields?
11. **Credit scorecard** — is Cashline keeping the existing `sfsrm__Score_Card_Parameter__c` model or replacing it?
12. **Picklist translation** — for the four high-signal `sfsrm__*` picklists (Dispute.Sub_Type, Payment_Line.Reason_Code, Treatment_Group, Transaction.Sub_Reason_Code), what's the target platform vocabulary? See [comparison Gap 11](./cashline-platform-ontology-comparison.md).

---

## How to use this document

1. **First pass:** read top to bottom. Calibrate which clusters are interesting.
2. **With the team:** open the keep/cut table and the open-questions list side by side. Work through the questions; the table updates as decisions get made.
3. **For deep dives:** when a specific object needs more inspection than this document covers, use `/objects?run=<id>` with the namespace/sensitivity/custom chips, then the CSV download for offline review. See [manual-mapping-stopgap.md](./manual-mapping-stopgap.md) for the field-level workflow.
4. **Living document:** as decisions get made, update the keep/cut table in place. The point isn't to be final on first writing — it's to give the team a shared map.
