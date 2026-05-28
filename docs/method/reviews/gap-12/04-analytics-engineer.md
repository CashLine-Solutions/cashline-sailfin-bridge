# Analytics engineer — Gap 12 (ARPosting) follow-up

Source: extraction run `id=9` against `cashline_ontology_development`.
Methodology mirrors the prior review: row counts via
`field_profiles.distinct_count` on `Id`; live/dead via `null_rate`;
discriminator value frequencies from `top_values`. Every claim has a rerunnable
query. The panel's P0 is right — `sfsrm__Transaction__c` is the polymorphic
AR posting record, not an Invoice. This pass sizes the subtypes, classifies
the 32 amount / 54 date / 16 status-family columns by which subtype each
belongs on, and stress-tests the synthesis claim that the cash-side gap costs
49 live sensitive fields.

## Sizing the 14 transaction types

The discriminator `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c` has
14 active picklist values; only 10 ever appear in data.

```sql
SELECT pv.value FROM spicklist_values pv
JOIN sfields sf ON sf.id = pv.sfield_id
JOIN sobjects s ON s.id = sf.sobject_id
WHERE s.extraction_run_id = 9
  AND s.api_name = 'sfsrm__Payment_Line__c'
  AND sf.api_name = 'sfsrm__Transaction_Type__c';

SELECT fp.distinct_count, fp.null_rate, fp.top_values
FROM field_profiles fp
JOIN sfields sf ON sf.id = fp.sfield_id
JOIN sobjects s ON s.id = sf.sobject_id
JOIN object_profiles op ON op.id = fp.object_profile_id
WHERE s.extraction_run_id = 9 AND op.extraction_run_id = 9
  AND s.api_name = 'sfsrm__Payment_Line__c'
  AND sf.api_name = 'sfsrm__Transaction_Type__c';
```

| Picklist value | Payment_Line rows | % cash side |
|---|---:|---:|
| Apply Cash | 194,263 | 74.4% |
| Auto Applied | 41,200 | 15.8% |
| On Account | 19,936 | 7.6% |
| Deduction | 1,892 | 0.7% |
| Reversal | 1,881 | 0.7% |
| Credit Memo | 732 | 0.3% |
| Account to Account Transfer | 726 | 0.3% |
| Applied | 456 | 0.2% |
| Applied Credit | 50 | 0.02% |
| Write Off | 30 | 0.01% |
| **Sum** | **261,166** | one row per Payment_Line |
| Discount / Payment Refund / Write Back / Offset | 0 | declared but never used |

74% of cash activity is `Apply Cash` (received money allocated to invoice).
With Auto Applied (system-matched) and On Account (unallocated), three
buckets cover 97.8% of cash rows.

**Invoice-side sizing.** `sfsrm__Transaction__c` has 2,169,629 rows.
Only 233,546 distinct Transactions are referenced from a Payment_Line
(`sfsrm__Payment_Line__c.sfsrm__Transaction__c`, 8.2% null):

```sql
SELECT ss.api_name, sf.api_name, fp.null_rate, fp.distinct_count
FROM srelationships r
JOIN sfields sf ON sf.id = r.source_field_id
JOIN sobjects ss ON ss.id = sf.sobject_id
JOIN sobjects t ON t.id = r.target_sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE r.extraction_run_id = 9 AND t.api_name = 'sfsrm__Transaction__c';
```

So **~1,936,000 Transactions originate AR** (Invoice / Ticket / Credit Memo
with no Payment_Line) and **~233,546 are cash-side subtypes** (the targets of
allocations). The closest in-row discriminator on Transaction itself is
`Document_Type_Description__c` (151 distinct values, 46% null):

