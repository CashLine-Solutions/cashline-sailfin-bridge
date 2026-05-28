# Cashline-platform ontology — five-lens review synthesis

Synthesis of five independent reviews of the forward-looking cashline-platform ontology, conducted 2026-05-27 against extraction run 9 (123 sObjects, 4,554 fields, 582 relationships, 7,999 picklist values). Each finding below cites the source review file — drill in for the supporting SQL and quoted source.

- [`01-salesforce-architect.md`](01-salesforce-architect.md) — what Salesforce / SRM Cloud / `sfsrm__` actually ships
- [`02-collections-domain-expert.md`](02-collections-domain-expert.md) — operational semantics of disputes, promises, cash app, credit
- [`03-data-architect.md`](03-data-architect.md) — target-side architecture stress test
- [`04-analytics-engineer.md`](04-analytics-engineer.md) — empirical data vs schema reality
- [`05-general-data-analyst.md`](05-general-data-analyst.md) — cross-cutting, data quality, surprises

---

## P0 — live exposures, fix this week

### P0.1 — PII classifier lets banking/credentials/EIN through as `safe`

Source: `05-general-data-analyst.md` headline #4 and Surprise #1; `04-analytics-engineer.md` "Sensitivity flags."

Live finding from run 9: `sfsrm__EIN_or_Social_Security_Numbre_s__c`, `sfsrm__Archival_Password__c`, `ABA`/`Routing` fields, `Bank_Account_No`/`IBAN` fields, plus `Contact.FirstName` and `Contact.LastName` are all classified `safe`. The compound `Contact.Name` is correctly classified `pii`, but the discrete parts are not — so any extraction that reads `FirstName`/`LastName` via the describe API bypasses redaction.

Root cause is in [`app/services/ontology/sensitivity_classifier.rb:91`](../../../app/services/ontology/sensitivity_classifier.rb):

```ruby
PII_NAME_PATTERN = /email|phone|ssn|tax_id|dob|birth|first_name|last_name|address|postal|zip/i
```

Two bugs:

1. The pattern uses snake_case (`first_name`) and Salesforce field names are camelCase (`FirstName`). The `/i` flag is case-insensitive but does not bridge the underscore boundary. Add explicit camelCase alternations or normalize the name before matching.
2. The pattern is missing the banking-PII vocabulary: `aba`, `routing`, `bank_account`, `bank_acct`, `iban`, `swift`, `ein`, `social_security`, `password`, `secret`, `token`.

Recommended fix (one-line) — extend the pattern, plus normalize input:

```ruby
PII_NAME_PATTERN = /email|phone|ssn|ein|social_security|tax_id|dob|birth|first[_ ]?name|last[_ ]?name|address|postal|zip|aba|routing|bank[_ ]?account|iban|swift|password|secret|token/i
```

Acceptance test: re-run the classifier against run 9 fields and confirm `sfsrm__EIN_or_Social_Security_Numbre_s__c`, `sfsrm__Archival_Password__c`, `Contact.FirstName`, `Contact.LastName`, and any field matching `*Bank_Account*`, `*ABA*`, `*Routing*`, `*IBAN*` are all marked `pii` or `pii_and_financial`. Then re-profile and confirm no `top_values`/`sample_values` were collected for those fields.

This is the highest-priority finding because it is a **live exposure** — the data is already in the dev DB unredacted, and `field_profiles.top_values` for `Account.Name`, `Brand_Region__c`, `sfcapp__Bank_Name__c` carries real customer/bank/person names from a run that ran with `include_sensitive=false`.

### P0.2 — `sfsrm__Transaction__c → Invoice` 1:1 is wrong; should be `ARPosting` polymorphic parent

Source: `01-salesforce-architect.md` headline #1 and "SRM Cloud" section; `02-collections-domain-expert.md` headline; `04-analytics-engineer.md` "Object row-count vs claims."

`sfsrm__Transaction__c` is the polymorphic AR sub-ledger record. It carries 14 transaction types (verified via `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`): `Invoice / Credit Memo / Debit Memo / On Account / Apply Cash / Write Off / Write Back / Reversal / Offset / Auto Applied / Account to Account Transfer / Payment Refund / Deduction / Applied Credit`. The current mapping (`cashline-platform-ontology-comparison.md:45`) loses ~30–40% of AR-affecting rows.

Recommended target: `ARPosting` with `kind` enum + `Invoice` as one subtype. Aligns with SRM Cloud's actual data model and gives Gap 1 (no payment side) a coherent landing zone — "Apply Cash" / "On Account" rows are already in `sfsrm__Transaction__c`, they don't need separate ingestion.

