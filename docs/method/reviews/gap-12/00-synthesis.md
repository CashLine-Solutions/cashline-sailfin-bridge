# Gap 12 — `ARPosting` design synthesis

Synthesis of the five-persona panel's round-2 designs for the `ARPosting` polymorphic parent (Gap 12, P0 by reversal cost). All five reviewers worked from the round-1 synthesis and the data; each landed on the same fundamental shape with a few productive disagreements.

- [`01-salesforce-architect.md`](01-salesforce-architect.md) — source-side mapping, status state-machine split, migration classifier
- [`02-collections-domain-expert.md`](02-collections-domain-expert.md) — per-kind operational semantics, cash-app worklist, GL impact, end-to-end scenario
- [`03-data-architect.md`](03-data-architect.md) — Rails STI inheritance, signed-amount, state-transition log, identity & uniqueness, validation invariants
- [`04-analytics-engineer.md`](04-analytics-engineer.md) — empirical sizing, currency/date/status field allocation, missing `Ticket` subtype
- [`05-general-data-analyst.md`](05-general-data-analyst.md) — cross-cutting cascades, tenant leakage, data-quality landmines, "what if we don't" inventory

---

## Convergent design (all five reviewers)

1. **STI on a single `ar_postings` table.** Rails `type` discriminator. Subclasses for each kind (`Invoice < ARPosting`, `CreditMemo < ARPosting`, etc.). The data architect (`03-data-architect.md` §"Winner: STI") and Salesforce architect (`01-salesforce-architect.md` §6) both argue this independently; the analytics engineer's sizing confirms a shared-core/sparse-tail field distribution that STI handles naturally; the general analyst's audit walk-through is impossible under the `subject_type/subject_id` alternative.

2. **`signed_amount_cents` lives on the parent.** Signed integer, no `>= 0` validation. Customer balance becomes `SELECT SUM(signed_amount_cents) FROM ar_postings WHERE customer_account_id = ?` — closed-form. The polymorphic shape is what unlocks Gap 14 (the multi-currency/signed gap from round 1).

3. **Two state machines, not one.** `approval_state` and `collections_state` as separate enums. Sigma overloaded `sfsrm__Status__c` with both; carrying that bug is the antipattern Gap 7 was groping at (`01-salesforce-architect.md` §3, `03-data-architect.md` §"State machine"). Per-subtype status enums share an integer column; the existing `invoice_status_events` table generalizes to a polymorphic `ar_posting_status_events` log.

4. **Source identity at parent level.** `source_system + source_external_id + source_updated_at + last_synced_at` all on `ar_postings`. Every kind is sync-able; every kind needs the same identity lattice.

5. **No write-back to `sfsrm__Transaction__c`.** Read-through during brand migration; archive Sailfin's per-brand rows after cutover. The vendor's 145 formula fields and validation rules fire on every write — we don't have the QA harness (`01-salesforce-architect.md` §5).

6. **The discriminator lives on the child, not the parent.** `sfsrm__Transaction__c.sfsrm__Transaction_Type__c` is **100% null in production** (`04-analytics-engineer.md` §"Sizing", `05-general-data-analyst.md` Landmine 5). The 14-value enum we want lives on `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`. Migration classifier must derive `kind` from `Document_Type_Description__c` (151 distinct, ungoverned) + per-tenant `Type__c` crosswalk (raw ERP codes: `I`, `IN`, `RI`, `RV`, `60`).

---

## The 12-value kind enum (with two safe collapses from the 14)

| `kind` | Source values collapsed in | Sign | Subtype payload |
|---|---|---|---|
| `invoice` | `INVOICE` / `AR Invoice` / `Draft Invoice` / `Ticket` from `Document_Type_Description__c` | + | `invoice_number`, `issue_date`, `due_date`, `subtotal_cents`, `tax_cents`, `total_cents`, `balance_due_cents`, `purchase_order_number`, `payment_terms_*`, denorms |
| `credit_memo` | `Credit Memo` / `CREDIT MEMO` | − | `credit_memo_number`, `linked_invoice_id` (nullable; rebuild per-brand from free-text `Credit_Memo_Reference__c`) |
| `on_account` | `Unapplied Cash` / `On Account` | − | `received_via` enum, `bank_reference`, future `payment_id` |
| `apply_cash` | `Apply Cash` + `Auto Applied` + `Applied` *(provenance collapse, `auto_applied:boolean` flag)* | − | `applied_against_id` (→ `ar_postings.id`), `payment_id`, `applied_at` |
| `apply_credit` | `Applied Credit` | − | `applied_against_id` |
| `write_off` | `Write Off` | − | `write_off_reason_code`, `write_off_authority_user_id` *(seg-of-duties: must differ from `created_by_user_id`)*, `gl_account_ref` |
| `write_back` | `Write Back` | + | `writes_back_id` (→ original `write_off`) |
| `reversal` | `Reversal` | opposite of original | `original_ar_posting_id` *(required; partial unique)*, `reversal_reason_code` |
| `offset` | `Offset` | by direction | `offsets_posting_id` |
| `deduction` | `Deduction` | − | `deduction_reason_code` (48 active values from `sfcapp__Deduction_Reason_Code__c`), `deduction_type` |
| `discount` | `Discount` | − | `discount_type` enum *(Earned / Unearned / Forced / Zeroed — see Gap 16)*, `applied_to_invoice_id` |
| `account_transfer` | `Account to Account Transfer` | row pair sums to 0 | `transfer_group_uuid`, `direction` |
| `payment_refund` | `Payment Refund` | + | `refunded_to_payment_id` |

