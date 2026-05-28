# Gap 12 — `ARPosting` redesign, cross-cutting lens (general data analyst)

Follow-up to the 2026-05-27 five-lens review. The panel has converged on a P0: `sfsrm__Transaction__c` is the polymorphic AR posting record (14 transaction types verified on `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`), not Invoice. The four specialists have the canonical-mapping, operational, target-architecture, and sizing lenses covered. This is the catch-all lens — interactions with Gaps 13–16, the data-quality landmines, the "what if we don't" risk inventory, and one surprise.

Anchor data — `cashline_ontology_development`, run_id=9, extraction `2026-05-24T23-27-12Z-be06`. SQL throughout.

---

## Cascades into Gaps 13–16

The panel has discussed the four other new gaps as if they were independent. They are not. The shape we pick for `ARPosting` cascades into every one of them.

### Gap 13 (PII classifier)

PII on `sfsrm__Transaction__c` is per-posting, not per-Invoice:

```sql
-- 13 pii-classified fields on Transaction, including:
-- sfsrm__Ship_To_Address__c   distinct=3,294
-- Job_Address__c              distinct=8,809
-- + 11 Viking_*_Email__c fields
```

8,809 distinct job-site addresses attached to individual postings. If we collapse Invoice/CreditMemo/OnAccountCash/WriteOff into one `ARPosting`, those PII columns ride along on *every subtype* — but a `WriteOff` has no business carrying a job-site address. Two consequences:

1. **Subtype-specific PII surface.** Classifier (Gap 13) is per-`sfield` today; with `ARPosting` it has to be per-`(field × kind)`. New structure.
2. **The leak amplifies.** On Invoice, `Job_Address__c` is legitimate-but-protected. On OnAccountCash it's polymorphic-carrier junk — and `top_values` collection still happens because the classifier doesn't know "this column is null-by-design for kind=on_account_cash."

Gap 12's design must produce a `legitimate_kinds[]` annotation on each field so a future classifier suppresses PII collection from rows where the field has no business being populated.

### Gap 14 (multi-currency / signed)

The worst cascade. **An `OnAccountCash` in USD applied against a `BRL` invoice — what currency does `ARPosting.amount` carry?**

```sql
-- CurrencyIsoCode             null=0      USD/CAD/KWD/BRL/GBP/AUD/COP/ARS/NOK/EUR
-- sfsrm__Base_Currency__c     null=0.78   USD/KWD/ARS/BRL/CAD/GBP/COP/AUD/MXN/TTD
-- sfsrm__Group_Currency__c    null=1.00   abandoned
-- sfsrm__Currency_Rate_CA__c  null=0.86   14% populated
```

The source carries the answer Sailfin worked out: **each posting holds its own currency plus a snapshot rate to base, and `Group_Currency` was abandoned (100% null).** In the OnAccountCash-vs-BRL-invoice case: Invoice minted in BRL at one rate; OnAccountCash minted in USD; Apply Cash carries **the rate at apply-time, not at invoice-time**. `ARPosting.amount` must therefore be a struct `(amount_minor, currency_iso, fx_rate_to_base, fx_rate_as_of)`, not a scalar. The 14% population on `Currency_Rate_CA__c` is the evidence — only foreign-currency postings carry a rate.

Two design choices fall out:

1. The `currency_conversions` reference table from Gap 14 is *not* sufficient alone. A rate table answers "what was the rate on 2026-05-15"; we also need the rate Sailfin *actually booked* at — the snapshot on the row.
2. `ARPosting.balance_due_minor` must be in posting-currency; customer-level `total_outstanding_base_minor` is a sum-over-subtypes-with-FX. The synthesis "switch cents columns from unsigned to signed" is a one-liner; this is a two-week ticket.

Kuwaiti Dinar (KWD — 8,253 postings, third-most-common above) has **three** subunits (fils, 1/1000). `*_cents` silently misvalues KWD by 10×. Use `*_minor` keyed off `currencies.subunits`.