```sql
SELECT fp.top_values FROM field_profiles fp
JOIN sfields sf ON sf.id = fp.sfield_id
JOIN sobjects s ON s.id = sf.sobject_id
JOIN object_profiles op ON op.id = fp.object_profile_id
WHERE s.extraction_run_id = 9 AND op.extraction_run_id = 9
  AND s.api_name = 'sfsrm__Transaction__c'
  AND sf.api_name IN ('Document_Type_Description__c','Type__c');
```

| Document_Type | rows | mapped subtype |
|---|---:|---|
| INVOICE | 789,491 | Invoice |
| Ticket | 299,935 | Invoice / Ticket variant |
| AR Invoice | 57,449 | Invoice |
| CREDIT MEMO | 7,176 | CreditMemo |
| General Journal | 5,005 | Adjustment |
| Draft Invoice | 4,738 | Invoice (pre-posting) |
| Unapplied Cash | 3,016 | OnAccount |
| PAYMENT | 1,584 | Apply Cash header |
| Credit / AR Credit Memo | 2,043 | CreditMemo |
| 141 long-tail values | ~1.0M | mixed; **46% of rows have NULL here** |

Three things to flag. (1) The discriminator is upper-case-mixed free text
per source ERP — `Type__c.top_values` confirms `I` (772K), `IN` (74K),
`Invoice` (126K), `13` (57K), `2` (53K), `RI` (46K), `60` (15K) all encode the
same concept across different client ERPs. **The `kind` enum needs a
translation table built at extract time** — a 1:1 picklist port will not work.
(2) The Transaction object's own `Transaction_Type__c` and
`Transaction_Type_Name__c` are *both 100% null*; the 14-value picklist exists
only on Payment_Line. So the discriminator must be **derived** for the 1.94M
Transactions that have no Payment_Line. (3) The four declared-but-unused
values (Discount, Payment Refund, Write Back, Offset) match the comparison
doc's enum list — the doc enumerates ambition; the live data has 10.

## The 32 currency fields, by subtype

```sql
SELECT sf.api_name, sf.calculated, fp.null_rate,
       ROUND((1 - fp.null_rate) * 2169629)::int AS approx_populated_rows
FROM sfields sf
JOIN sobjects s ON s.id = sf.sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9 AND s.api_name = 'sfsrm__Transaction__c'
  AND sf.data_type = 'currency'
ORDER BY fp.null_rate NULLS LAST;
```

Bucketed by null_rate:

- **ARPosting parent (8 fields, 100% populated):** `sfsrm__Amount__c`,
  `sfsrm__Balance__c`, `Original_Amount__c`, `sfsrm__Base_Amount__c`,
  `sfsrm__Base_Balance__c`, `sfsrm__Disputed_Amount__c`,
  `sfsrm__Transaction_Disputed_Amount__c`, `sfsrm__Undisputed_Balance__c`.
- **Account-context formulas — recompute, don't migrate (12 fields):**
  `Amount_Due_30/90/Over_90__c`, `AR_30_Days_Past_Due__c`,
  `AR_Less_Than_30_Days_Past_Due__c`, `Amount_45_Days_Past_Due__c`,
  `Brand_Total_AR__c`, `In_Line_for_Payment__c`, `Not_in_Line_for_Payment__c`,
  `Montant__c`, `Montant_en_souffrance__c`, `X150__c`, `X121_150__c`. All
  calculated; all roll up against Account, not row-level Transaction state.
  The new platform should compute these on demand from a single
  `ARPosting.balance_cents` column.
- **Invoice-only (7 fields):** `sfsrm__Tax__c` (57.5% pop), `Tax_Amount__c`
  (97%, mostly $0), `Freight_Amount__c` (97%, mostly $0), `sfsrm__Discount_Feed__c`
  (77%), `sfsrm__Discount_Amount_Requested__c` / `_Applied__c` (8.8%),
  `Retention_Amount__c` (0.8%, construction billing), `Discount_Amount__c` (0.4%).
- **PaymentPromise (1 field):** `sfsrm__Promised_Amount__c` (99.8% — defaults
  to 0 on non-Invoice; the *meaningful* population is the same ~36% of rows
  where `sfsrm__Promise_Date__c` is set).