This belongs in the comparison doc's gap list — see the updates below.

---

## P1 — decide before first real Client uploads

### P1.1 — Five architectural omissions not on the current gap list

Source: `03-data-architect.md` headline and "What's missing entirely."

| Omission | Why it bites | Cheapest fix |
|---|---|---|
| No soft-delete / discard | First accidental delete of a `Client::Group` is an audit-log replay exercise | Add `discarded_at` to every operational model |
| No `state_transitions` event log | "How long did this invoice spend in `in_review`?" is answerable only via Ruby reconstruction over `audited_changes` | One ~80-LOC polymorphic table + after_commit hook |
| No field-level provenance | Gap 10 (re-upload reconciliation) is ad-hoc without per-field source | `field_provenance jsonb` on `Invoice` |
| No `Tenant::Group` above Operator | Year-3 marketplace scenario is a multi-week migration; pre-empting is one nullable FK | Add nullable `tenant_group_id` now |
| No `ClientFieldDefinition` + `ClientFieldValue` pair | JSONB-only metadata fails the four collector concerns Gap 3 names | Sidecar pair with `target_entity` enum (see `03-data-architect.md` for shape) |

### P1.2 — Currency assumption is wrong

Source: `05-general-data-analyst.md` headline #3.

Comparison doc Design Decision 4 ("money in integer cents") is contradicted by the data: Accounts hold balances in 10 currencies (USD, CAD, BRL, GBP, EUR, AUD, ARS, NOK, COP, TTD). Multiple currencies have different minor units (JPY=0, TND=3). Every receivables-side amount has negative values (credits, reversals); unsigned cents columns can't represent them.

Add a `currencies` reference table + `currency_conversions` with date-bracketed rates before any non-USD invoice lands. Change cents columns from unsigned to signed.

### P1.3 — `CommunicationEvent` polymorphism issue recurs and worsens on `OperationalTask`

Source: `03-data-architect.md` "Polymorphic relationships."

Risk 2 in the comparison doc names the 6-optional-FK pattern on `CommunicationEvent`. The same shape recurs on `OperationalTask` (9 optional FKs, 8 cross-validators) and to a lesser degree on `Invoice`. The data architect's recommendation is the cleanest:

```
subject_type   enum (invoice / dispute / promise / customer_account / contact / standalone)
subject_id     polymorphic; null only when subject_type=standalone
client_group_id, customer_account_id, invoice_id  -- denormalized context, set by callback
context_derived_at, context_derived_from          -- provenance bit
```

This is the same shape Salesforce's `Task.WhatId` / `WhoId` settles on — a 25-year-old idiom worth borrowing.

### P1.4 — Picklist translation work is differently shaped than Gap 11 suggests

Source: `04-analytics-engineer.md` "Picklist value usage skew"; `02-collections-domain-expert.md` "Picklist translation."

Two of Gap 11's four "high-signal" picklists are **100% null in production**:

| Field | Active values | Distinct in data | %Null |
|---|---:|---:|---:|
| `sfsrm__Dispute__c.sfsrm__Sub_Type__c` | 70 | 64 | 87.5% (live) |
| `sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` | 64 | **2** | 100.0% (dead in data) |
| `sfsrm__Treatment__c.sfsrm__Treatment_Group__c` | 37 | 30 | 0.0% (fully live) |
| `sfsrm__Transaction__c.sfsrm__Sub_Reason_Code__c` | 36 | **0** | 100.0% (dead in data) |

Aggregate bloat: 7,250 of 7,983 active picklist values (91%) never appear in any row. The actual translation surface is much smaller than the schema suggests — but the collections domain expert flags **10 fields, ~290 values** of *real* translation work that the doc misses, including `sfcapp__Deduction_Reason_Code__c` (48 values, the cash-app worklist driver). Re-scope Gap 11 against in-data distinct counts, not declared picklist sizes.

### P1.5 — Missing operational entities a real collections shop will recreate as JSONB

Source: `02-collections-domain-expert.md` "Missing operational entities."

Six entities the collections domain expert flags as load-bearing, not on the current gap list:

1. **Credit Hold / Watchlist** — Sailfin has `Account.Credit_Hold__c`, `Credit_Limit_Total__c`, `sfsrm__Amount_Over_Credit_Limit__c`. Platform has nothing.
2. **Customer Hierarchy / Parent-Pay** — Sailfin has `Account.ParentId`, `Parent_Account_Total_AR__c`. Real reality: subsidiaries invoiced separately, parent pays. Add two FKs to `Customer::Organization`: `parent_organization_id` (org chart) and `pays_through_organization_id` (treasury arrangement).
3. **Dunning Strategy / Cadence** — Sailfin's `sfsrm__Treatment__c` 3×3 matrix. Per-Client config belongs in the ontology even if execution doesn't.
4. **Aging Bucket Definition** — Sailfin hardcodes 30/60/90; real shops have Client-configurable buckets.
5. **Statement of Account** — most common dispute trigger ("you say $50K, my records say $48K") with no platform model.
6. **Collection Note routing** — notes belong on `Customer::Account` or `PaymentPromise`, not embedded on the triggering invoice.

