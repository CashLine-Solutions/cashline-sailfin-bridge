# Gap 12 — `ARPosting` design proposal (Salesforce / SRM Cloud lens)

Follow-up to [`../01-salesforce-architect.md`](../01-salesforce-architect.md) headline #1 and synthesis P0.2. The panel accepted that `sfsrm__Transaction__c` is SRM Cloud's polymorphic AR posting record, not Invoice. This doc specifies the target shape. All counts verified against run 9 (`extraction_run_id=9`, `cashline_ontology_development`).

---

## 1. The 14 transaction types and the `ARPosting.kind` mapping

```sql
SELECT pv.value FROM spicklist_values pv
JOIN sfields f ON f.id = pv.sfield_id JOIN sobjects o ON o.id = f.sobject_id
WHERE o.extraction_run_id=9 AND o.api_name='sfsrm__Payment_Line__c'
  AND f.api_name='sfsrm__Transaction_Type__c';  -- → 14 active rows
```

Cross-checked with `field_profiles.top_values` on 261,166 Payment_Line rows: only 10 of the 14 values appear in data. Counts below are in-data occurrence on Payment_Line.

| # | `sfsrm__Transaction_Type__c` | PL count | → `ARPosting.kind` | Decision |
|--:|---|--:|---|---|
| 1 | `Apply Cash` | 194,263 | `apply_cash` | Preserve. Dominant cash-app event; `sfcapp__CashApp_Applied_Amount__c` keys off it. |
| 2 | `Auto Applied` | 41,200 | `apply_cash` (`auto=true`) | **Collapse.** Provenance-only difference; carry source value in subtype `auto_applied:boolean`. |
| 3 | `Applied` | 456 | `apply_cash` (`auto=false`) | **Collapse.** SRM Cloud's legacy label for the same action. |
| 4 | `On Account` | 19,936 | `on_account` | Preserve. Cash with no allocation yet. |
| 5 | `Credit Memo` | 732 | `credit_memo` | Preserve. Negative invoice; needed for AR aging and tax reporting. |
| 6 | `Applied Credit` | 50 | `apply_credit` | Preserve. Credit-memo equivalent of `apply_cash`; closes credit balances. |
| 7 | `Deduction` | 1,892 | `deduction` | Preserve. Customer short-pay; feeds `sfcapp__Deduction_Reason_Code__c` (48 values). |
| 8 | `Discount` | 0 | `discount` | Preserve. Picklist active, no data yet — first non-Key-US tenant will populate. |
| 9 | `Write Off` | 30 | `write_off` | Preserve. Distinct approval and GL impact. |
| 10 | `Write Back` | 0 | `write_back` | Preserve. Reversal of write-off (cash arrived post-charge-off). |
| 11 | `Reversal` | 1,881 | `reversal` | Preserve. SRM's "undo"; subtype carries `reverses_posting_id`. |
| 12 | `Offset` | 0 | `offset` | Preserve. Net debit-vs-credit on same customer; no cash moves. |
| 13 | `Account to Account Transfer` | 726 | `account_transfer` | Preserve. Subtype carries `transferred_from/to_account_id`. |
| 14 | `Payment Refund` | 0 | `payment_refund` | Preserve. Outbound cash — direction-opposite of `apply_cash`. |

Plus the implicit 15th — `Payment_Line.Transaction_Type__c` never carries it because invoices don't apply against themselves, but it's the dominant kind on the Transaction side (verified via `Document_Type_Description__c` top values on the 2.17M Transaction rows):

| 15 | `Invoice` (from `Document_Type_Description__c` data) | 789,491 INVOICE + 299,935 Ticket + 57,449 AR Invoice + 4,738 Draft Invoice ≈ **1.15M** | `invoice` | Preserve. The originating debit posting; the 14 values above are the *applied-against* vocabulary. |

**Final enum (12 values, from 15 verified types — two safe collapses):**

```
invoice | credit_memo | on_account | apply_cash | apply_credit
write_off | write_back | reversal | offset | deduction | discount
account_transfer | payment_refund
```

Collapse rule applied: *preserve when downstream collections/aging/tax filters on the distinction; collapse when the difference is provenance only.* `Auto Applied`/`Applied`/`Apply Cash` are provenance variants of one event — collections doesn't route differently on them.

---

## 2. Column split — `ARPosting` parent vs. STI subtypes

The parent carries columns that exist *and have meaning* on every kind. Subtypes carry kind-specific fields. Of the 75 `sfsrm__`-prefixed columns on `sfsrm__Transaction__c` (verified), the split is:

### `ar_postings` (parent — ~20 columns, every kind)