- **Other / sparse (1):** `Other_Amount__c` (11.2%, subtype unclear).
- **Collections-Treatment subtype (1):** `Legal_Balance__c` (0.01%, 197 rows).
- **Dead, do not migrate (5):** `Broken_Promise_Amount__c`, `Ticket_Total__c`,
  `Total_Amount_Due_90_Days__c`, `sfsrm__Subtotal__c`,
  `sfsrm__Promised_Target_Balance__c` — all 100% null.

**Net:** of the 32 currency-typed fields the comparison doc currently funnels
into `Invoice`, only **8** are actual ARPosting parent columns. 12 are
Account-roll-ups that should not exist at row level. 7 belong on the `Invoice`
subtype. 5 are dead.

## The 54 date columns, by subtype

```sql
SELECT sf.api_name, sf.data_type, fp.null_rate
FROM sfields sf JOIN sobjects s ON s.id = sf.sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9 AND s.api_name = 'sfsrm__Transaction__c'
  AND sf.data_type IN ('date','datetime')
ORDER BY fp.null_rate NULLS LAST;
```

- **ARPosting parent (4 fields):** `Invoice_Created_Date__c` (100% — the
  `posted_at`), `sfsrm__Create_Date__c` (~100%, duplicate),
  `sfsrm__Close_Date__c` (90.3% — `closed_at` when retired), system audit
  columns (`CreatedDate`, `LastModifiedDate`, `SystemModstamp`).
- **Invoice-only (8):** `sfsrm__Due_Date__c` (100%), `Best_Possible_Payment_Date__c`
  (100%), `Expected_Payment_Date__c` and its **four duplicate formula variants**
  (`_V2`, `_Pro`, `_Merit_Flow`, original) — collapse to one in the new
  ontology, `Bline_Date__c`, `Lien_Laws_Date__c` (construction-billing),
  `Ship_Date__c`, `sfsrm__Discount_Date__c`.
- **Ticket subtype (5 fields, ~13% pop, ~300K rows):** `Job_End_Date__c`,
  `Job_Return_Date__c`, `Job_Min_Start_Date__c`, `Original_Ticket_Close_Date__c`,
  `Ticket_Approval_Date__c`, `Field_Ticket_Submission_date__c`. These match
  `Document_Type_Description__c='Ticket'` (299,935 rows). The Ticket subtype
  is genuinely distinct from Invoice — the doc should add it.