The Salesforce architect collapses `Auto Applied` / `Applied` / `Apply Cash` into a single `apply_cash` kind with an `auto_applied` provenance flag. The collections domain expert preserves the distinction operationally but agrees the storage shape can be one row — the boolean carries enough signal for the worklist UI.

### Productive disagreements

1. **Missing 13th subtype: `Ticket`?** The analytics engineer flags 299,935 rows where `Document_Type_Description__c = 'Ticket'` (oil & gas field-service jobs that become invoices). The Salesforce architect treats Tickets as a subtype of `invoice` (same shape, different downstream lifecycle). The collections expert is neutral. **Resolution to confirm**: model as `Invoice.invoice_kind` enum (`standard / ticket / draft / ar_invoice`) rather than a top-level `ARPosting` subtype — same parent shape, no new STI class.

2. **`AccountTransfer` — one row or two?** The data architect proposes one row with `direction` field; the Salesforce architect proposes a paired row (debit side + credit side) with `transfer_group_uuid` summing to zero. The paired-row shape gives clean `SUM(signed_amount_cents)` semantics on both customers' accounts simultaneously. **Resolution**: paired rows. Cheaper to query, mirrors how the source models it via `sfsrm__Transferred_To__c` self-ref.

3. **Missing kinds beyond the 14?** The general analyst suggests `debit_memo` and `finance_charge`. The Salesforce architect notes neither is in Sigma's enum — they'd materialize as `Invoice` rows with a kind flag. **Resolution**: defer until a Client actually books them.

---

## Field allocation (parent vs. subtype)

Parent (`ar_postings`, ~25 columns) — applies to every kind:

```
id, type (Rails STI discriminator), operator_id, client_group_id, customer_account_id,
posting_number (← sfsrm__Transaction_Key__c, external id),
posted_at, effective_date, closed_at,
signed_amount_cents, currency_iso, fx_rate_to_base, fx_rate_as_of,
approval_state, collections_state, status_changed_at,
source_system, source_external_id, source_system_kind, source_document_type, source_updated_at,
last_synced_at, imported_from_sync_run_id,
field_provenance jsonb, metadata jsonb,
created_by_user_id, discarded_at, created_at, updated_at
```

Subtype tables hold kind-specific columns per the table above. Associations stay where they semantically belong:

- `line_items`, `attachments`, `submissions`, `disputes`, `payment_promises` → `Invoice` (subtype-only)
- `state_transitions` → `ARPosting` (parent, polymorphic)
- `audited` → per-subtype (Rails STI default)

What does NOT migrate:
- **145 formula fields on `sfsrm__Transaction__c`** — Sigma recomputes; we recompute on our side
- **64 overlapping date columns** — collapse to one `expected_payment_at` per kind; alternates to `metadata` for one quarter, then drop
- **31 Viking_* + 27 Corrpro_* + Alpine + Casey_Sprayberry + 6 French-labeled fields** — to `ClientFieldDefinition + ClientFieldValue` (Gap 15.5)

---

## State, identity, validation

### State

- `ar_postings.status` is a polymorphic integer column. Per-subtype enum mappings on `Invoice`, `CreditMemo`, etc.; integer values may overlap (e.g., `0` is `draft` on Invoice, `proposed` on Reversal). Cross-subtype reporting uses `(type, status)` as composite category.
- `approval_state` (Invoice-only, nullable elsewhere): `unapproved → pending_review → pending_signature → approved_for_billing → closed`
- `collections_state` (Invoice + CreditMemo, when `balance_cents != 0`): `unpaid / promised / disputed / standby / paid`
- The "Contacted" status from `sfsrm__Status__c` is **derived**, not stored — comes from `CommunicationEvent.most_recent_at` (collections expert from round 1 + Salesforce architect this round agree).
- Rename existing `invoice_status_events` → `ar_posting_status_events`; generalize FK to polymorphic `ar_posting_type / ar_posting_id`. One migration, ~30 LOC.

