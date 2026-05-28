# General data analyst — cross-cutting review

Cross-lens review of run_id=9 (extraction `2026-05-24T23-27-12Z-be06`, 123 sobjects, 4,554 fields). Focused on what the four specialist reviewers (Salesforce architect, collections domain expert, target-side data architect, analytics engineer) will likely miss because of their specialty bias.

## Headline

- **PII has already leaked into a non-sensitive run.** Run 9 (`include_sensitive=false`) carries top_values that include real customer names ("NAVAL FACILITIES ENG. COMMAND", "CONOCOPHILLIPS COMPANY", "EXXONMOBIL PIPELINE COMPANY"), real tenant identities ("VikingRentals", "EnduranceLift", "VoltYX", "KeyEnergy"), real bank names ("Bank of America", "AMEGY BANK OF TEXAS"), real Houston addresses, and a person's name ("Michelle Sprayberry"). The Phase-2 redaction story is structurally broken — fields the classifier labels `safe` carry the PII that the threat model is supposed to suppress.
- **The schema documents three tenant-leakage tenants (Viking / Alpine / Casey Sprayberry); the data shows at least nine.** Viking (45 fields), ELS (8), Endurance (4), KLX (4), Voltyx (2), Griffin (2), Warrior (1), Casey Sprayberry (1), Alpine (1), plus six **French-labeled fields** (Montant, Date d'échéance). The side-table migration scope is ≥3× what the docs claim, and i18n was never mentioned anywhere.
- **The platform's "money in integer cents" plan does not survive contact with the data.** Accounts hold balances in 10 currencies (USD, CAD, BRL, GBP, EUR, AUD, ARS, NOK, COP, TTD). Currencies with different minor units (Japanese Yen=0, Tunisian Dinar=3) will silently misvalue invoices. Negative amounts are normal on every receivables table — credit memos, reversals, refunds — and `unsigned cents` columns can't represent them.
- **Bank account numbers, ABA, IBAN, EIN/SSN, and PASSWORD fields are all classified `safe`.** The R14 PII blocklist regex misses `aba|routing|bank_account|iban|password|ein` and lets banking-PII through. `sfsrm__EIN_or_Social_Security_Numbre_s__c` (note the typo) and `sfsrm__Archival_Password__c` are profiled as if they were generic text. This is a P0 finding for the security-review track.
- **`object_profiles.record_count` is NULL for all 123 objects.** Every row-count claim in the comparison doc (~20K Payments, ~261K PaymentLines, ~203K EmailMessages, etc.) was sourced *outside* this database. The unused-fields report still works because it joins on `field_profiles.null_rate`, but `runs/show` reads `record_count` and will show blanks. Designers running the workbench off this data will see zero volume signal.
- **The automatic clustering output is meaningless** — duplicate cluster names ("Call Center" appears twice, "Account" appears twice), and the 32-object "Call Center" cluster mashes `sfsrm__Collection_Forecast__c` together with `ProfileSkillEndorsement`, `User`, `Solution`, and the SFSRM Config tables. The hand-curated cluster map is the only usable grouping; the algorithmic output does not earn its keep.
- **Date data spans 1753 to 3623.** Multiple Transaction date columns use 1753-01-01 (SQL Server `datetime` min) as a sentinel for unset, and `Expected_Payment_Date__c` ranges to year 3623 (typo: `2023` → `3623`). The platform's Rails `Date` validations will reject these rows wholesale at migration.

## Data quality findings

### Two `PO_Number` fields on Transaction

```sql
SELECT so.api_name, sf.api_name FROM sfields sf JOIN sobjects so ON so.id = sf.sobject_id
WHERE so.extraction_run_id = 9 AND so.api_name = 'sfsrm__Transaction__c'
  AND sf.api_name ILIKE '%po%number%';
-- PO_Number__c (Cashline custom)
-- sfsrm__Po_Number__c (managed-package version)
```

Two columns hold the same concept. Migration must choose one — and the side that doesn't agree with the chosen one needs reconciliation. Worse: a similar duplication exists for currency amounts (see "string-typed money" below).

### String-typed money on Transaction

`Invoice_Amount__c` and `Invoice_Amount_Due__c` are `string` data_type on the most important amount-carrying object in the org, while every sibling amount column is `currency` or `double`. String-typed money lets garbage in:

```sql
SELECT sf.api_name, sf.data_type FROM sfields sf JOIN sobjects so ON so.id = sf.sobject_id
WHERE so.extraction_run_id = 9 AND so.api_name = 'sfsrm__Transaction__c'
  AND sf.api_name ILIKE 'Invoice_Amount%';
-- Invoice_Amount__c        | string
-- Invoice_Amount_Due__c    | string
```

### 11 status fields, 27 amount fields on one object

```sql
SELECT COUNT(*) FILTER (WHERE sf.api_name ILIKE '%status%') AS status_fields,
       COUNT(*) FILTER (WHERE sf.api_name ILIKE '%amount%') AS amount_fields
FROM sfields sf JOIN sobjects so ON so.id = sf.sobject_id
WHERE so.extraction_run_id = 9 AND so.api_name = 'sfsrm__Transaction__c';
-- 11 status, 27 amount
```

Status is shattered across tenant subsystems: `Dispute_Status__c`, `ELS_Portal_Status__c`, `Endurance_Status__c`, `Invoice_Status__c`, `Network_Status__c`, `Project_Status__c`, `Promise_Status__c`, `Status_Name__c`, `Ticket_Ecommerce_Status__c`, `Warrior_Status_Update__c`, `sfsrm__Status__c`. The platform's plan (Gap 7) calls for ~15 lifecycle states; but the source maintains parallel state machines per tenant. The translation is not 11→1; it's "pick one or compose".

### Date sentinels and overflow

```sql
SELECT sf.api_name, fp.min_date, fp.max_date FROM field_profiles fp
JOIN sfields sf ON sf.id = fp.sfield_id
JOIN sobjects so ON so.id = sf.sobject_id
JOIN object_profiles op ON op.id = fp.object_profile_id
WHERE op.extraction_run_id = 9 AND fp.min_date < '1900-01-01' OR fp.max_date > '2050-01-01';
```

- `Best_Possible_Payment_Date__c`: **1753-01-01 → 2125-12-30**
- `Expected_Payment_Date__c`: **1753-02-12 → 3623-09-08**
- `Bline_Date__c`: 1950-02-25 → 2040-08-20
- 4 fields with `min_date < 1900`, 14 fields with `max_date > 2050`.

### Numeric overflow in formula chains

```sql
SELECT sf.api_name, fp.min_value, fp.max_value FROM field_profiles fp
JOIN sfields sf ON sf.id = fp.sfield_id
JOIN sobjects so ON so.id = sf.sobject_id
JOIN object_profiles op ON op.id = fp.object_profile_id
WHERE op.extraction_run_id = 9 AND so.api_name = 'sfsrm__Transaction__c'
  AND (fp.min_value < -1e9 OR fp.max_value > 1e9);
```

- `sfsrm__DPD_x_Amount__c`: -570 billion → 498 billion
- `Weighted_Days_to_Pay__c`: -570 billion days → 580 billion days
- `Original_Amount__c`: -$4.56 billion → $4.81 billion
- `sfsrm__DPD__c` (Days Past Due): -36,551 → 99,792 (273 years past due — sentinel value 99999 in the data)
- `Credit_Limit_Total__c` on Account: **$4.6 TRILLION max**

The 145 formulas on Transaction (per the EDA) amplify whatever sentinel/typo enters the input. The new ontology's KPI rollups will inherit this unless the migration explicitly bounds-checks.

### 802 fields are literally always null; 983 fields have null_rate ≥ 0.99

```sql
SELECT COUNT(*) FROM field_profiles fp
JOIN object_profiles op ON op.id = fp.object_profile_id
WHERE op.extraction_run_id = 9 AND fp.null_rate = 1.0;
-- 802

SELECT COUNT(*) FILTER (WHERE sf.sensitivity='safe' AND fp.null_rate >= 0.99) AS safe_unused,
       COUNT(*) FILTER (WHERE sf.sensitivity!='safe' AND fp.null_rate >= 0.99) AS sensitive_unused
FROM field_profiles fp JOIN sfields sf ON sf.id = fp.sfield_id
JOIN object_profiles op ON op.id = fp.object_profile_id
WHERE op.extraction_run_id = 9;
-- safe_unused=805 | sensitive_unused=178
```

~18% of the schema is dead weight; the analytics engineer will catch the unused-field count but probably not the **20% of unused fields that are sensitive-classified** (they should be cut even harder — empty PII columns are still attack surface in the file system audit trail).

### Tenant-leakage inventory (much wider than docs report)

```sql
SELECT split_part(sf.api_name, '_', 1) AS prefix, COUNT(*) AS fields
FROM sfields sf JOIN sobjects so ON so.id = sf.sobject_id
WHERE so.extraction_run_id = 9 AND sf.api_name LIKE '%__c' AND sf.api_name NOT LIKE 'sfsrm%';
```

Across Account, User, Dispute, Transaction, Weekly_AR_Snapshot:
- **Viking** — 45 fields (4 objects). Documented.
- **ELS** — 8 fields. Not documented.
- **Endurance** ("Endurance Lift") — 4 fields. Not documented.
- **KLX** ("KLX Energy Services") — 4 fields. Not documented.
- **Voltyx** — 2 fields. Not documented.
- **Griffin** ("Griffin Dewatering") — 2 fields. Not documented.
- **Warrior** ("WarriorTech") — 1 field. Not documented.
- **Casey Sprayberry** — 1 field. Documented.
- **Alpine** — 1 field. Documented.
- **Centerline** — 1 field on Account. Not documented.
- **Montant** (French) — 6 fields. Not documented.

The cluster map says "Viking + Alpine + Casey Sprayberry"; the actual surface area is **9+ tenants leaking ~70 fields**. Migrating them per the side-table plan (Gap 3) is roughly 3× the work the docs suggest.

## Cross-cluster cohesion check

Using a manual cluster mapping that mirrors the cluster-map's 8 buckets and stripping system FKs (`OwnerId`, `CreatedById`, etc.), the edge-density tells a different story than the narrative:

```sql
-- (cluster_map CTE elided; assigns each sobject to C1_Parties..C8_CRMRemnants)
SELECT src.cluster AS src, tgt.cluster AS tgt, COUNT(*) AS edges
FROM srelationships r
JOIN cluster_map src ON src.sobject_id = r.source_sobject_id
JOIN cluster_map tgt ON tgt.sobject_id = r.target_sobject_id
JOIN sfields sf ON sf.id = r.source_field_id
WHERE r.extraction_run_id = 9 AND r.target_sobject_id IS NOT NULL AND NOT r.polymorphic
  AND sf.api_name NOT IN ('OwnerId','CreatedById','LastModifiedById','ProfileId',
                          'UserRoleId','ManagerId','BusinessHoursId','RecordTypeId')
GROUP BY src.cluster, tgt.cluster ORDER BY edges DESC;
```

Top results (business edges only):

| src | tgt | edges |
|---|---|---:|
| C8_CRMRemnants | C8_CRMRemnants | 56 |
| C8_CRMRemnants | C1_Parties | 26 |
| C7_Platform | C7_Platform | 21 |
| C5_Communication | C5_Communication | 19 |
| C7_Platform | C5_Communication | 14 |
| C1_Parties | C1_Parties | 14 |
| C8_CRMRemnants | C7_Platform | 10 |
| C2_Receivables | C1_Parties | 9 |
| C2_Receivables | C2_Receivables | 7 |

The story:

1. **C8 (CRM Remnants — "cut all of these") is the most internally-cohesive cluster** with 56 within-cluster business edges. Lead→Account, Order→OrderItem→Pricebook→Product2, WorkOrder→WorkOrderLineItem, Asset→AssetRelationship. Cutting C8 wholesale severs 56 internal + 26 inbound-to-Parties edges. The "cut" recommendation needs an edge-by-edge audit, not a blanket policy — at minimum the C8→C1 edges (Lead→Account, Order→Account) need translation rules so historical CRM data can still resolve a Customer.
2. **C2 Receivables is sparse internally — only 7 within-cluster edges.** Transaction, Line_Item, Payment_Line, Dispute, Credit_Application, Credit_Review don't directly reference each other much; they route through Account. The new ontology's plan to keep Invoice + InvoiceLineItem + Payment + PaymentAllocation as a tight cluster assumes a denser FK graph than the source has.
3. **C2 → C1 Parties: 9 edges.** The supposed-to-be-fundamental "Receivables belongs to Customer" relationship is carried by exactly 9 business FKs. The Account hub story holds (Account has 34 inbound), but the Receivables→Parties bridge is thin.
4. **C5 Communication has 19 internal edges** — that's surprisingly cohesive. EmailMessage, ContentDocument, ContentVersion, Task all reference each other. Consolidating into a single `CommunicationEvent` (Gap 4) collapses those edges into joins on a single table; the platform's plan handles this implicitly but the migration mapping needs to be explicit.

## Documentation-vs-reality drift

Spot-checked 10 claims from the EDA / cluster map / comparison docs against the DB.

| # | Claim | Source | Verdict |
|---|---|---|---|
| 1 | 123 sobjects, 4,554 fields, 7,999 picklist values | EDA §2 | ✅ Exact. |
| 2 | Namespace split 77/35/7/4 (standard / sfsrm / custom / sfcapp) | EDA §1 | ✅ Matches when derived from `api_name` prefix — but `sobjects.namespace_prefix` is **NULL for every row**. The column exists, the loader never populates it. Anything querying `sobjects.namespace_prefix` returns wrong answers. |
| 3 | Cross-namespace edges: (standard)→sfsrm 166 / sfsrm→(standard) 81 | EDA §4 | ❌ DB shows (standard)→sfsrm = 6 / sfsrm→(standard) = 118. Numbers don't match in either direction. The EDA likely expanded polymorphic refs to all `referenceTo` targets; the DB stores them as one row with the target in `reference_to_api_names` JSONB and `target_sobject_id` pointing at the first target. The EDA's edge-count methodology is not reproducible from this DB. |
| 4 | "13 true orphan objects" with no business in/out edges | EDA §4 | ❌ Under-count. DB shows **26 true orphans** when system FKs are stripped (Open_Invoices__c, Forecast_Configuration, Risk_Configuration, etc.). The EDA may use a more permissive system-FK filter. |
| 5 | 24 objects self-reference | EDA §4 | ⚠ Close — DB shows 22. Likely 2 polymorphic self-refs not counted. |
| 6 | Transaction = 438 fields, 426 custom, 145 formulas | EDA §2 | ✅ Verified — 438 total, 145 calculated. |
| 7 | Account = 352 fields, 295 custom (83.8%) | EDA §2 | ✅ Verified — 352 / 295. |
| 8 | Brand__c = 52 fields | Cluster map §1 | ✅ Verified. |
| 9 | Reporting_Client__c = "17 fields, only 4 substantive" | Cluster map §1 | ⚠ 17 fields confirmed; 5 substantive (Name + 4 documented). Minor. |
| 10 | "Viking 31 + Alpine 1 + Casey Sprayberry 1 = 33 tenant-leaked fields" | Cluster map §2 | ❌ Under-count. Real total ≥70 across 9+ tenants. |
| 11 | sfsrm__Dispute__c.sfsrm__Sub_Type__c = 70 values | Comparison Gap 11 | ✅ Exact match (70/64/37/36 for the four key picklists). |
| 12 | "Multi-invoice payments are the norm — ~13 PaymentLines per Payment, ~3,900 PaymentBatches" | Comparison §summary, Cluster 4 | ✅ Approximately: 261K PaymentLines / 19.9K Payments = ~13.1; PaymentBatches = 3,929. |

The high-confidence findings: the headline counts are right. The relationship statistics and orphan counts are aspirational, and they shouldn't be quoted as facts to designers without an asterisk.

## Hidden assumptions in the cashline-platform ontology

Read the comparison doc carefully — the following assumptions are *implicit* in the new design and contradicted by the data:

1. **One currency.** `Invoice.subtotal_cents` / `total_cents` / `balance_due_cents` plus a single ISO4217 column means a Customer's invoices are uniform-currency. The data has Accounts holding 10 currencies — including ones (BRL, ARS, COP) with different volatility profiles where rate-at-invoice vs rate-at-collection matters. The plan has no FX/rate-snapshot story.
2. **Amounts are non-negative.** Every receivables-side amount in the data has negative values (credits, reversals, refunds). The platform's `*_cents` columns are unsigned. Either the migration loses every credit memo, or the model needs `signed_cents` (admitting negative invoices breaks "balance_due_cents = 0 when paid").
3. **Customers have exactly one parent.** The comparison doc says `Customer::Account` carries `client_organization_id` + `client_group_id` (both required, validated to agree). The Sailfin data has `Account.ParentId` (self-reference, hierarchical customers) AND `Account_Brand_Association` for the link to Client. The platform model has no way to represent a Customer parent-child hierarchy — but the source has 22 self-referencing objects including `Account`. Parent-of-Customer is a real concept (subsidiaries, divisions) being silently dropped.
4. **`Account.account_number` is unique per client_organization, not per client_group.** Comparison §1 calls this out as a footnote. Worth surfacing: a Client with 5 internal divisions can not have those divisions all carrying their own "ACCT001" for the same Customer. The source's `Account_Brand_Association__c` has no `account_number` field at all — so wherever in the source the per-link account number lives, the migration is creating fresh.
5. **A Customer's name is not PII.** The classifier marks `Account.Name` as `safe` because there's no `FirstName`/`LastName` sibling — but in B2B collections, the customer's legal entity name (NAVAL FACILITIES ENG. COMMAND, CONOCOPHILLIPS COMPANY) **is the protected information**. It's confidential business intelligence that Cashline's collection clients pay to be exclusive. The ontology has no notion of "client-confidential" vs "operator-internal" vs "PII".
6. **Time zone is implicit.** No object_profiles record carries a TZ for the datetime columns. The user-list shows 174 Users in a single org but `TimeZoneSidKey` is a 424-value picklist. Phase-1 dashboards show "due dates" without saying "in whose time zone". An invoice due 2026-05-15 in Houston is not the same data point as in Sydney (the AUD currency suggests Australian customers).
7. **Activity carries one direction.** The comparison's `CommunicationEvent` has `direction: inbound|outbound|internal_note`. The source has `Task.sfsrm__From__c` AND `sfsrm__To__c` AND `sfsrm__Cc__c` AND `sfsrm__Bcc__c` — so direction is *derivable* from the participant list. Hardcoding direction at ingest means losing fidelity for forwarded messages, replies-to-an-internal-note, BCCs.
8. **Notes are text, not events.** `sfsrm__Latest_Note_Title__c` top values are "NOTE - \*", "EMAILED -", "NOTE - .", "NOTE - Update" — single-character note titles dominate. Notes already live half-as-events; the platform's plan to make them embedded text on Dispute (Cluster 5 open question 4) freezes the existing under-modeled shape.

## Unnamed risks

Beyond the Gaps/Risks section of the comparison doc.

1. **Twilio is in the data path.** `sfsrm__Screens__c.sfsrm__Screen_Name__c` contains values like `TwilioCreateReminderForOutOfOffice`, `TwilioTranscriptCreateDispute`. Sailfin's dunning flow includes voice/SMS via Twilio, and **transcripts feed into the dispute pipeline**. The new ontology has no path for ingesting Twilio transcripts; "communications ingestion" (Gap 4) talks about email only.
2. **File storage depends on third-party Dropbox links.** `Brand__c.Logo_URL__c` top values are public `https://www.dropbox.com/scl/...` URLs. Brand-side logos are not self-hosted. If Dropbox rotates the links (which it does), brand logos vanish silently.
3. **No deletion semantics.** R20 says "extraction is idempotent at the run level" but never discusses source-side deletes. If a Brand or Account is deleted in Sailfin between runs, the platform side has no `tombstone` story — the migrated record continues to exist on the platform with no signal.
4. **`IsDeleted` is consistently `null_rate = 1.0`.** The Salesforce describe API does not return soft-deleted rows by default. Run 9 never exercised `queryAll`, so the "Yes, but how many soft-deletes are in the source" question is unanswerable from this DB. The cluster map's row counts (~135K Accounts, etc.) exclude soft-deletes.
5. **Multi-currency exchange-rate drift.** The data has BRL (Brazilian Real), ARS (Argentine Peso), TTD (Trinidad-Tobago Dollar) — all currencies with notable inflation/volatility. Recording amounts in source-currency cents with a snapshot ISO code is necessary but not sufficient: the platform needs a rate table to consolidate at the Operator level, and that's not in scope anywhere.
6. **The audit DB design assumes append-only Postgres trigger holds.** The plan calls out that the audit DB has a separate role with INSERT-only privileges. This is only enforced if the smoke test in `lib/tasks/audit.rake` runs in CI. Without CI enforcement (`Risks & Dependencies` table acknowledges "out of scope here"), role-drift will silently weaken the audit guarantee.
7. **`sfsrm__Temp_Object_Holder__c` has 184,452 rows.** Cluster map dismisses it as a config table; the volume says it's a load-bearing scratch space (likely the SFSRM package's queue/cache). Cutting it from the ontology is correct — but the migration script that copies receivables data will fail if it triggers SFSRM logic that reads from Temp_Object_Holder. Worth flagging to whoever runs the cutover.
8. **`sfsrm__Data_Load_Batch__c` has 91,576 rows.** That's 5+ years of ingestion audit history. The cluster map says cut; but if anyone ever asks "when did this Customer's account last update from ERP X", `Data_Load_Batch` is the only source. The platform's `ImportBatch` model starts fresh and has no backfill story for historical ingestions.