### Gap 15 (soft-delete + state-log + provenance + Tenant::Group + ClientFieldDefinition)

Three of the five tighten under `ARPosting`:

1. **`discarded_at`** — fine on Invoice, but **opens a question on ARPosting**: if a `CreditMemo` posting is discarded, the parent Invoice's `balance_due` must recompute. Soft-delete needs a derived-fields-recompute trigger.
2. **State-transitions log** — see §"Audit and provenance" below.
3. **Field-level provenance** — the source already has it:
   ```sql
   -- sfsrm__Source_System__c top values
   -- Flowco 420,851 | KLXTickets 299,935 | KeyEnergy 243,945
   -- KLXEnergyServices 187,697 | EpicLift 176,502 | EnduranceLift 77,397 | …
   ```
   Different postings on the same invoice come from different source systems. The platform's missing model hides what the source already carries.
4. **`Tenant::Group` shell** — 9 tenants + 13 source-systems means Tenant::Group is **already implicitly two layers deep**: Operator → Tenant → SourceSystem. The Gap-15 nullable FK should be `source_system_id` on ARPosting too, not just `tenant_group_id` on `Client::Organization`.
5. **`ClientFieldDefinition + ClientFieldValue`** — the biggest landing zone for the 57 tenant-leaked fields on Transaction (inventory below). Definitions must be scopable **per-subtype**, not just per-entity. `Viking_Branch_Manager__c` is meaningful on Invoice kind only.

### Gap 16 (missing operational entities)

Two collide directly with `ARPosting`:

- **Dunning Strategy** drives `Treatment_Group` (37 codes A–Z, AA–ZZ on `sfsrm__Treatment__c`). Treatment is **per-posting** in Sailfin (`Treatment_Level__c`, `Treatment_Exception__c`, `Treatment_Latest_Note__c` on `sfsrm__Transaction__c`). A `WriteOff` cannot be in dunning level "M"; an `OnAccountCash` has no treatment. Treatment lives on the Invoice subtype only.
- **Aging Bucket** — 8 calculated aging fields on `sfsrm__Transaction__c` (`Amount_Due_30__c`, `Amount_Due_90__c`, `Amount_Outstanding__c`, `sfsrm__Aging_Group__c`, `sfsrm__DPD__c`, `sfsrm__DPD_x_Amount__c`, …). Computed *per posting*. Customer aging is a sum over **Invoice-kind postings minus credits/applications**. Gap 16 talks about per-Client bucket *definitions*; doesn't acknowledge the per-posting *computation*.

---

## Tenant-leakage cascade — where do the 9 tenants' fields land?

57 tenant/i18n-leaked fields on Transaction alone (verified via `api_name ILIKE` rollup): 33 Viking, 6 French (Montant/Date_d_echeance), 4 ELS, 4 Endurance, 3 KLX, 2 each Griffin/Voltyx, 1 each Warrior/Alpine/Casey Sprayberry. In the ARPosting world they fall into three buckets:

1. **Invoice-subtype-only (~50).** `Viking_Branch_Manager__c`, `ELS_Portal_Status__c`, `KLX_Contact__c`, `Griffin_Payment_Terms__c`, French amount fields — describe an *invoice*. → `Invoice.client_field_values[]` via the Gap-15 sidecar.
2. **Account-subtype denormalizations (~5).** `Viking_Region_Key__c`, `Viking_Division__c`, `Viking_Brand__c`. → `Customer::Account.client_field_values[]`, not duplicated per-posting.
3. **Tenant notes (~2).** `Viking_Internal_Meeting_Notes_To_Dos__c`, `Voltyx_Notes__c`, `Warrior_Status_Update__c`. → `CommunicationEvent` with `subject_type='ar_posting'`, not as columns.

The trap: defining tenant fields at the `ARPosting` polymorphic-parent level. Almost all belong on `Invoice` or `Customer::Account`. With per-subtype scoping the active surface is 5–15 fields × 9 tenants ≈ 60–135 ClientFieldDefinitions. Big but bounded.