### P1.6 — Cluster map mis-classifies live data; cut decisions need re-validation

Source: `04-analytics-engineer.md` "Object row-count vs cluster-map claims"; `05-general-data-analyst.md` "Unnamed risks."

Three corrections to flag back to the cluster map:

- `sfsrm__Temp_Object_Holder__c` (184,452 rows — second-largest custom object) is classed as a config table. It is not. Likely an SFSRM per-Transaction scratch table. Confirm before cutting.
- `Task` has 521,417 rows, not the ~20K the cluster map's filter implies. The activity-model design needs to size against half a million tasks.
- `Open_Invoices__c` (30,881 rows) carries open workflow state, not "pure reporting" — confirm redundancy with `sfsrm__Transaction__c.sfsrm__Status__c` before cutting.

Also flagged: `sfsrm__Data_Load_Batch__c` (91,576 rows of 5+ years of ingestion history) has no backfill story when the platform's `ImportBatch` starts fresh.

---

## P2 — track but defer

### P2.1 — `object_profiles.record_count` is NULL for all 123 objects

Source: `04-analytics-engineer.md` methodology note; `05-general-data-analyst.md` headline #5.

R9 in the plan (record_count profiling) is not satisfied — the loader never populated `object_profiles.record_count`. The `unused_fields` report still works because it joins on `field_profiles.null_rate`, but `runs/show` displays blanks for row count. Every row-count claim in the existing comparison/cluster-map docs was sourced *outside* the DB. Fix the loader to persist record_count from the profile job output; backfill is straightforward.

### P2.2 — `sobjects.namespace_prefix` and `sfields.namespace_prefix` are NULL for every row

Source: `05-general-data-analyst.md` Surprise #2.

The relational loader drops namespace metadata silently. Anything querying these columns gets wrong answers; downstream reports and the namespace EDA numbers in the docs were sourced from the JSONL files, not the DB. Fix in `app/services/runs/relational_loader.rb`.

### P2.3 — Automatic clustering output is unusable

Source: `05-general-data-analyst.md` headline #6 and "Scope-vs-effort mismatch."

The plan's Unit 18 (modularity clustering) shipped but the output has duplicate cluster names ("Call Center" ×2, "Account" ×2) and a 32-object cluster mashing `Collection_Forecast__c` with `ProfileSkillEndorsement` and `User`. The hand-curated cluster map is the only usable grouping. Either drop the auto-cluster surface or replace it with a "reset to hand-curated default" rather than letting algorithmic output overwrite manual fix-ups.

### P2.4 — Date sentinels and numeric overflow will break Rails validations

Source: `05-general-data-analyst.md` "Date sentinels" and "Numeric overflow."

Source data has dates spanning 1753-01-01 (SQL Server datetime min, used as sentinel for "unset") to 3623-09-08 (typo: `2023` → `3623`). Numeric overflow on `Weighted_Days_to_Pay__c` reaches ±580 billion days; `Credit_Limit_Total__c` peaks at $4.6 trillion. The platform's Rails `Date` validations will reject these wholesale at migration. Add bounds-checking + sentinel-stripping to the ingestion pipeline before first real sync.

---

## Findings by lens — one-paragraph each

### Salesforce architect (`01-salesforce-architect.md`)