### Identity (per-subtype natural keys as partial unique indexes)

```sql
CREATE UNIQUE INDEX idx_ar_postings_invoice_natural_key
  ON ar_postings (client_group_id, invoice_number)
  WHERE type = 'Invoice' AND discarded_at IS NULL AND invoice_number IS NOT NULL;

CREATE UNIQUE INDEX idx_ar_postings_credit_memo_natural_key
  ON ar_postings (client_group_id, credit_memo_number)
  WHERE type = 'CreditMemo' AND discarded_at IS NULL;

CREATE UNIQUE INDEX idx_ar_postings_reversal_uniqueness
  ON ar_postings (original_ar_posting_id)
  WHERE type = 'Reversal' AND discarded_at IS NULL;

CREATE UNIQUE INDEX idx_ar_postings_source_identity
  ON ar_postings (source_system, source_external_id)
  WHERE discarded_at IS NULL;
```

### Validation invariants (per-subtype)

- **`Reversal`** — `original_ar_posting_id` required; original must share `customer_account_id` and `currency_iso`; original cannot be a `Reversal` itself (use `WriteBack`); `signed_amount_cents == -1 * original.signed_amount_cents`; original's `status` transitions to `reversed`.
- **`CreditMemo`** — `linked_invoice_id` nullable but if set must be an `Invoice` on the same `customer_account_id`; `signed_amount_cents < 0`.
- **`OnAccountCash`** — `customer_account_id`, `received_via`, `bank_reference` all required; `signed_amount_cents < 0`.
- **`WriteOff`** — `write_off_authority_user_id` required and must differ from `created_by_user_id` (segregation of duties).
- **`Offset` / `AppliedCredit`** — `applied_to_ar_posting_id` required; pair shares customer account + currency.
- **`AccountTransfer`** — row pair must share `operator_id`; sum to zero.
- **Cross-cutting** — a soft-deleted `ARPosting` cannot be the target of `original_ar_posting_id` / `applied_to_ar_posting_id` from a live posting (soft-delete propagation through the FK graph).

---

## Migration — mechanical because the table is empty

Zero `Invoice` rows in production. Single deploy:

1. Rename `invoices → ar_postings`. Add `type` defaulting to `'Invoice'`. Add `signed_amount_cents` populated from `total_cents`.
2. Add nullable subtype-specific columns (the 14 from the table above).
3. Rename `invoice_status_events → ar_posting_status_events`; generalize FK to polymorphic.
4. `class Invoice < ApplicationRecord` becomes `class Invoice < ARPosting`. Associations stay. Validations stay. Enum stays.
5. Add skeletal subclasses: `CreditMemo < ARPosting`, `OnAccountCash < ARPosting`, `Reversal < ARPosting`, etc.
6. Existing FKs (`invoice_line_items.invoice_id` etc.) re-target `ar_postings.id` post-rename — Postgres handles atomically.

**Hard deadline**: before the first real Sailfin sync (comparison doc Decision 5). After that, this becomes a multi-week migration with data-loss risk.

### Brand-by-brand classifier (the actual work)

The mechanical Rails migration is the easy part. The classifier is the bulk of the work:

```sql
kind =
  CASE
    WHEN Document_Type_Description__c ILIKE '%credit memo%'  THEN 'credit_memo'      -- ~8K rows
    WHEN Document_Type_Description__c = 'Unapplied Cash'     THEN 'on_account'       -- 3K
    WHEN Document_Type_Description__c = 'PAYMENT'            THEN 'apply_cash'       -- 1.5K
    WHEN Document_Type_Description__c = 'General Journal'    THEN 'reversal'         -- 5K *(confirm with finance)*
    WHEN Document_Type_Description__c IN
         ('INVOICE','AR Invoice','Draft Invoice','Ticket')   THEN 'invoice'          -- ~1.15M
    ELSE                                                          'invoice'          -- fallback for 460K nulls
                                                                                     -- pending Type__c per-tenant pass
  END
```

~75% resolves off `Document_Type_Description__c`; the 460K null rows need a per-tenant crosswalk against raw ERP codes in `Type__c`. The crosswalk is the deliverable for each brand migration.

### Post-migration row-count gates