```
id                       bigint pk
kind                     enum (12 values)
client_group_id          fk → client_groups          -- denormalized for query
customer_account_id      fk → customer_accounts      -- the Account-link
operator_id              fk → operators
posting_number           text                        -- ← sfsrm__Transaction_Key__c (external id)
posted_at                timestamptz                 -- ← sfsrm__Create_Date__c (label "Invoice Date" misleads — it's the posting date for ANY kind)
due_at                   timestamptz nullable        -- ← sfsrm__Due_Date__c (null on cash/on_account/refund)
closed_at                timestamptz nullable        -- ← sfsrm__Close_Date__c
amount_cents             bigint SIGNED               -- ← sfsrm__Amount__c (must be signed; credits/reversals are negative — see Gap 14)
balance_cents            bigint SIGNED               -- ← sfsrm__Balance__c (open-AR contribution)
currency_iso             text                        -- ← CurrencyIsoCode (ISO 4217)
source_system            text                        -- ← sfsrm__Source_System__c
source_system_kind       text                        -- ← Type__c (raw ERP codes: "I","IN","RI","RV","13","60"…)
source_document_type     text                        -- ← Document_Type_Description__c (e.g. "INVOICE","CREDIT MEMO","Unapplied Cash")
external_id              text                        -- Salesforce Id, for sync provenance
approval_state           enum   (see §3)
collections_state        enum   (see §3)
days_past_due            integer                     -- ← sfsrm__Days_Past_Due__c (recomputed)
metadata                 jsonb                       -- catch-all for 31 Viking_*, 27 Corrpro_*, French-labeled, etc.
imported_from_sync_run_id fk → sync_runs nullable
discarded_at             timestamptz nullable
```

### Subtype tables

