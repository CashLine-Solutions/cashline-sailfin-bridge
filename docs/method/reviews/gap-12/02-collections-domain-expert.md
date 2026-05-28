# `ARPosting` — operational design lens

Reviewer: senior collections / receivables domain expert (carry-over from [`../02-collections-domain-expert.md`](../02-collections-domain-expert.md)). The Salesforce architect owns the schema/discriminator mechanics; the data architect owns the polymorphism pattern; my job is what each posting type *means in the AR workflow* and how the cash-app desk and collector seat will interact with it. Follow-up to P0 in [`../00-synthesis.md`](../00-synthesis.md): `sfsrm__Transaction__c` is polymorphic AR posting, not Invoice. Source: run_id=9, picklists queried from `spicklist_values`; the 14 values cited below are verbatim from `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`.

Carry-over rule: **one shared `reason_code` controlled vocabulary** across Dispute, Deduction, and `ARPosting` (Sailfin has three separate enums; copying that locks in two years of reconciliation work). Plus a `discount_type` enum (4 Sailfin values: `Earned / Unearned / Forced / Zeroed`) required only when `kind = discount`.

---

## The 14 `transaction_type` values — what each one means in the seat

Not "categories" — *operational states* with distinct creators, triggers, GL impact, and downstream worklist behavior. Walked in the order a collector or cash-app analyst encounters them.

### 1. `Invoice`

Receivables-creating posting (DR AR / CR Revenue + Sales Tax). Created by the Client ERP or operator's invoice flow; lands via ingestion. The *only* kind that carries a full set of invoice fields (number, PO, due date, terms, line items, attachments, original amount, balance due). Every other kind either references an Invoice or stands alone on the customer account. Downstream: enters the dunning calendar, ages through buckets, eligible for promise and dispute. The only `ARPosting` row a collector "calls about."

### 2. `Credit Memo`