---

## Data-quality landmines for the migration runbook

### Landmine 1 — `Invoice_Amount__c` is a disposable string formula

```sql
-- Invoice_Amount__c   string   calculated=t   distinct=675,795
-- sfsrm__Amount__c    currency calculated=f   distinct=675,796   min -$39M  max $4.8B
-- Original_Amount__c  currency calculated=t   distinct=675,795   min -$4.56B max $4.81B
-- sfsrm__Balance__c   currency calculated=t   distinct=51,444    min -$16M  max $20.9M
```

`Invoice_Amount__c` is `TEXT(Amount)` — disposable. **Canonical amount is `sfsrm__Amount__c`.** The $4.8B max on a non-calculated column is the lurking horror — see surprise below.

### Landmine 2 — Date sentinels propagate through 145 formulas

```sql
-- sfsrm__Due_Date__c             1753-01-01 → 2125-12-30
-- Best_Possible_Payment_Date__c  1753-01-01 → 2125-12-30
-- Expected_Payment_Date__c       1753-02-12 → 3623-09-08
-- Ecommerce_Due_Date__c          1753-02-12 → 3623-09-08
-- sfsrm__Promise_Date__c         2002-05-07 → 3623-09-08
```

145 calculated formulas on Transaction; any chained off `Due_Date__c`/`Expected_Payment_Date__c` inherits the sentinel, including 16 calculated amount/DPD fields. Strip sentinels at the ingest boundary (Rails validation rejects the row; we want to admit with NULL).

### Landmine 3 — Two `PO_Number` fields, one populated

`PO_Number__c` (null=0) and `sfsrm__Po_Number__c` (null=0.83). Custom wins in practice. Pick one in ARPosting; reconcile other at ingest.

### Landmine 4 — `Document_Type_Description__c` has 151 distinct values, no governance

The discriminator we'd use to assign `ARPosting.kind` from source is `Document_Type_Description__c`. `data_type='string'`, **151 distinct values**: `INVOICE` (789K), `Ticket` (300K), `AR Invoice` (57K), `CREDIT MEMO` (7.2K), `General Journal` (5K), `Draft Invoice` (4.7K), `Unapplied Cash` (3K), `PAYMENT`, `Credit`, `AR Credit Memo`, plus a 141-value long tail. Mapping 151 strings to 14 kind enums is **a Gap-11-shaped translation table for an SF-typed-as-string field with no picklist governance.**

### Landmine 5 — The discriminator we want is on the *child* table

```sql
-- On sfsrm__Transaction__c: Transaction_Type__c   null_rate=1.000 (always empty!)
-- On sfsrm__Payment_Line__c: sfsrm__Transaction_Type__c  14 picklist values
```

The 14-value kind discriminator lives on `Payment_Line` rows that point at the Transaction. So `ARPosting.kind` has to be **derived from `Document_Type_Description__c` (151 values) + rolled up from `Payment_Line.Transaction_Type__c` (14 values) + `sfsrm__Status__c` (56 distinct in run 9)**. Round-1's "11 status fields on Transaction" matters here: status is shattered across 11 columns *and* kind has to be inferred from 4 sources. This is the migration's most likely-to-ship-wrong piece.

---

## "What if we don't" — concrete breakage from keeping 1:1 Invoice mapping