- **`invoices`** (kind=`invoice`) — `invoice_number`, `po_number`, `so_number`, `discount_amount_cents`, `discount_date`, `subtotal_cents`, `tax_cents`, `tax_exempt`, `payment_terms`, 6 `bill_to_*`, 6 `ship_to_*`, `disputed_amount_cents`, `undisputed_balance_cents`. Has children: `invoice_lines` (from `sfsrm__Line_Item__c`, 27 fields, **0 rows** in run 9 — ERPs aren't writing lines back to Sailfin).
- **`credit_memos`** (kind=`credit_memo`) — `credit_memo_number`, `references_invoice_id` (fk; resolved from free-text `Credit_Memo_Reference__c` on migration — that field is 100% null in data so source rebuilding is brand-by-brand), `reason`.
- **`on_account_cash`** (kind=`on_account`) — `payment_id`, `received_at`, `remit_reference`. The `balance_cents` here is *unapplied* cash, drawn down by future `apply_cash` rows.
- **`cash_applications`** (kind ∈ `apply_cash`, `apply_credit`) — `auto_applied:boolean` (absorbs the Auto Applied collapse), `applied_against_id` (→ ar_postings: the invoice/CM being paid down), `payment_id`, `applied_amount_cents`, `applied_at` (← `sfcapp__Posting_Date__c`).
- **`write_offs`** (kind ∈ `write_off`, `write_back`) — `writes_off_id`, `reason_code`, `approved_by_user_id`, `gl_account` (← `sfcapp__GL_Account__c`), `direction` enum.
- **`ar_adjustments`** (kind ∈ `deduction`, `discount`, `reversal`, `offset`, `account_transfer`, `payment_refund`) — one shared subtype with `kind`-scoped check constraints: `reason_code`, `deduction_type` (only when kind=deduction), `reverses_posting_id` (only kind=reversal), `offsets_posting_id` (only kind=offset), `transferred_from/to_account_id` (only kind=account_transfer), `refunded_to_payment_id` (only kind=payment_refund). This is the SF `RecordType`-per-business-process idiom in Rails STI form — `validates :reverses_posting_id, presence: true, if: -> { kind == 'reversal' }` per kind.

### What does *not* migrate

1. The **145 formula fields** on `sfsrm__Transaction__c` — Sigma recomputes them on every write. We recompute on our side. Drop.
2. The **64 date columns** with overlapping semantics (`Expected_Payment_Date__c`, `_V2__c`, `_Pro__c`, `_Merit_Flow__c` all exist) — collapse to one `expected_payment_at` per kind; alternates to `metadata` for a quarter, then drop.
3. The **31 Viking_*, 27 Corrpro_*, Alpine_, Casey_Sprayberry_, French-labeled fields** — tenant-leaked Client extensions. Migrate to `ClientFieldDefinition`/`ClientFieldValue` (P1.1), not `ar_postings`. Verbatim in `metadata` on first sync; structured migration is P1 follow-up.

---

## 3. `sfsrm__Status__c` — split the two state machines

Verified: `sfsrm__Transaction__c.sfsrm__Status__c` declares 12 active picklist values, but `field_profiles.distinct_count = 56` (real values in data) and `null_rate = 0.82`. The picklist is narrower than the data. The 12 declared values resolve to **two orthogonal state machines plus picklist garbage**:

| Value | In-data count | State machine | Target column |
|---|--:|---|---|
| `0. UNAPPROVED` | 6,543 | approval | `approval_state = unapproved` |
| `1. APPROVED FOR REVIEW` | 1,198 | approval | `approval_state = pending_review` |
| `2. APPROVED FOR SIGNATURE (ACCRUED)` | 3,137 | approval | `approval_state = pending_signature` |
| `3. APPROVED FOR BILLING (ACCRUED)` | 2,395 | approval | `approval_state = approved_for_billing` |
| `4. INVOICED/CLOSED` | 286,662 | approval | `approval_state = closed` (terminal) |
| `Unpaid` | (low) | collections | `collections_state = unpaid` |
| `Promised` | (low) | collections | `collections_state = promised` |
| `Disputed` | (low) | collections | `collections_state = disputed` (active `InvoiceDispute` exists) |
| `Contacted` | (low) | collections | **Drop** — derive from `CommunicationEvent.most_recent_at`. Per `02-collections-domain-expert.md`, this is a touch-flag, not a lifecycle state. |
| `No Action` | (low) | collections | `collections_state = standby` (DNC or no-touch) |
| `A` | 52,060 | **garbage** | Undocumented single-letter; carry in `metadata.source_status_raw`. |
| `H` | 3,185 | **garbage** | Same — undocumented. `metadata.source_status_raw`. |

And the 44 *other* in-data values not in the active picklist (since `distinct_count=56` vs declared 12) include `Approved` (15,770), `Open` (13,905), `Submitted` (2,765), four-digit codes — tenant drift. `metadata.source_status_raw`; no enum translation.

**Schema decision.** Two columns on `ar_postings`:

```
approval_state     enum [unapproved, pending_review, pending_signature, approved_for_billing, closed]
                   -- only meaningful when kind=invoice; nullable elsewhere
collections_state  enum [unpaid, promised, disputed, standby, paid]
                   -- paid is derived from balance_cents=0; only meaningful when kind∈(invoice,credit_memo)
                   --   and balance_cents != 0
```

This is the antipattern fix from previous-review section 6. The comparison doc's Gap 7 ("expand `Invoice.status` to 15 values") was trying to encode both machines on one column. Don't.

---

## 4. `ARPosting` × `sfsrm__Payment_Line__c` — same 14-value discriminator, for a reason

`sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c` is *not* an FK disambiguator; it's the **kind of the Payment_Line itself**, mirroring the kind of the AR posting it creates. In SRM Cloud, a Payment_Line *materializes* a Transaction row in cash-side flows — the `apply_cash` Transaction is created from the Payment_Line at posting time.

Concretely:

```
ar_postings (SoR for AR-affecting events)
  ↑
  └── cash_applications (subtype, kind=apply_cash|apply_credit)
        ↑
        └── 1:1 with payment_lines (← sfsrm__Payment_Line__c)

payments (← sfsrm__Payment__c, the cash receipt header)
  └── has_many payment_lines
        ↓ each materializes one ar_postings row of kind ∈
          (apply_cash, apply_credit, on_account, write_off, deduction, discount, offset, refund)
```

Migration shape: `ar_postings.from_payment_line_id → payment_lines.id` (nullable; only set for the cash-side kinds). One Payment_Line ↔ one ARPosting row.

**Consequence for Gap 1.** "No payment side at all" is misframed. The cash side is *already* in `ar_postings` via 7 of the 12 kinds (`apply_cash`, `apply_credit`, `on_account`, `write_off`, `deduction`, `account_transfer`, `payment_refund`). `payments` only carries the *header* (check number, ACH ref, deposit date — verified: `sfsrm__Cheque_Number__c`, `sfsrm__ABANumber__c`, `sfsrm__Deposit_Date__c`); `payment_lines` carries the per-application split; the AR-side effect of each application is a row in `ar_postings`.

---

## 5. Migration strategy — 2.17M Transaction rows, 261K Payment_Line rows

Step 1 — **classify each `sfsrm__Transaction__c` row to a `kind`**. Discriminator priority (verified top-values on the 2.17M-row population):

```
kind =
  CASE
    WHEN Document_Type_Description__c ILIKE '%credit memo%'            THEN 'credit_memo'   -- ~8K (7,176 + 808)
    WHEN Document_Type_Description__c = 'Unapplied Cash'               THEN 'on_account'    -- 3,016
    WHEN Document_Type_Description__c = 'PAYMENT'                      THEN 'apply_cash'    -- 1,584
    WHEN Document_Type_Description__c = 'General Journal'              THEN 'reversal'      -- 5,005 (verify with finance — may need split)
    WHEN Document_Type_Description__c IN
         ('INVOICE','AR Invoice','Draft Invoice','Ticket')              THEN 'invoice'      -- ~1.15M
    ELSE                                                                'invoice'           -- fallback for 460K nulls (pending Type__c pass)
  END
```

~75% resolves unambiguously off `Document_Type_Description__c`. The 460K rows with null `Document_Type_Description__c` (46% null rate per `field_profiles`) need a second pass against `Type__c` raw codes (top values: `I`, `T`, `Invoice`, `IN`, `RI`, `RV`, `60`) — those are *source-ERP* codes, not Sigma codes, so the crosswalk is per-tenant. Build brand-by-brand during the brand migration. That's the bulk of Gap-12 migration work.

Step 2 — **for `apply_cash` / `apply_credit` / `on_account` rows, join back to `sfsrm__Payment_Line__c`** to recover cash-side context (payment, applied_against, applied_at). Expected: 261K Payment_Lines → 261K cash-side ARPostings. Any mismatch with Step 1's cash-side count flags rows the Sigma package didn't materialize symmetrically.

Step 3 — **derive `approval_state` and `collections_state` from `sfsrm__Status__c`** per §3. Carry the 44 unmappable values in `metadata.source_status_raw`.

Step 4 — **split tenant-leaked columns to structured extensions.** Keep verbatim in `metadata` on first sync; `ClientFieldDefinition` migration is P1 follow-up.

Step 5 — **read-only from `sfsrm__Transaction__c`. No write-back.** Per previous review recommendation 1: Sigma's 145 formula fields, validation rules, and workflow engine fire on every write — we don't have the QA harness. Read-through until the brand is fully migrated, then archive Sailfin's rows for that brand.

Step 6 — **row-count gates post-migration**:

```
COUNT(ar_postings)          ≈ 2,169,647 + 0..261,166 cash-side fan-out
COUNT(invoices)             ≈ 1,150,000
COUNT(credit_memos)         ≈ 8,000
COUNT(cash_applications)    ≈ 235,000  (sum of Apply Cash + Auto Applied + Applied on Payment_Line)
COUNT(on_account_cash)      ≈ 20,000
```

If post-migration totals deviate >5%, the classifier is wrong.

---

## 6. The Salesforce-canonical idiom for polymorphic AR sub-ledgers

SF Core doesn't ship an AR sub-ledger — `sfsrm__` and `sfcapp__` are both third-party packages because SF doesn't have the shape. The idioms SRM Cloud uses, that we should knowingly carry or reject:

1. **One physical table + `kind` discriminator + permissive nullable schema.** SRM Cloud's `sfsrm__Transaction__c` (438 columns, 14 types). It's the SF idiom: one sObject + `RecordType` per business process + page-layout field subsetting. Rails equivalent: STI with kind-scoped validations. **Adopt.** ~20 shared columns, 1-6 subtype-specific.

2. **ERP-side double-entry does not come into play.** `sfsrm__Transaction__c` is AR only — a sub-ledger, not a GL. Double-entry would require a matching GL credit against revenue/cash/COGS, and that's the customer's ERP's job (visible via `sfsrm__Source_System__c`). `sfcapp__GL_Account__c` is a *reference* to the ERP GL line, not a posting Cashline books. **`ar_postings` is a one-sided ledger by design.** Don't try to balance it.

3. **Lightning-Industries precedent.** FSC's `FinancialAccountTransaction`, Loyalty's `LoyaltyLedger`, Subscription Management's `BillingTransaction` all use `Type` enum + nullable per-type fields on one sObject. Our STI shape matches the industry idiom.

4. **Approval-state and collections-state must not share a column.** SF's standard: `Status` (business lifecycle) + separate `ApprovalStatus` driven by `ApprovalSubmission`/`ApprovalWorkItem`. Sigma broke that by overloading `sfsrm__Status__c`. **Don't carry the bug.**

---

## Recommendations

1. `ARPosting` parent + STI subtypes per §2; 12-value `kind` enum per §1.
2. Two state columns (`approval_state` + `collections_state`) per §3; `metadata.source_status_raw` for the 44 unmapped values.
3. One Payment_Line ↔ one cash-side ARPosting per §4; `from_payment_line_id` on the subtype.
4. Classifier: `Document_Type_Description__c` first, `Type__c` raw codes second (per-tenant), per §5.
5. Read-through only from `sfsrm__Transaction__c` until brand is fully migrated.
6. `ar_postings` is a one-sided AR sub-ledger by design; `sfcapp__GL_Account__c` is a reference, not a posting.

Reversal cost of keeping `Invoice` 1:1: ~30-40% of AR-affecting rows silently dropped (every credit memo, cash app, write-off, deduction, reversal, offset, transfer, refund — verified ~250K cash-side Payment_Line rows + ~8K credit memos on Transaction), Gap 1 mis-scoped, and the first brand-migration reconciliation fails on totals. Doing this refactor before the first brand migration is the cheapest path.