- **PaymentPromise (3 fields):** `sfsrm__Promise_Date__c` (35.7%, **773,527
  rows** — much larger than the platform's stub PaymentPromise implies),
  `Promise_Marked_Date__c` (2.9%), `sfsrm__Note_Date__c` (40.9%, dual-use).
- **Cash-side subtypes (3):** `Payment_Date__c` (0.2% on Transaction —
  sparse here because most cash dates live on the Payment_Line),
  `Clearing_Date__c` (0.04%), `Posting_Date__c` (4.1%).
- **Approval-workflow (3):** `Date_Approved__c`, `Ticket_Approval_Date__c`,
  `Invoice_Approval_Date_OneX__c` — ~1% each, all the
  `Open_Invoices__c` (30K rows) approval surface.
- **Tenant-specific extensibility (1):** `Endurance_Lift_Comment_Date__c`
  (3.2%, ELS/Endurance tenant only).
- **ETL provenance — migrate to ImportBatch (1):** `Latest_Upload_Date__c`
  (99.5%).
- **Dead, do not migrate (6+):** `Last_Return_Date__c`, `First_Start_Date__c`,
  `Action_Note_Date__c`, `sfsrm__Next_Follow_up_Date__c`, `Last_Stop_Date__c`,
  `LastActivityDate` — all 100% null.

**Net:** 4 date columns on ARPosting parent, 8 on Invoice, 5 on a new Ticket
subtype, 3 on PaymentPromise, 3 on cash-side subtypes, and 6+ dead. The 5
Expected_Payment_Date formula variants are particularly worth flagging — they
all encode "predicted payment date" with different rule sets per tenant. Keep
one; recompute the others or drop.

## The 16 status-family fields

```sql
SELECT sf.api_name, sf.data_type, fp.null_rate, fp.distinct_count,
       (SELECT COUNT(*) FROM spicklist_values pv WHERE pv.sfield_id = sf.id AND pv.active) AS active_values
FROM sfields sf JOIN sobjects s ON s.id = sf.sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9 AND s.api_name = 'sfsrm__Transaction__c'
  AND (sf.api_name ILIKE '%status%' OR sf.api_name ILIKE '%state%'
       OR sf.api_name ILIKE '%stage%' OR sf.api_name ILIKE '%flag%')
ORDER BY fp.null_rate NULLS LAST;
```

I count 16 status-family fields (my prior review undercounted by filtering too
narrowly). The breakdown:

- **Cross-kind on ARPosting parent (4):** `Promise_Status__c` (100%, binary —
  has-promise/none), `sfsrm__Flag__c` (100%, 6 distinct), `sfsrm__DisputedFlag__c`
  (100%, binary), `sfsrm__Collection_Stage__c` (100%, **136 distinct values for
  what should be a 9-stage funnel — bloat to investigate**).
- **The lifecycle status, but sparse (1):** `sfsrm__Status__c` populated on
  only 18% of rows (~391K), 12 active picklist values but 56 distinct in data
  (translation work). `4. INVOICED/CLOSED` = 286K dominates. **82% of
  Transactions have no lifecycle status at all** — migration must back-derive
  state from `sfsrm__Close_Date__c` presence + Payment_Line allocation.
- **Invoice-only (1):** `Invoice_Status__c` (4%, 5 distinct).
- **Tenant-specific — `ClientFieldValue` candidates (5):** `ELS_Portal_Status__c`,
  `Endurance_Status__c`, `Ticket_Ecommerce_Status__c`, `Network_Status__c`,
  `Project_Status__c`. Each is ~1-3% populated and tenant-scoped. Exactly the
  shape Gap 15.5 (`ClientFieldDefinition + ClientFieldValue`) is meant to
  absorb. **Do not migrate these as columns.**
- **Mis-named, ignore (2):** `sfsrm__Ship_To_State__c` / `sfsrm__Bill_To_State__c`
  — these are US state postal codes, not lifecycle status.
- **Dead (3):** `Warrior_Status_Update__c`, `Dispute_Status__c` (0.6%,
  denormalized from Dispute), `Status_Name__c`.

## The 49-sensitive-fields-lost claim

```sql
SELECT s.api_name,
       COUNT(*) FILTER (WHERE sf.sensitivity IN ('pii','financial','pii_and_financial')) AS sensitive,
       COUNT(*) FILTER (WHERE sf.sensitivity IN ('pii','financial','pii_and_financial')
                        AND fp.null_rate < 0.5) AS live_sensitive
FROM sfields sf JOIN sobjects s ON s.id = sf.sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9
  AND s.api_name IN ('sfsrm__Payment__c','sfsrm__Payment_Line__c',
                     'sfcapp__Payment_Batch__c','sfcapp__Bank_Statement_Remittance__c')
GROUP BY s.api_name ORDER BY 3 DESC;
```

Verified: Payment_Line 17 + Payment_Batch 11 + Bank_Statement_Remittance 11 +
Payment 10 = **49 live sensitive fields**. The synthesis number holds.

**But re-routing into `ARPosting` recovers a meaningful chunk.** Payment_Line's
17 live sensitive fields are mostly `Amount`, `Date`, `Account` (FK),
`Transaction` (FK), `Check_Amount`, `Invoice_Amount_trns`, `Deposit_Date`,
`Paid_Amount_Extract`, `sfsrm__Payment_Date__c`. **At least 9 of these become
columns on ARPosting cash-side subtypes** (Apply Cash / Auto Applied / On
Account) — the amount, transaction date, account FK, and reason are already
modeled at the Transaction grain. The remaining 8 Payment_Line fields
(currency conversion, deduction type, transfer-to self-ref) are
per-allocation and need either a slim `CashAllocation` or absorption into
JSONB.

Payment_Batch's 11 (totals, batch dates, accounting period) and
Bank_Statement_Remittance's 11 (bank name, wire reference, amount) are at
a level **above** ARPosting and don't migrate into it. These still need
`Payment` + `PaymentBatch` + `BankStatementRemittance` to land cleanly —
Decision 1's stub `Payment` (`invoice_id` + `amount_cents` + `received_at` +
`method`) covers the dashboard need but loses the batch/wire grain.
Payment's own 10 fields (check number, method, total, currency) belong on
that stub.