## Scope-vs-effort mismatch

Cross-check the Phase-1 plan (1,030 lines) against the gap inventory.

- **The plan delivers Units 1-21 in 6 phases. The MVP is Units 1-9, 11-13, 16-17 (14 units).** Phase 3 (mapping workbench, FIBO/schema.org suggestions, Turtle export, cross-check brief) is **deferred entirely**. The brainstorm doc lists Phase 3 as the primary deliverable; the plan ships a Phase-1 viewer instead.
- **R9–R12 (data shape profiling) was supposed to deliver record counts, null rates, distinct counts, top-N, length/range stats, sample values.** What landed in run 9:
  - `object_profiles.record_count`: **NULL for all 123 objects.** R9 is not satisfied.
  - `field_profiles.sample_values`: **0 fields have samples.** R12 is not satisfied (even for non-sensitive fields where samples should be collected).
  - `field_profiles.top_values`: only 936 of 4,554 fields (20.5%) have any top values. R10 partially satisfied.
  - `field_profiles.null_rate`: 3,065 of 4,554 (67%) have null_rate populated. R9 partially satisfied.

  The README + reports infrastructure ships, but the underlying data is incomplete. Designers using `/objects/show` will see fields with no record-count and no samples on most fields. The headline success criterion ("'Is this field actually used?' and 'What values appear in this field?' are answerable from per-object pages") **fails on a majority of fields**.