| Table | Expected | Source |
|---|---:|---|
| `ar_postings` | 2.17M + ≤261K cash-side fan-out | `sfsrm__Transaction__c` + `sfsrm__Payment_Line__c` |
| `Invoice` rows | ~1.15M | `Document_Type ∈ (INVOICE, AR Invoice, Draft, Ticket)` |
| `CreditMemo` rows | ~8K | `Document_Type ILIKE '%credit memo%'` |
| `cash_applications` (apply_cash + apply_credit) | ~235K | `Payment_Line.Transaction_Type ∈ (Apply Cash, Auto Applied, Applied, Applied Credit)` |
| `on_account_cash` | ~20K | `Payment_Line.Transaction_Type = On Account` |

Deviation > 5% means the classifier is wrong.

---

## Cascades into other gaps

| Gap | How `ARPosting` changes the work |
|---|---|
| Gap 1 (no payment side) | **Re-framed**: cash side is already in `ar_postings` via 7 kinds (`apply_cash`, `apply_credit`, `on_account`, `write_off`, `deduction`, `account_transfer`, `payment_refund`). `Payment` is just the cash-receipt header; `PaymentAllocation` collapses into the `apply_cash` subtype's `applied_against_id`. |
| Gap 13 (PII classifier) | No interaction — already fixed. |
| Gap 14 (multi-currency/signed) | **Resolved**: `signed_amount_cents` + `currency_iso` + `fx_rate_to_base` + `fx_rate_as_of` on parent. Customer balance is one closed-form query. |
| Gap 15.1 (soft-delete) | `discarded_at` on parent; all subtypes inherit. |
| Gap 15.2 (state-transition log) | `ar_posting_status_events` polymorphic; one log across all subtypes. |
| Gap 15.3 (field-provenance) | `field_provenance jsonb` on parent; keys include subtype path implicitly. |
| Gap 15.5 (`ClientFieldDefinition`) | 60+ tenant-leaked fields (Viking, Corrpro, Alpine, Casey, French) move here per-subtype. |
| Gap 16 (missing operational entities) | `discount_type` enum (Earned/Unearned/Forced/Zeroed) lives on the `discount` subtype; `CreditHold` and `Statement` still need their own tables. |

---

## "What if we don't" — concrete breakage from keeping 1:1 Invoice mapping

From `05-general-data-analyst.md`:

- **~8K credit memos silently dropped** (only 808+7,176 rows but every one is a real tax/audit obligation)
- **~236K Payment_Line apply rows orphaned** — Payment_Line will have a `transaction_id` pointing to nothing in our schema
- **5K Reversals lost** — finance team's "undo cash app" path becomes inoperative
- **~20K on-account cash rows mis-classified** as paid invoices, inflating customer balances by the on-account total
- **AR aging diverges from finance's books on day 1** — first reconciliation report fails

Aggregate: ~270K rows of AR-affecting state lost or mis-classified. Reversal cost compounds with every brand migration after the first.

---

## Data-quality landmines for the migration runbook

From the analytics engineer + general analyst:

1. **`Invoice_Amount__c` is a string** (data_type=string, not currency). Plus it's a formula. The real signed amount comes from `sfsrm__Amount__c` (currency, 100% populated).
2. **Date sentinels span 1753-01-01 to 3623-09-08.** SQL Server datetime min as "unset" sentinel; one typo'd 3623. Add Postgres CHECK constraint `posted_at BETWEEN '1990-01-01' AND '2100-01-01'`.
3. **Two `PO_Number` fields on Transaction.** `PO_Number__c` (Cashline custom) vs `sfsrm__Po_Number__c` (managed-package). Choose one per-brand at ingest.
4. **`Document_Type_Description__c` has 151 distinct ungoverned free-text values** but is the load-bearing classifier discriminator. Build the per-tenant crosswalk before brand migration runs.
5. **`sfsrm__Amount__c` has a $4.8 billion max** — likely a sentinel or formula overflow. Bound-check + reject at ingest.
6. **The `Transaction_Type__c` discriminator that we want is on `Payment_Line`, not `Transaction`.** The Transaction-side field with the same name is 100% null. Don't read it.

---

## Recommended next moves

In priority order:

1. **This sprint**: rename `invoices → ar_postings`, add `type` column + signed amount + the polymorphic state log. Land the skeletal subclasses. Single PR.
2. **Before first brand migration**: write the `Document_Type_Description__c` + `Type__c` per-tenant classifier for that brand. Land row-count gates.
3. **Block on first Sailfin sync**: no sync until ARPosting is shipped + brand classifier is approved by finance.
4. **Defer until needed**: `debit_memo` / `finance_charge` kinds, the `ar_posting_reversal_details` sidecar.

The reversal cost of waiting: ~270K AR-affecting rows lost per brand migration. The deadline is the first real Sailfin sync.