The team is conflating standard SF / managed package / custom across the 123 objects. Sailfin uses **none** of standard SF's polymorphism affordances — no `RecordTypeId` anywhere, no `AccountContactRelation`, no `*History` field tracking, no Person Accounts, no `ContactPointAddress`. These are conscious choices the comparison doc should call out, not coincidences. `sfsrm__Transaction__c` is SRM Cloud's polymorphic AR posting record (14 transaction types), not an Invoice. The 70 `sfsrm__Dispute__c.sfsrm__Sub_Type__c` values decompose into ~25 dispute / ~30 task / ~10 derived / ~5 disposition. Strategic recommendation: read-through `sfsrm__` (don't sync-back into a vendor schema), model `ARPosting` as polymorphic parent, treat per-picklist translation tables as the real deliverable.

### Collections domain expert (`02-collections-domain-expert.md`)

Five places where the cashline-platform ontology compresses real workflow distinctions: (1) `sfsrm__Status__c` 12 values include 4 that are collector-touch flags, not lifecycle states; (2) the stub Payment forecloses ~140 cash-side semantic states across 5 picklists; (3) PaymentPromise needs to be a header on `Customer::Account` with bucket-promise support, not invoice-level; (4) `Dispute.Sub_Type` 70 values decompose into substantive (~30) + escalation stages (~20) + cash-app states (~10) + noise (~10); (5) three missing operational entities (Credit Hold, Customer Hierarchy/Parent-Pay with two FKs, Dunning Strategy). The picklist translation work is ~10 fields and ~290 values, two domain-expert weeks of focused mapping.

### Target-ontology data architect (`03-data-architect.md`)

The party model (Operator → Client::Org → Client::Group → Customer::Org → Customer::Account) is structurally sound and genuinely fixes the Aethon-22x problem at the schema level. Five omissions not on the comparison doc's gap list compound over time: no soft-delete, no `state_transitions` event log, no field-level provenance, no `Tenant::Group` shell above Operator, no `ClientFieldDefinition + ClientFieldValue` structured-extensibility pair. The `CommunicationEvent` 6-FK pattern recurs and worsens on `OperationalTask` (9 optional FKs); the right fix is a `subject_type/subject_id` discriminator with denormalized context FKs. Year-3 stress tests: second receivables source is easy if SoR work lands first; marketplace sub-tenant is the painful scenario worth pre-empting now; sanctions screening is medium-pain.

### Analytics engineer (`04-analytics-engineer.md`)

Half the source org is empty — 62 of 123 objects have zero rows, including four the comparison treats as load-bearing: `sfsrm__Credit_Application__c`, `sfsrm__Credit_Review__c`, `sfsrm__Trade_Reference__c`, and `sfsrm__Line_Item__c` (the InvoiceLine). Picklist bloat is 91% (7,250 of 7,983 active values never appear in data); two of Gap 11's four "high-signal" picklists are 100% null. The cluster map misclassifies `sfsrm__Temp_Object_Holder__c` (184K rows, second-largest custom object) as config, undersizes `Task` by 25× (521K, not 20K), and treats `Open_Invoices__c` (30K rows) as a sidecar when it carries open workflow state. Quiet load-bearing pattern: every `_Key__c` field is a populated external-system join anchor; some aren't flagged `externalId`. The cash-side gap costs 49 live sensitive fields, and the `sfcapp__` namespace (76.8% live) is denser with real data than the receivables core.

### General data analyst (`05-general-data-analyst.md`)

PII has already leaked into a supposedly non-sensitive run — top_values for `Account.Name`, `Brand_Region__c`, `sfcapp__Bank_Name__c` carry real customer/bank/person names because the classifier's "safe unless FirstName/LastName sibling" rule is wrong for B2B (company name = protected information). Tenant leakage is 3× larger than docs claim (9 tenants: Viking, ELS, Endurance, KLX, Voltyx, Griffin, Warrior, Centerline, Casey Sprayberry — plus 6 French-labeled fields, i18n never mentioned anywhere). The platform's "money in integer USD cents" plan contradicts the data (10 currencies, negative amounts everywhere). `object_profiles.record_count` is NULL for all 123 objects — every row-count claim in the docs was sourced outside the DB. The sensitivity classifier marks `ABA`, `IBAN`, `Bank_Account_No`, `EIN_or_Social_Security_Numbre_s`, and `Archival_Password` all as `safe`.

---

## Recommended next moves

In order:

1. **Today**: fix `app/services/ontology/sensitivity_classifier.rb` PII_NAME_PATTERN + re-run classifier against run 9 + verify the named-and-shamed fields are properly classified. This is the only live-exposure issue.
2. **This week**: update the comparison doc's gap list with the new gaps (currency, soft-delete, state-transition log, ARPosting polymorphism, structured extensibility, missing operational entities, Tenant::Group). Updates have been applied — see the comparison doc.
3. **Before first brand migration**: re-scope Gap 11 against in-data distinct counts. Add `sfcapp__Deduction_Reason_Code__c` to the high-signal list. Defer the two 100%-null picklists.
4. **Before first Sailfin sync**: re-model `sfsrm__Transaction__c → ARPosting` (polymorphic parent), not Invoice 1:1. This is the biggest reversal cost on the table.
5. **Phase 1 follow-up**: add `state_transitions`, `discarded_at`, field-level provenance, nullable `tenant_group_id`, `ClientFieldDefinition + ClientFieldValue`. Each is cheap now, expensive later.