- **The plan claims `complete_with_warnings` as a status for partial-profile failures.** Run 7 has 20 partial failures (PG NotNullViolation on `sampled` column) and its status is `complete`. The state transition logic was either not implemented or silently bypassed.
- **Gap 11 (picklist translation, ~342 fields × ~4,300 values) is Decision #7 with "Stephen + Andreas" as owners, no timeline.** Plan Unit 14 (top-N + sample values) is the prerequisite for designers to know what each picklist's values mean — but Unit 14's top_values only ran on 20% of fields, and the picklist-specific report (`/reports/picklists`) was added late (it appears as `app/views/reports/picklists.html.erb` in git status — uncommitted at the time of review). The "decide vocabularies before first sync" trigger is unrealistic without a working translation surface.
- **Plan Unit 18 (modularity clustering) shipped, but the output is unusable.** Two clusters named "Call Center", two clusters named "Account", 32 objects in one bucket that mixes `sfsrm__Collection_Forecast__c` with `ProfileSkillEndorsement`. The "Reset to auto-cluster" button (Unit 18 approach) would *worsen* the persisted clusters by overwriting any manual fix-up. The persisted-cluster + manual-override design assumed the auto-cluster was a reasonable starting point; in practice the cluster map's 8 hand-curated clusters are the only usable input.
- **Sensitive-data UX (plan §"Sensitive-Data UX") is built assuming sensitive runs are rare.** All 9 runs in the DB are `include_sensitive=false`. The UX work (lock icons, redacted cells, role-gated views) is dead code paths until a sensitive run is triggered. Given the PII leakage found in supposed-non-sensitive run 9, the priority is fixing the classifier — not polishing the sensitive UI.