**Net exposure after ARPosting redesign:** ~9 sensitive fields recovered into
ARPosting subtypes; ~32 still need Batch+Remittance+Payment; ~8 per-allocation
need a junction or JSONB. So **the real cash-side gap is closer to 40 live
sensitive fields, not 49** — ARPosting buys ~18% relief on its own.

## What the comparison doc should change at line 45

The current side-by-side (`sfsrm__Transaction__c → Invoice`, 1:1) needs the
~70 mapped fields redistributed:

- **~20 onto `ARPosting` parent** (Amount, Balance, Disputed family, Base
  family, Account FK, `kind` derived, `posted_at`, `closed_at`, Reason_code,
  Collection_Stage, Disputed/Promise flags, CurrencyIsoCode, Transaction_Key
  external ID).
- **~17 stay on `Invoice` subtype** (Due_Date, Expected_Payment_Date,
  Tax, Freight, Discount fields, Retention, Ship_Date, Bline_Date,
  Lien_Laws_Date, Discount_Date, Invoice_Number / Invoice_Category
  formulas).
- **~9 onto a new `Ticket` subtype** (Job_End, Job_Return, Job_Min_Start,
  Original_Ticket_Close, Ticket_Approval, Field_Ticket_Submission, FT_Attached,
  Project_Status, Ticket_Total if revived). Justified by 299,935 `Ticket`-typed
  rows.
- **~3 onto `PaymentPromise`** (Promise_Date, Promised_Amount, Promise_Marked_Date)
  — but with the warning that 773K Transactions carry a promise date,
  meaning PaymentPromise is a much larger historical surface than the platform
  currently models.
- **~6 onto cash-side subtypes** (Payment_Date, Clearing_Date, Posting_Date,
  CashApp_Balance, CashApp_Applied_Amount, CA_Balance_Mismatch).
- **~12 dropped** (12 Account-context aging formulas — recompute from
  `ARPosting.balance_cents`).
- **~5 dropped** (tenant-status columns) — store via ClientFieldValue.
- **~15 dropped** (dead in run 9).

That's about 30% relocation, 30% drop, and 40% staying on their original
mapped concept. The 1:1 → polymorphic move is real work but it's bounded.

## Reproducibility notes

- Discriminator value frequencies:
  `top_values` on `sfsrm__Payment_Line__c.sfsrm__Transaction_Type__c`.
- Sub-type signal on Transaction itself: `Document_Type_Description__c` +
  `Type__c` `top_values` (free text — normalize at extract).
- Cross-kind vs subtype-specific detection: rank by `null_rate * 2,169,629`;
  100% → parent; ~46% → matches the Document_Type non-null rate → Invoice-leaning;
  <10% → workflow subtype; 0% → dead.
- Sensitive-fields accounting: `sensitivity IN (...)` joined to
  `null_rate < 0.5` across the four cash-side objects.