Receivables-reducing posting against a specific Invoice (DR Sales Returns / CR AR). Created by an authorized AR user as the resolution of a dispute or as a billing concession. Carries `parent_invoice_id` and `reason_code` (Pricing / Damaged Product / Shortage / Billing Correction / Promotional — same vocabulary as Dispute). Two variants the model must distinguish: **applied credit memo** (immediately reduces the named invoice's balance) vs **open credit memo** (sits on the customer account waiting to be applied — see `Applied Credit`). Approval workflow above collector authority. Where 60-70% of substantive disputes end.

### 3. `On Account`

Cash received with no invoice match — sits on the customer account as a liability (DR Cash / CR Customer Deposit-On-Account). Created by the cash-app analyst when remittance is identifiable to a customer but not to an invoice. Carries `customer_account_id`; `parent_invoice_id` is null. Critical to represent distinctly from `Unapplied` (header-level state) and `Unidentified` (no customer match): On-Account is a *deliberate* decision to park the money, not an unresolved cash-app state. Feeds the On-Account worklist queue; collector sees the credit during dunning calls; converts to `Applied Credit` once the customer directs application. Pretending these don't exist is the single biggest reason customers say "we already paid that."

### 4. `Apply Cash`

The *act* of applying cash to an invoice (DR Cash / CR AR-specific-invoice). Human-driven counterpart to `Auto Applied`. Carries `parent_invoice_id` + `payment_id`. Distinguishing this from `Auto Applied` is load-bearing because it measures **cash-app desk effort** (hours-per-invoice input) and feeds the matching-engine training set. Reduces invoice balance; transitions invoice to `paid` or `partially_paid`. The desk's bread-and-butter row — 100-500/day at a mid-market shop.

### 5. `Auto Applied`

Engine-created counterpart of `Apply Cash`. Same GL impact, same FKs, distinct kind because **the desk does not want to re-review engine-created applications** — they filter these out and only see human-created or exception rows. Created by the auto-match engine when remittance carries a clean invoice number matching an open invoice for the identified customer. The "what fraction of incoming cash auto-applies cleanly" KPI is `Auto Applied` count / total allocations per payment.

### 6. `Applied Credit`

An open credit memo or On-Account balance applied to a specific invoice (DR Customer Credit-On-Account / CR AR-specific-invoice). Created when the customer directs ("apply $5K of our open credit to Invoice 12345"). Carries `parent_invoice_id` + `source_credit_posting_id` (the credit or On-Account row being consumed). Distinct from `Apply Cash` because **no new cash entered** — it's a reshuffling on the customer's books. Very common right after a dispute resolves with a credit memo.

### 7. `Deduction`

The cash-app finding that "customer paid $9,500 on $10,000 and coded the $500 difference as `Shortage`." Distinct from short-pay-without-explanation (which becomes Unapplied). Created by the cash-app analyst or remittance parser. Carries `parent_invoice_id`, `payment_id`, `amount` (the short amount), `reason_code` (one of 48 `sfcapp__Deduction_Reason_Code__c` values, collapsed to ~12), and `deduction_type` (Sailfin's 3 values: `Credit Memo` / `Deduction` / `Dispute` — "becomes a credit memo on research" / "stays as a deduction to recover" / "escalates to a dispute"). GL impact is **suspense**, not write-off. Spawns `OperationalTask{deduction_research}` with SLA clock; resolves to a `Credit Memo`, `Write Off`, or `Dispute` escalation. Deduction rate is a top-three KPI; without this row, you can't measure it.

### 8. `Discount`

The cash-app finding that customer took an early-pay discount. Carries `parent_invoice_id`, `payment_id`, `amount`, and a **mandatory** `discount_type` (Sailfin's 4 values: `Earned / Unearned / Forced / Zeroed`). Four distinct downstream behaviors — full detail in "Discount semantics" section below. The most operationally important picklist nobody on a generalist team would notice (carry-over from prior review).

### 9. `Write Off`

Bad-debt recognition (DR Bad Debt Expense / CR AR). Created by a collections manager or credit committee — *not* a collector unilaterally; tiered approval thresholds. Carries `parent_invoice_id`, `reason_code` (Bad Debt / Customer Bankruptcy / Small Balance / Statute of Limitations), `authorized_by_user_id`. **Permanent expense** — hits the P&L. Distinct from `Reversal` (no expense) and `Credit Memo` (contra-revenue, different P&L line). Sailfin's `KEY US DIRECT WRITE OFF - INV` vs `- Rcpt` reason codes encode two paths: invoice-level (`parent_invoice_id` populated) and receipt-level (against the cash receipt when the invoice can't be identified). Recommend two kinds (`write_off_invoice` / `write_off_receipt`). Closes invoice as `written_off` (not `void`); feeds credit decisions.

### 10. `Write Back`

Reversal of a prior write-off because the customer eventually paid (DR AR / CR Bad Debt Recovery — recovery to the expense account, sometimes a separate revenue account). Rare but operationally critical. Created by the cash-app analyst when cash arrives referencing a previously written-off invoice. Carries `parent_invoice_id` + `original_writeoff_posting_id`. Reinstates the receivable; a subsequent `Apply Cash` clears it (two rows, not one). Re-opens the invoice in reporting; bad-debt recovery hits the P&L; updates the customer's Cashline-Score signal positively.

### 11. `Reversal`

Undoing an erroneous prior `ARPosting` row. Distinct from `Write Back` (intentional re-recognition) and `Write Off` (recognizing bad debt). Created by a cash-app analyst or supervisor when an earlier application was wrong (wrong invoice, wrong customer, posted twice). Carries `reverses_posting_id` and inherits the original's amount with opposite sign. Critical: the model must **never delete** an `ARPosting` row; corrections are always new reversal rows. Non-negotiable for audit; the single biggest reason non-AR engineers get this wrong (they reach for `DELETE`). Supervisor co-sign typical; reversal count per analyst is a quality metric.

### 12. `Offset`

Net an AR balance against an AP balance with the same counterparty — customer is also a supplier, settled by netting (DR AP-supplier / CR AR-customer). Created by the AP/AR reconciliation function (controller-level), not by collectors. Carries `parent_invoice_id` and an external reference to the AP system (Cashline likely doesn't model AP — string field or `metadata`). **No cash moves.** Closes invoice as paid, flagged "paid by offset." Rare at frequency but load-bearing for any customer who is also a supplier (oil & gas, construction, manufacturing).

### 13. `Account to Account Transfer`

Move an On-Account credit between two customer accounts — most commonly **parent-pay**: Chevron-Houston has $80K On Account, parent Chevron Corporation has unpaid invoices, treasury says "use the Houston credit." Created by the cash-app analyst with explicit customer authorization (otherwise it's misapplication). Carries `source_customer_account_id` + `destination_customer_account_id` + `amount`. **No GL change at company level** — only the customer-level subledgers move. Collapsing into `Applied Credit` loses the source-customer audit trail. This is *the* reason `Customer::Organization.pays_through_organization_id` (treasury) needs to be a separate FK from `parent_organization_id` (org chart) — carry-over from prior review. Parent-pay customers see this monthly.

### 14. `Payment Refund`

Money flowing **out** — we owe the customer, from overpayment or a completed chargeback (DR Customer Credit-On-Account / CR Cash). Created by AR/Treasury, requires approval. Carries `customer_account_id` + `source_credit_posting_id` + `refund_method`. **Cash going out** — the only kind other than offsets where cash leaves. Distinct from Account-to-Account Transfer (no cash) and Write Off (expense, no cash). Spawns treasury task; on issuance, the credit balance zeroes. Where the worst customer experience lives — refunds take weeks at most B2B shops, and collectors absorb the rage during the wait.

---

## Cash-app worklist queues and `ARPosting` ↔ `Payment` interaction

Three queues drive the desk — these are not `ARPosting` kinds but `Payment` *header* states (the 8 values of `sfsrm__Payment_Status2__c`):

- **Unidentified Payment queue** — `Payment.status = unidentified`. Cash arrived; no customer known. No `ARPosting` rows yet. SLA: same-day. Analyst identifies the customer via remittance lookup / bank ref / phone.
- **Unapplied Payment queue** — `Payment.status = unapplied` (or *Partially Paid* for residuals). Customer identified, no invoice match. Analyst either (1) gets remittance detail and creates `Apply Cash` / `Auto Applied` / `Applied Credit` / `Deduction` / `Discount` rows, or (2) parks as `On Account`. SLA: typically 3-5 business days before On-Account is the default disposition.
- **On Account queue** — visible per-customer. Lists every customer with non-zero On-Account balance. Collectors work this *during dunning calls* — "you have a $50K credit from June; apply to invoices 1234, 1235, 1236?" Creates `Applied Credit` rows on resolution.

Model interaction: `Payment` is the cash-receipt header (one row per deposit / wire / check); `ARPosting` rows are the subledger postings (one or many per `Payment` once allocations are made). A `Payment` with no consuming `ARPosting` rows is Unapplied; with rows that don't sum to the payment amount is partially-applied — residual auto-creates `On Account` (if policy is "park") or stays Unapplied (if "research"). Client-configurable.

`PaymentAllocation` is **redundant** if every `ARPosting` row that consumes payment carries `payment_id` directly. Recommend collapsing it: `ARPosting.payment_id` nullable, populated for `apply_cash / auto_applied / applied_credit / deduction / discount / payment_refund`. Saves a table; data architect to rule.

---

## GL impact — keeping `Write Off` / `Write Back` / `Reversal` / `Account-to-Account Transfer` distinct

Non-AR people conflate these. Each hits a different GL account and a different audit-attestation surface.

| Kind | DR | CR | Hits P&L? | Approval |
|---|---|---|---|---|
| `Write Off` | Bad Debt Expense | AR | Yes (expense) | Manager / credit committee |
| `Write Back` | AR | Bad Debt Recovery | Yes (recovery) | Cash-app analyst |
| `Reversal` | Mirror of original | Mirror of original | Net zero over the pair | Supervisor co-sign |
| `Account to Account Transfer` | Customer-A Subledger | Customer-B Subledger | No (subledger only) | Customer must authorize |

Three model implications: **(1)** `Write Off` and `Write Back` reference `parent_invoice_id` for invoice-level GL traceability (SOX/SOC). Plus two write-off variants per the `Write Off` paragraph above. **(2)** `Reversal` carries `reverses_posting_id`, not `parent_invoice_id` — inherits invoice via the FK chain. Audit chain stays explicit; no orphan reversals; never DELETE. **(3)** `Account to Account Transfer` is the only kind that doesn't update an invoice balance — it updates customer-subledger balances. The discriminator design must allow `parent_invoice_id = null` for this kind without firing orphan-posting warnings.

---

## Discount semantics — Earned / Unearned / Forced / Zeroed on `ARPosting`

`ARPosting` kind `= discount` + mandatory `discount_type` enum (4 values):

- **`Earned`** — auto-posted by the engine when remittance arrives within the discount window. No approval. Contra-revenue (DR Sales Discount).
- **`Unearned`** — posted when remittance arrives *after* the window but customer still deducted. Spawns `OperationalTask{unearned_discount_recovery}`; collector contacts customer; if recovery fails after N attempts, converts to `Write Off` (small balance) or escalates to a `Dispute`. Unearned-Discount rate is one of the cleanest measures of payment-terms abuse — watched at credit review.
- **`Forced`** — posted by an authorized AR user with approval as a post-hoc concession. Carries `authorized_by_user_id` + `concession_reason`.
- **`Zeroed`** — small residual write-off via the discount channel ($3 left on $10K). Avoids bad-debt expense for trivial amounts. Tolerance-band is client-configurable.

Rule: `discount_type` is **required when `kind = discount`, forbidden otherwise** (model-level validation). The four downstream behaviors must each be implemented; collapsing reproduces the SFSRM bug where shops can't measure unearned-discount leakage.

---

## `Deduction` ↔ `Dispute` interaction via `ARPosting`

The lifecycle where the cash-app desk hands off to collections.

1. **Deduction at remittance.** Cash short with a coded reason. Analyst creates `ARPosting{kind=deduction, parent_invoice_id, payment_id, amount, reason_code}` + sibling `apply_cash` for the paid portion. Invoice → `short_paid`.
2. **Research.** Deduction spawns `OperationalTask{deduction_research}` (SLA: typical 30d substantive / 5d trivial).
3. **Decision** — four outcomes:
   - **We agree** → `ARPosting{kind=credit_memo}`; deduction's `resolved_by_posting_id` points to it; invoice usually → `paid`.
   - **We disagree, small enough to absorb** → `ARPosting{kind=write_off, reason_code=Small Balance}`; P&L hit.
   - **We disagree, substantive** → promote to `InvoiceDispute{reason_code=<from deduction>, triggering_ar_posting_id=<deduction>}`; deduction marked `under_dispute`; dispute drives workflow.
   - **Chargeback (credit card)** — different lifecycle: `OperationalTask{chargeback}` with merchant-gateway response window; outcome is `Write Off` (we lose) or `Reversal` + recovery posting.

Rule: **the `Deduction` row is never deleted or updated to resolved** — terminal in its kind; a *separate* `ARPosting` row carries the resolution; `resolved_by_posting_id` on the deduction points to the resolver. Preserves the deduction → resolution audit chain — the single most-audited workflow in mid-market AR.

---

## Operational scenario walked end-to-end

**Setup.** INV-1001 for $10,000 to Chevron-Houston, net 30, issued 2026-03-01.

**Day 40.** Chevron remits $9,500 coded "Shortage - damaged units." Cash-app creates `Payment{P-501, $9,500, status=partially_paid}` plus two `ARPosting` rows (apply_cash + deduction). Invoice → `short_paid` (Gap 7 new state); deduction spawns `OperationalTask{deduction_research, SLA=30d}`.

**Day 45 — Research.** Collector finds customer is partly right: $300 valid shortage, $200 invalid counting error. Collector creates the $300 credit memo (within authority); manager authorizes the $200 small-balance write-off.

**Final `ARPosting` ledger for INV-1001:**

| id | kind | parent_invoice | amount | reason_code | payment | resolves |
|---:|---|---|---:|---|---|---:|
| 1 | invoice | self | +$10,000 | — | — | — |
| 2 | apply_cash | 1 | −$9,500 | — | P-501 | — |
| 3 | deduction | 1 | −$500 | Shortage | P-501 | — |
| 4 | credit_memo | 1 | −$300 | Damaged Product | — | 3 |
| 5 | write_off | 1 | −$200 | Small Balance | — | 3 |

Sum: $10,000 − $9,500 − $300 − $200 = $0 ✓. GL: AR DR $10,000 cleared by $9,500 cash + $300 sales returns + $200 bad-debt expense. Invoice → `paid`. Row 3 is never mutated; its `resolved_by_posting_ids` references rows 4 and 5.

**Contrast with the stub-Payment design** (Decision #1 default — one Payment row with `invoice_id=1`, `amount=$9,500`): the $500 short-pay is invisible, the deduction reason code is invisible, the split between contra-revenue ($300) and bad-debt expense ($200) is invisible, the audit chain is missing, the deduction-rate KPI is uncomputable. Five rows tell the story; one row hides it.

---

## Operator UI surfaces

Three: **(1) Per-invoice posting timeline** — every `ARPosting` row touching an invoice, chronological, with kind + amount + reason + author. **(2) Cash-app worklist** — three queues (Unidentified / Unapplied / On Account) driven by `Payment.status` + `Customer::Account.on_account_balance`, filterable by SLA breach. **(3) Deduction research queue** — `ARPosting{kind=deduction, resolved_by_posting_id IS NULL}`, grouped by reason code, sorted by age. The single most-watched queue at a B2B AR shop. Collector seat lives in (1); cash-app desk lives in (2) and (3).
