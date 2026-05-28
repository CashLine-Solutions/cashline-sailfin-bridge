# Collections / receivables domain expert review

Reviewer: senior AR / collections operator (15+ years mid-market and enterprise B2B). My job here is to put words to what the Sailfin picklist values *mean in the seat*, and to call out where the cashline-platform ontology has either compressed real workflow distinctions or skipped them entirely. Source: `extraction_run_id=9`, paired with `sailfin-cluster-map.md`, `cashline-platform-ontology-comparison.md`, `sailfin-eda-2026-05-27.md`.

---

## Headline (what the team is missing operationally)

- **The cash-app gap (Gap 1) is bigger than "no Payment model."** Sailfin encodes ~140 distinct cash-side semantic states across `Payment_Line.Reason_Code` (64), `Deduction_Reason_Code` (48), `Transaction_Type` (14), `Discount_Type` (4), and `Payment_Status2` (8). The Decision #1 default ("stub Payment with `invoice_id`, `amount_cents`, `received_at`, `method`") cannot represent *Cash On Account*, *Unapplied / Unidentified Payment*, *Auto Matched vs Auto Applied*, *Earned vs Unearned vs Forced vs Zeroed discount*, *Write Back vs Write Off*, *Payment Netting*, *Account-to-Account Transfer*. These are how cash-app analysts close their day, not edge cases.
- **PaymentPromise (Gap 6) is wrong twice over.** Invoice-level *and* no first-class broken-promise behavior. Sailfin has `Is_Broken_Promise__c`, `Broken_Promise_Amount__c`, `Days_Past_Promise_Date__c`, `of_Promises_Marked__c`, `sfsrm__Promises_Risk__c`, `sfsrm__Create_Broken_Promise_Note__c` on `sfsrm__Transaction__c` because broken promises drive escalation cadence, watchlist additions, and credit-hold triggers. The platform's `open/kept/broken/canceled` enum is right at headline; the surrounding behavior (aging-bucket suspension while open, automatic broken-promise note, escalation on repeat) is absent.
- **`sfsrm__Transaction__c.sfsrm__Status__c` has 12 values; four (`A`, `H`, `Contacted`, `No Action`) are not lifecycle states — they are collector-touch flags.** Any platform that maps Sailfin status 1:1 to `Invoice.status` will mis-classify hundreds of records. The most expensive translation in the inventory.
- **Three operational entities are absent from cashline-platform — a real collections shop will recreate them as JSONB workarounds within 60 days:** (1) Credit Hold / Watchlist (Sailfin: `Account.Credit_Hold__c`, `Credit_Limit_Total__c`, `sfsrm__Amount_Over_Credit_Limit__c`, `sfsrm__Auto_Dunning_Enabled__c`); (2) Customer Hierarchy / Parent-Pay (Sailfin: `Account.ParentId`, `Parent_No__c`, `Parent_Account_Total_AR__c`); (3) Dunning Strategy / Cadence (Sailfin's `sfsrm__Treatment_Segment__c` 3×3 size × payer-quality matrix).
- **Dispute picklists encode tenant-specific operational vocabulary the "8-subtype enum, lean" treatment will lose.** `Sub_Type__c` has 70 values: ~30 real distinctions, ~20 workflow stages misfiled as types, ~10 cash-app states misfiled as disputes, ~10 duplicates / casing variants / tenant tokens. Compressing to 8 is correct as a target; the *translation table* is where the work hides.

---

## Dispute lifecycle — what the picklist values actually mean

`sfsrm__Dispute__c` carries five operationally-meaningful picklists. Walking them in the order a dispute touches them:

### `sfsrm__Status__c` (5 values) — the only real lifecycle column

`Unassigned → Assigned → Open → Closed`, with `Reopened` as the back-edge. The other Dispute picklists are classifiers, not states. `Reopened` is load-bearing — it counts recurrences, the only honest signal for "is this dispute pattern repeating." Collapsing reopens to "open with audit log" loses the metric. Keep as a distinct state.

### `sfsrm__Type__c` (28 values) — structural classification

Four real groups underneath the 28:

- **Substantive disputes:** `Job Quality`, `NPT Negotiation` (Non-Productive Time, oil & gas), `Retention`, `Pricing`, `Catalog/Price Book`, `EPD` (Early Payment Discount). Customer disagrees. Long SLA, sometimes legal.
- **Documentation disputes:** `Invoice Copy Needed`, `Invoice Requirements`, `Awaiting Signed/Approved Docs`, `Accrued/No Signature`. Customer *cannot process* the invoice — not "disagrees." Different SLA, clock is on Cashline. The Gap 5 routing rule ("Disputes block payment; Tasks are work") needs this sub-distinction.
- **Billing-error / not-really-a-dispute:** `Duplicate Inv`, `Cash Application Error`, `E-Commerce Inv Amt Error Entered`, `E-Commerce Pmt On Hold/Reversed`, `Incorrect Customer`, `Not Submitted - Ecommerce`. *Our* data errors filed as disputes because Sailfin had no other home. Should be `OperationalTask` (`invoice_exception` / `cash_application_correction`), not `InvoiceDispute`. Inflates customer-dispute KPIs if conflated.
- **Chargeback:** `Credit Card Dispute` — fundamentally different object. 60-day response window, merchant gateway as recovery path. Arguably its own `Chargeback` entity.
- **Tenant-named leakage:** `Voltyx`, `Griffin`, `Viking`, `Merit Advisors`, `Milstead` — client names in a global enum. Belong on per-Client extension.

Target enum (~8): `pricing / documentation / quality_or_service / duplicate_or_billing_error / tax / pay_when_paid_or_retention / chargeback / cash_application_correction`.

### `sfsrm__Sub_Type__c` (70 values) — the operational vocabulary

The field collectors actually filter on. Four categories:

1. **Substantive sub-types** (~30 values): `PO Issues`, `No PO/Change Order`, `Pricing Issues`, `Documentation Issues`, `Certified Payroll`, `Counter Invs`, `Wrong Quantity`, `Wrongfully Billed`, `Damaged Product`, `Wrong Customer`, `Returned`, `Warranty`, `Faulty Equipment`, `Discount Balance`, `Tax Issues`, `Service Dates`, `Retainage`, `Collectable Retainage`, `Pay when Paid`, `Need Updated COI`, `Missing Invoice`, `Insurance Issues`. The credit analyst's aggregation surface.
2. **Workflow stages masquerading as sub-types** (~20 values, move to a new `escalation_stage` enum): `Demand Letter`, `Escalated`, `Legal`, `LEGAL_CL`, `Small Claims`, `Lien`, `Closed Job - Waiver Signed`, `Waivers`, `Resubmitted`, `Pending Value Determination`, `Payment Plan`, `Mgmt - Customer Issue`, `Mgmt - Our Issue`, `MGMT - CUSTOMER ISSUE_CL`, `Waiting for Credit/Refund to be Issued`, `Waiting for Viking to Make Decision`, `Viking Pending`, `Prev Req Removal`.
3. **Cash-app values masquerading as sub-types** (~10 values, move to Payment / OperationalTask): `Cash App`, `Misapplied`, `Unapplied Payment`, `Payment Receipt Verified`, `To Be Applied`, `Credit to be Applied`, `Unidentified`, `Internal Invoice`, `Credit Card`, `CP/PW Issue`.
4. **Picklist hygiene noise** (~10 values, merge or drop): `Cash Flow / Funding Delay` vs `Cash Flow Issues` (identical, two values), `Documentation Issues` vs `Documentations Issues (Not CP/PW)` (typo'd variant), `Mgmt - Customer Issue` vs `MGMT - CUSTOMER ISSUE_CL` (casing + load-batch suffix), `Legal` vs `LEGAL_CL`, `Disputed` (vendor default — literally "disputed" as a sub-type of dispute).

Sized: ~3 person-days of mapping work paired with the data, not the "unsized workstream" the comparison doc names — but it requires a domain expert in the seat.

### `sfsrm__Reason_Code__c` on Dispute (14 values) — *why* on the customer's side

Values: `Billing`, `Damage`, `Discount`, `Promotional`, `Rebate AP accrue`, `Shortage`, `Communications`, `Supplies`, plus tenant-specific payroll/HR codes (`Accrued LIfe Insurance` [sic], `Employee HSA Ded`, `Group Insurance Deduction`, `Insurance Claims Payable` — almost certainly from a PEO/insurance client), plus accounting codes (`Offline AR Trade`, `Prepaid Expense`).

**Insight the comparison doc misses:** "reason code" in mid-market AR is the *same value* that appears on the deduction at remittance. When a customer short-pays and codes the remittance "Shortage," that same code becomes the dispute reason *and* the `sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` value (64 values, ~50% overlap with deduction codes), and feeds the chargeback/credit-memo decision. The new ontology needs **one** controlled vocabulary for `reason_code` shared across Dispute, Deduction, and PaymentAllocation. Sailfin has three separate enums; copying that locks in two years of reconciliation work.

### `sfsrm__Resolution_Code__c` (18 values) — how it closed

Target ~7 values: **Credit Memo Issued** (AR write-down, GL impact, approval threshold), **Billing Correction / Cancel & Re-Bill** (invoice re-issued; aging clock arguably resets — collectors will fight about this), **Documentation Provided** (`Attachments / Back-up`, `Signatures`, `AFE / PO /Codes Updated`, `Tax Certificate Received` — closes without monetary movement, highest-volume resolution), **Paid** (customer paid after backup; dispute unfounded), **Bad Debt Consideration**, **Withdrawn by customer** (add — not in Sailfin), **Written off** (add — terminal). Remaining Sailfin values (`Processing`, `Imported`, `Submitted`, `Operations Resolved`, `Legal Resolved`, `Insurance Claim in Process`, `Voltyx`) are workflow stages leaked into resolution, or tenant-named.

---

## Invoice lifecycle — the missing 6 states

Gap 7 names 9 current states + 5 PRD additions. Sailfin's real lifecycle is reconstructed across `sfsrm__Status__c` (12, half non-lifecycle), `Promise_Status__c`, `Is_Broken_Promise__c`, `sfsrm__Dispute_Status__c`, `Factored__c`, `Invoice_Receipt_Confirmed__c`, plus 64 date columns on `sfsrm__Transaction__c`. "9 vs 15" understates source complexity by an order of magnitude.

Six states to add, in priority order:

1. **`received`** — customer's AP has acknowledged receipt (portal scrape, read receipt, AP rep). Sailfin's `Invoice_Receipt_Confirmed__c` (YES/NO) encodes this. *Submitted but not received* after 7 days is a distinct dunning trigger from "received but not approved." Without it, the collector wastes a call asking "did you get it?" when the answer was logged a week ago.

2. **`approved_for_payment` / `scheduled_for_payment`** — AP has matched and scheduled a payment date. Dunning *must stop* the moment this is set. Highest-leverage signal from any AP portal scrape; the platform must have somewhere to put it.

3. **`short_paid`** — partial payment with explicit short-pay coding (paid $9,500 on $10K with $500 coded as `Deduction-Shortage`). Distinct from `partially_paid` ("some money came in"). Short-pay auto-creates a deduction-to-research item or a dispute. Without distinguishing, you can't measure deduction rate, can't trigger the deduction workflow, can't separate "slow on the rest" from "challenging the difference."

4. **`awaiting_documentation`** — customer asked for backup, we haven't sent it. Different from `disputed`: no disagreement, just missing artifact. Sailfin encodes via `sfsrm__Sub_Type__c = "Invoice Backup Required"`. SLA clock is on Cashline, not the customer — confusing this with "disputed" makes Cashline look bad on its own scorecard.

5. **`on_hold` / `credit_hold`** — credit hold, legal escalation, or parent-pay negotiation. Sailfin's `Account.Credit_Hold__c` cascades to every open invoice. On-hold invoices need to be *visible but not actioned* — drop out of the call queue, freeze aging bucket (Client-configurable).

6. **`written_off`** — bad debt. Distinct from `void`. `void` = "should never have existed" (duplicate, wrong customer); `written_off` = "real and uncollectable." Different GL postings, different downstream consequences. Sailfin has both via `sfsrm__Transaction_Type__c`: `Write Off` / `Reversal` / `Write Back`.

Six safe to defer: `pending_submission` (sub-state of draft), `expired` (statute-of-limitations), `legal_referred` (better as a flag), `factored` (Sailfin's `Factored__c` — only matters if Client factors receivables), `customer_disputed_in_full` vs `customer_disputed_in_part` (sub-state of disputed), `settled` ("accepted less than face value").

---

## PaymentPromise — why invoice-level is wrong

Gap 6 recommends `PaymentPromiseAllocation` many-to-many. Promote it, but the gap is larger than allocation.

### Bucket promises and partial promises

Customer with $200K across 14 invoices says *"I can get you $80K next Tuesday."* The collector is not promising specific invoices — they are promising a **dollar amount against a bucket** (often "everything over 60 days"). Which invoices AP will pull is unknown until remittance lands. Forcing invoice selection upfront produces three failure modes: (1) collector picks wrong invoices, customer pays different ones, every promise looks "broken"; (2) collector picks all 14 and tags each with $80K/14, breaking the broken-promise calc; (3) collector skips logging entirely (what actually happens).

**Recommendation:** `PaymentPromise` as a header on `Customer::Account` carrying `promised_amount_cents`, `promise_date`, `bucket_filter` ("60+ days", "all open", or specific invoices). `PaymentPromiseAllocation` is first the collector's *intended* allocation, then the *resolved* allocation once remittance arrives.

### Aging suspension while open

While a promise is `open` with a future `promise_date`, the invoice's aging bucket should *freeze* — customer drops from the call queue, invoices don't escalate, DSO report optionally excludes promised amounts (Client-configurable; both inclusion policies are legitimate). Platform has no mechanism for this today.

### Broken-promise count drives escalation

First broken promise: re-call in 2 business days. Second within 90 days: management review / credit-hold conversation. Third: legal or written-off candidate. Platform needs broken-promise count per customer as a first-class derived field. *Kept-vs-broken ratio over 12 months is the single most predictive feature for credit decisions on existing customers — more predictive than D&B in most mid-market shops.*

### Fuzzy match for "kept"

A `kept` promise arriving short ($80K promised, $72K received) needs either a re-opened partial promise or a deduction-research task on the $8K. "Kept" cannot just mean `received >= promised`. Add a tolerance band (within 5% or $X is "kept").

---

## Cash application semantics

The 14 values of `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c` are the classifier the cash-app desk lives in:

- **`Applied`** / **`Auto Applied`** — common case; *Auto Applied* = engine matched (clean invoice number on remittance), *Applied* = human / downstream rule.
- **`Apply Cash`** / **`On Account`** — money arrived but unmatched. *On Account* = "we have your money, we don't know what for." Distinct from `Unapplied Payment` (the *payment-header* state on `sfsrm__Payment_Status2__c`).
- **`Applied Credit`** — uses an existing credit balance from prior overpay / credit memo.
- **`Credit Memo`** — credit against an invoice (usually from dispute resolution).
- **`Deduction`** — customer paid less and coded a reason. Becomes deduction-to-research → credit memo (if valid) or chargeback / write-off (if not).
- **`Discount`** — `sfsrm__Discount_Type__c` (4 values: `Earned / Unearned / Forced / Zeroed`) is the most operationally important picklist nobody on a generalist team would notice. *Unearned* = customer took 2/10 net 30 but paid day 45 — a deduction by another name, must be collected back or written off. *Forced* = AR honored a discount post-hoc to keep the relationship. *Zeroed* = wrote off a tiny remainder. Four distinct outcomes.
- **`Write Off`** / **`Write Back`** / **`Reversal`** — three GL-impacting movements that look identical to a non-AR person. *Write Off* = bad-debt expense. *Write Back* = reverse a prior write-off because customer eventually paid (rare). *Reversal* = undo an erroneous prior application. Keep distinct or GL diverges from subledger.
- **`Payment Refund`** — money flowing *out*. Overpay refund or chargeback completed.
- **`Account to Account Transfer`** — move an on-account credit between customers (parent-pay).
- **`Offset`** — net an AR balance against an AP balance with the same counterparty. Common where customer is also supplier. Without it, you can't represent why a balance disappeared.

### Minimum viable Payment model for Phase 1

The Decision #1 default ("stub Payment with `invoice_id`, `amount_cents`, `received_at`, `method`") forecloses multi-invoice allocation, unapplied/on-account cash, deductions, overpays, refunds, offsets, and the 8 cash-app worklist states. Recommend:

- **`Payment` (header):** `customer_organization_id` (nullable until identified), `customer_account_id` (nullable until matched), `received_at`, `amount_cents`, `currency`, `method` (ACH / Check / Wire / CC / Offset / Other — matches `sfsrm__Payment_Type__c` 5 values), `reference_number`, `payment_batch_id`, `status` (8-value `sfsrm__Payment_Status2__c` enum: `Applied / Auto Applied / Auto Matched / Identified Account / Partially Paid / Processing / Unapplied Payment / Unidentified Payment` — *Unidentified Payment* is its own queue with its own SLA).
- **`PaymentAllocation`:** `payment_id`, `invoice_id` (nullable for on-account), `amount_cents`, `transaction_type` (Sailfin's 14 collapsed to ~8: `applied / on_account / applied_credit / credit_memo / deduction / discount / write_off / refund`), `reason_code` (shared vocabulary with Dispute.reason_code), `discount_type` (only if `transaction_type=discount`).
- **`PaymentBatch`:** trivial.
- *Defer to Phase 2:* `BankStatementRemittance` (raw bank-side layer). Desk can work without it as long as Payment captures the right fields.

---

## Credit ontology minimum viable shape

### CreditApplication (Sailfin 31 fields)

Capture: legal name + DBA + business-operates-as (customers invoice under DBA, pay under legal name, reference parents under yet other names), EIN (encrypted), parent company name (**seed for Customer Hierarchy**), date business started, estimated monthly purchases, tax exempt status, PO requirements, AP contact — name, billing email, address, phone (promote to a first-class `Customer::BillingContact` distinct from the relationship contact), bank, owners, "required" boolean.

### CreditReview (Sailfin 29 fields)

The four credit-limit fields are operationally load-bearing — *do not collapse*:

- `Requested_Credit_Limit__c` — what the customer asked for.
- `Recommended_Credit_Limit__c` — what the scorecard says.
- `Approved_Credit_Limit__c` — what the credit committee authorized (may be less than recommended).
- `System_Credit_Limit__c` — what's enforced in the ERP / order-block.

Plus: `Model_Type__c` (4 values: `CID / Experian / Full Review / SES`), `DNB_Score__c`, `Paydex_Score__c` (trade-payment score 0-100, the standard mid-market signal), `Country_Score__c`, `Risk_Score__c` (composite), `Status__c` (`Pending / Approved / Rejected`). A `CreditReview` with no preceding `CreditApplication` is a *recurring review* — model that case explicitly.

### TradeReference (Sailfin 15 fields)

Customer lists 3-5 suppliers they buy from on credit; we (or the Client) call each. Minimum viable: `TradeReference { credit_application_id, supplier_name, supplier_contact, contacted_at, high_credit_amount, current_balance, payment_terms, payment_rating (excellent/good/fair/poor/n/a), notes }`.

### Do NOT port `Score_Card_Parameter__c`

Cashline's "Cashline Score" POC will have its own model. Carrying Sailfin's parameterization locks in the SFSRM vendor's choices. Instead: `CreditScore { credit_review_id, score_value, model_name, model_version, computed_at, components: jsonb }` — components opaque until the model stabilizes.

### Missing from both Sailfin and the platform

- **`CreditHoldEvent`** — when on hold, why, authorized by, when lifted, lifted by. Sailfin has only the `Credit_Hold__c` boolean, no history.
- **`CreditLimitChange`** — every change to the approved limit with reason and authorizer. Bad-debt waiting to happen without this.
- **`PaymentBehavior`** (derived) — rolling DSO, broken-promise rate, dispute rate, deduction rate per customer. Feedback loop from collections into credit.

---

## Picklist translation work the team is underestimating

Three ways the work shape is wrong:

### 1. Reason codes look mergeable but encode different downstream actions

`sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` (64) and `sfcapp__Deduction_Reason_Code__c` (48) overlap ~50% — look like the same vocabulary, aren't:

- `Chargeback Adjustment` vs `Chargeback Reversal` — opposite actions. Merging erases audit direction.
- `KEY US BAD DEBT WRITE OFF` vs `KEY US DIRECT WRITE OFF - INV` vs `KEY US DIRECT WRITE OFF - Rcpt` — three write-off paths, three different GL postings. `Rcpt` = write-off against the cash receipt (used when you can't identify which invoice the receipt belongs to).
- `KEY US BAD DEBT WRITE  OFF` vs `KEY US BAD DEBT WRITE OFF` — two spaces vs one. **Different picklist values.** Almost certainly both have data behind them. Without a domain expert, the ontology inherits a duplicate vocabulary.
- 22 state-specific `XX SALES TAX WRITE-OFF` values — *can* collapse to `sales_tax_writeoff` with state in a separate field, but the originals exist for state-level reporting. Decide explicitly before collapsing.

### 2. Picklist values double as record-type / tenant-routing tokens

`_CL` suffix on `sfsrm__Sub_Type__c` values (`LEGAL_CL`, `MGMT - CUSTOMER ISSUE_CL`) is a load-batch source marker from the SFSRM import — not a distinct meaning. `Corrpro_Resolver__c` on `sfsrm__Transaction__c` is a 27-value picklist with **27 named individuals** as values (Brad Williams, Brooks Bucher, ...) — a person-routing field implemented as a picklist instead of a `User` FK. Don't translate values, replace with an FK. `Viking_Task__c` (36 values, all `Dispute - X` for one specific client) is tenant-leaked workflow state.

### 3. The high-signal picklist list is broader than the comparison doc names

Comparison doc names 4 fields (~200 values). Add: `Dispute.Type` (28), `Dispute.Resolution_Code` (18), `Transaction.Status` (12, overloaded), `Transaction.Viking_Task` (36, tenant-leaked but contains real stages), `Payment_Line.Transaction_Type` (14), `Payment_Line.Discount_Type` (4), `Payment_Line.Deduction_Type` (3 — three different GL postings), `Payment.Payment_Status2` (8 — cash-app worklist drivers), `Treatment.Treatment_Segment` (9 — the 3×3 matrix). Ten fields, ~290 values, all needing domain-expert mapping. Two domain-expert weeks paired with the data, not one analyst with a spreadsheet.

---

## Missing operational entities

The cluster map and comparison doc correctly cut `Reporting_Client__c`, `Collector_Productivity__c`, etc. as operational-not-domain. Agreed on those. But entities the new ontology needs that are missing from both Sailfin and cashline-platform:

### 1. Credit Hold / Watchlist

Sailfin has `Account.Credit_Hold__c`, `Credit_Limit_Total__c`, `sfsrm__Credit_Limit__c`, `sfsrm__Amount_Over_Credit_Limit__c`, `sfsrm__Auto_Dunning_Enabled__c`. Platform has none. **Minimum viable:** `CreditHold { customer_account_id, started_at, ended_at, reason, authorized_by_user_id, lifted_by_user_id }` + `Customer::Account.credit_limit_cents`, `Customer::Account.dunning_enabled` boolean.

### 2. Customer Hierarchy / Parent-Pay

Sailfin has `Account.ParentId`, `Parent_No__c`, `Parent_Account_Account_Number__c`, `Parent_Account_Total_AR__c`. Common reality: Chevron-Houston, Chevron-Midland, Chevron-Corporate roll up to Chevron Corporation; Chevron-Corporate actually pays. Without this you can't represent "invoice to subsidiary, parent pays," can't aggregate exposure across subsidiaries for credit-limit purposes, can't route dunning to the parent when the subsidiary contact bounces, can't represent the most common dispute pattern ("we already paid on the Corporate account"). **Minimum viable:** `Customer::Organization.parent_organization_id` (self-FK) **plus** a separate `pays_through_organization_id` — a subsidiary may have a parent for org-chart purposes but invoices get paid by a third entity per treasury arrangement. Two distinct FKs.

### 3. Dunning Strategy / Cadence

Sailfin has `sfsrm__Treatment__c` with `sfsrm__Treatment_Segment__c` (9 values, a 3×3 size × payer-quality matrix) driving the dunning calendar. Comparison doc treats as out-of-ontology (Gap 8). I disagree on one point: **the dunning *configuration* belongs in the ontology even if the *execution* doesn't.** Which Client uses which cadence template, what the templates are ("Good payer: call at +14, email at +21, escalate at +45"), per-Customer overrides. Without this, every Client onboarding hard-codes cadence into the OperationalTask scheduler. **Minimum viable:** `DunningStrategy { client_organization_id, name, rules: jsonb }` + `Customer::Account.dunning_strategy_id` override.

### 4. Aging Bucket Definition

Sailfin's `Amount_Due_30__c`, `Amount_Due_60__c`, `Amount_Due_90__c`, `Amount_Due_Over_90__c` assumes 30/60/90 buckets. Real shops have Client-configurable buckets (some 0/30/60/90/120+, some weekly for first 60 days then monthly). **Minimum viable:** `AgingBucketDefinition { client_organization_id, buckets: jsonb }`.

### 5. Statement of Account

Sailfin has `sailfin__Statement__c` (interestingly, a separate namespace — Cashline-specific). Statements are the most common dispute trigger ("you say $50K, my records say $48K"). Without statement history you can't answer "what did we tell the customer they owed on the last statement," and that question comes up in every escalation. **Minimum viable:** `Statement { customer_account_id, statement_date, total_balance_cents, attachment }` — most value is in storing the rendered PDF, not re-deriving line items.

### 6. Collection Note routing

Sailfin embeds notes everywhere (`sfsrm__Latest_Note__c`, `sfsrm__Notes__c`, `sfsrm__Treatment_Notes__c` on Dispute; `Dispute_Notes__c` on Transaction). Cluster map open question 4 asks whether these should be first-class. **Answer:** call notes belong on `Customer::Account` or `PaymentPromise`, not embedded textarea on the invoice. Collector calls about Invoice 1234, customer says "I'll pay all 5 overdue on Friday" — that note belongs at the customer or promise level. `CommunicationEvent` with `direction: :internal_note` covers this *if* the routing rule explicitly sends collection notes to Customer::Account or PaymentPromise, not the triggering invoice.

---