1. **Credit memos disappear.** `'CREDIT MEMO'` 7,176 + `'AR Credit Memo'` 808 ≈ 8K postings with negative amounts. Gap-14 unsigned cents rejects them; 1:1 mapping has nowhere to put them.
2. **On-account cash silently merges with invoices.** `'Unapplied Cash'` 3,016 rows land as Invoice with `kind=NULL`.
3. **Apply Cash and Auto Applied lines (236K+ on Payment_Line) have no Invoice on platform side.** "Cash applied this week" is unanswerable without inventing it at query time.
4. **Aging breaks.** Paid invoices have zero in `Amount_Due_30/60/90` on the source because credits/applications zeroed it. Without the credit/cash postings on the platform, only Invoice rows exist — still carrying pre-payment aging. Report says $X; ledger says $0.
5. **Gap-10 reconciliation becomes unimplementable.** Per-record reconciliation on `(client_group, invoice_number)` works for Invoice; has no key for "this CreditMemo against that Invoice."
6. **Customer totals wrong by 30–40% on receivables-mixed accounts.** Net AR = sum of postings, not sum of invoices. Round-1's `Original_Amount__c` range (-$4.56B → $4.81B) is the receivables-side breadth being lost.
7. **PaymentPromise (Gap 6) becomes ungrounded.** `sfsrm__Promised_Amount__c` is on `sfsrm__Transaction__c`. Multi-invoice promises lose linkage in 1:1.
8. **`audited_changes` inherits the broken model.** Every Invoice row gets audited; every CreditMemo row that should have existed never does. Audit replay (Gap 15) reconstructs the *wrong* history.

The least-bad 1:1 shipping path is an explicit rejection log: `received subtype=CreditMemo, dropped (no ARPosting model)`. Tractable "ship now, fix later", and makes the gap visible in production.

---

## Are we missing a subtype? Scan of the 14

The 14 from `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c` aren't all distinct *kinds*. `Applied / Apply Cash / Auto Applied / Applied Credit` are verb-tense variants of "cash hitting AR." Actual kinds:

- Header: Invoice, CreditMemo, DebitMemo, OnAccountCash
- Adjustments: WriteOff, WriteBack, Reversal, Discount
- Transfers: AccountToAccount, Offset, PaymentRefund, AppliedCredit
- Reductions: Deduction

Scan for things that **ought to be kinds but aren't**:

1. **`DebitMemo`** — not in the 14 (Sailfin enters debit memos as Invoice with `Document_Type_Description__c='AR Invoice'` and positive amount). Model it anyway for ERP portability.
2. **`FinanceCharge` / `LateFee`** — `Handling_Charge__c` and `VA_Charge__c` exist on Transaction (null=0.027). 97% of postings carry a handling-charge column. Today they ride on Invoice. If any Client invoices late fees separately (common B2B), `FinanceCharge` is a missing subtype.
3. **`Promise` posting** — Sailfin has 13 promise-related columns on Transaction (`sfsrm__Promise_Date__c`, `sfsrm__Promised_Amount__c`, `Broken_Promise_Amount__c`, `Promise_Status__c`, …). Promises are state on Invoice, **not separate postings**. `PaymentPromise` (Gap 6) is a separate entity, not a kind.
4. **`Hold` marker** — `Dunning__c` is a boolean on Transaction; `Credit_Hold` (Gap 16) is a separate entity, not a kind.
5. **`Dunning_Action` posting** — Treatment is its own sobject (`sfsrm__Treatment__c`); → `CommunicationEvent`, not a kind.
6. **`Statement` posting** — a snapshot view, not an ARPosting. Don't put in the enum.

So the kind enum is roughly right. **Add `DEBIT_MEMO` and `FINANCE_CHARGE`. Resist** `PROMISE`/`HOLD`/`DUNNING_ACTION`/`STATEMENT` — they're separate entities.

---

## Audit and provenance — 3 postings, not 1 state machine

The data architect lens will half-cover state-transitions and the domain expert will half-cover cash-app workflow. The right answer cuts across both.

`OnAccountCash` and `ApplyCash` are **two different rows in `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`** in run 9 (194,263 Apply Cash + 19,936 On Account). They are not state transitions of the same row. Sailfin mints fresh rows:

- Wire arrives → Treasury creates `OnAccountCash` posting + `Payment_Line` linking to Payment.
- Cash app reviews → analyst creates `ApplyCash` row linking Payment to *target Invoice*. On Account balance goes to zero.
- Correction → `Reversal` row (1,881 in run 9).