## Surprises

1. **The classifier marks the discrete name parts as `safe`, not the compound Name.** Plan Unit 12 says: "Contact.LastName (with FirstName sibling) → pii". The actual DB: `Contact.Name = pii`, `Contact.FirstName = safe`, `Contact.LastName = safe`. The sibling-check appears to mark the compound Name PII and leave the parts unmarked. So extracting FirstName/LastName via the API will not trigger redaction. **This is the opposite of what the design intended.**

   ```sql
   SELECT sf.api_name, sf.sensitivity FROM sfields sf JOIN sobjects so ON so.id = sf.sobject_id
   WHERE so.extraction_run_id = 9 AND so.api_name = 'Contact'
     AND sf.api_name IN ('Name','FirstName','LastName');
   -- Name      | pii
   -- FirstName | safe
   -- LastName  | safe
   ```

2. **`sobjects.namespace_prefix` and `sfields.namespace_prefix` are NULL for every row.** The relational loader (Unit 11) drops the namespace metadata silently. Anything querying these columns gets wrong answers — yet the EDA, the cluster map, and the comparison doc all rely on the namespace split. Their numbers were sourced from elsewhere (the JSONL files, presumably).
3. **`ContentDocument.ParentId` has 324,228 rows pointing at one ID** (`0584R0000009u6eQAA`). That's a single record holding the entire org's content. Either that record is a "Files" pseudo-folder, or there's been a hierarchy collapse that flattened all attachments under one entity. Either way, the new ontology's "Attachment polymorphic on Invoice/Dispute/Account" assumption (comparison doc, Cluster 5) doesn't survive — most attachments aren't linked to anything that resembles a domain entity in the source.
4. **`Cashline Solutions` itself is a row in `Brand__c`.** The Operator-vs-Client distinction the platform makes (`Operator` as the top tenant, `Client::Organization` as the customer-of-operator) doesn't exist in the source. There's just `Brand__c` with Cashline Solutions in there alongside the customers. The migration needs an explicit "this Brand becomes the Operator" rule, or all 67 Brands become Clients including Cashline itself.
5. **6 French-labeled fields and 1 with a curly quote.** `Date d'échéance` uses `’` (U+2019, RIGHT SINGLE QUOTATION MARK) in its label. UTF-8 handling needs to be tested throughout the ingest path — labels are user-facing, and a CSV export that downgrades to ASCII will turn this into `Date d???ch??ance` or worse.
6. **The 67 Brand__c rows include "NewparkResources_Inactive" and "BnLPipecoServices_Inactive".** Brands have a soft-delete naming convention (suffix `_Inactive`) rather than a flag. The new ontology needs to choose: do those Brands migrate (and get a `status: archived` field), or are they cut? Currently neither plan nor cluster map mentions this.
7. **Multi-currency tells a US-Latin America-Canada-UK story.** Currency distribution suggests Cashline has clients with debtors in Argentina (ARS), Brazil (BRL), Trinidad (TTD), Colombia (COP), Norway (NOK), Australia (AUD), UK (GBP), Europe (EUR), Canada (CAD), and US (USD). The Phase-1 dashboards have no internationalization story.
8. **Recent activity is exactly the day before extraction.** `Open_Invoices__c.Approval_Date__c` top value: 2026-05-19 (2551 rows) — extraction ran 2026-05-24. Data freshness in the platform is ~24h source-of-truth. If extraction is daily, lag is ≤24h; if weekly, anything in flight in the last week is missing. The plan never commits to a refresh cadence.
9. **The "Owner / RecordType / Profile" claim that polymorphic refs reference ~150 objects** (EDA §4) is conservative. The DB shows `ApprovalSubmission.RelatedRecord` and `ApprovalWorkItem.RelatedRecord` reference **141 distinct objects each**. Some references include objects not even in the extracted run (e.g., `Customer_Communication__c`, `Lien_Law__c`, `Tax_Amount_Configuration__c`). The walk-termination rule (R1) successfully bounded the extraction, but the polymorphic targets it discovered include objects the operator chose not to walk — designers seeing those names in the UI will be confused.

---

The review was performed against run 9 only. A repeat against a sensitive run, after the classifier fixes and `record_count` backfill, would surface additional findings.