**3 separate postings, not 1 with a state machine.**

Implications for Gap 15's `state_transitions` log: the log is **between Invoice statuses** (`open → in_review → paid`), not between ARPosting kinds. Kinds don't transition — they accumulate. A row of kind `OnAccountCash` doesn't *become* kind `ApplyCash`; a new row is minted.

This shapes audit gem usage:
- Per-row `audited_changes` on ARPosting tracks amount/status/notes/treatment within one posting's lifetime. Most postings are write-once except for `applied_amount_minor` rolling up from child Payment_Lines.
- `state_transitions` log lives on **`Invoice`** (and Dispute, PaymentPromise), keyed by `(invoice_id, from_state, to_state, transitioned_at, by_user_id, reason)`. **Not** keyed by ARPosting.
- Sizing: per-row `audited_changes` is high-volume on `Invoice` (touched by every Apply Cash), low-volume per individual ARPosting (mostly write-once). Price the audit DB on Invoice updates.

The corner case the specialists will miss: **`Reversal` postings carry provenance back to the original posting via `Credit_Memo_Reference__c` + `Original_Amount__c` + `Original_DPD__c`** (verified on Transaction). Audit has two layers: per-row `audited_changes` *plus* inter-row provenance. Gap 15's `field_provenance jsonb` doesn't cover inter-row provenance. **Add `reverses_ar_posting_id` self-FK on `ARPosting`.**

---

## One surprise — the $4.8 billion posting forces a data-cleaning gate before migration

Round-1 caught the $4.6 trillion `Credit_Limit_Total__c` on Account. The follow-up: `sfsrm__Amount__c` on Transaction has **max $4,809,736,487 ($4.8 billion)**, `data_type='currency'`, `calculated=false`. **Someone, somewhere, posted a $4.8B transaction.**

The 145 calculated formulas consume this. They produce `Original_Amount__c` (-$4.56B → $4.81B), `sfsrm__DPD_x_Amount__c` (-570B → 498B), `Weighted_Days_to_Pay__c` (-570B days → 580B days). One $4.8B input row poisons the entire KPI surface.

The surprise the specialists will miss: the ARPosting redesign **forces a data-cleaning gate before migration runs**. The team has been treating ARPosting as a model decision. It is also a remediation decision. Until the $4.8B row is investigated and either fixed-in-source or quarantined-on-ingest, the platform's `*_minor` columns can technically hold it (`bigint` fits), but downstream:

- `Customer::Account.total_outstanding_base_minor` for that customer gets a $4.8B addend.
- `DunningStrategy` triggers on `total_outstanding` — that customer auto-escalates to Legal.
- Aging rollups — customer's 90+ bucket shows $4.8B; the report is unusable.
- KPI rollups in `bigint` are precise; views that cast to `float64` for charting hit the precision boundary at 16 digits (480,973,648,700 cents).

This is the kind of finding that lives in nobody's individual lens. The SF architect sees polymorphic mapping; the domain expert sees cash-app workflow; the data architect sees schema shape; the analytics engineer sees column statistics. But **"the ARPosting redesign cannot ship until the source is cleaned, and cleaning requires the model"** is the chicken-and-egg the cross-cutting lens is for.

Recommendation: bound-check ingest at $1B/posting (configurable per-Client), quarantine rows above into an `IngestionRejection` log (sidecar of `ImportBatch`), surface the rejection count in the dashboard. The $4.8B row probably represents either a real corner case (multi-year master agreement) or a typo — either way the Operator needs to see it before it ships.

---

## Cross-references

- SF-canonical mapping of the 14 kinds → reviewer 01.
- Operational semantics of OnAccountCash → ApplyCash → Reversal → reviewer 02.
- ARPosting table shape, indexes, FKs → reviewer 03.
- Volumes, null rates, distribution skew → reviewer 04.

This document is the joints between those four.
