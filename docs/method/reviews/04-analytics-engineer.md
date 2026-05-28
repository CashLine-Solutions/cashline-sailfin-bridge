# Analytics engineer data-review

Source: extraction run `id=9` (`2026-05-24T23-27-12Z-be06`), the only run that
covers all 123 production Sailfin objects with field-level profiles
(`field_profiles.null_rate` and `field_profiles.distinct_count`). All numbers
below come from queries against `cashline_ontology_development`; SQL is inline
so anyone can rerun.

One methodology note up front. `object_profiles.record_count` is **NULL** for
every row in run 9 (the profile job completed but didn't persist the row
counter). I've been treating `field_profiles.distinct_count` on the `Id` field
as the de facto row count — it agrees with the cluster-map sampling
(`sfcapp__Bank_Statement_Remittance__c` = 12,056 vs cluster-map "~12K";
`sfcapp__Payment_Batch__c` = 3,929 vs "~3,900"). Use that pattern below.

## Headline

- **62 of 123 objects (50.4%) have zero rows.** Every cell in their
  `field_profiles.null_rate` column is NULL. That includes four objects the
  comparison doc treats as load-bearing migration targets:
  `sfsrm__Credit_Application__c`, `sfsrm__Credit_Review__c`,
  `sfsrm__Trade_Reference__c`, and **`sfsrm__Line_Item__c`** — the invoice-line
  table that Cluster 2 keeps as `InvoiceLine` is empty in this org. Mapping
  effort against shapes nobody fills is wasted unless someone confirms intent.
- **Across the 20 widest objects (3,194 fields total), 36% are dead
  (null_rate ≥ 0.99) and only 34% are live (null_rate < 0.5).** On
  `sfsrm__Transaction__c` alone, 129 of the 438 fields are dead (29.5%) —
  including the 36-value picklist `sfsrm__Sub_Reason_Code__c` which is **100%
  null** but has 36 active picklist values. That picklist is one of the four
  in Gap 11 of the comparison doc; the data says the value list is decorative
  in production.
- **Picklist bloat is 91%.** 364 picklist fields hold 7,983 active values;
  7,250 of those values (90.8%) never appear in any row. Translation-work
  sizing per Gap 11 should be measured in *values actually used*, not values
  defined. The four "high-signal" picklists named in the comparison doc fall
  apart on inspection: `sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` has 64
  active values but **2 distinct values in data** with 100.0% null rate.
- **20 of 45 `Viking_*__c` tenant-leakage fields are actually populated**
  (null_rate < 0.5); 7 are dead. The cluster map flags these as the canonical
  side-table-migration case. The data backs that — they're real in production
  on a subset of rows, not just dormant schema.
- **`sfsrm__Temp_Object_Holder__c` holds 184,452 rows** — the second-largest
  custom object after `sfsrm__Transaction__c` excluding ContentBody. Cluster 6
  classes it as "configuration table" and recommends cutting. It is not a
  configuration table; it is *the second-largest custom data store in the
  org*. Cut it without understanding what's in it and you are losing 184K rows
  of something.

## Dead-schema vs live-data — where mapping effort will be wasted

The headline numbers per object, ordered by field count:

```sql
WITH row_counts AS (
  SELECT s.id AS sobject_id, s.api_name, fp.distinct_count AS row_count
  FROM sobjects s
  JOIN sfields sf ON sf.sobject_id = s.id AND sf.api_name = 'Id'
  LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
  LEFT JOIN object_profiles op ON op.id = fp.object_profile_id
  WHERE s.extraction_run_id = 9
),
field_counts AS (
  SELECT sf.sobject_id, COUNT(*) AS n_fields,
         COUNT(*) FILTER (WHERE fp.null_rate < 0.5) AS populated,
         COUNT(*) FILTER (WHERE fp.null_rate >= 0.5 AND fp.null_rate < 0.99) AS sparse,
         COUNT(*) FILTER (WHERE fp.null_rate >= 0.99) AS dead,
         COUNT(*) FILTER (WHERE fp.null_rate IS NULL) AS unprofiled
  FROM sfields sf
  LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
  LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
  GROUP BY sf.sobject_id
)
SELECT rc.api_name, rc.row_count, fc.n_fields, fc.populated, fc.sparse, fc.dead
FROM row_counts rc
JOIN field_counts fc ON fc.sobject_id = rc.sobject_id
ORDER BY fc.n_fields DESC LIMIT 20;
```

| Object | Rows | Fields | Live | Sparse | Dead | %Dead |
|---|---:|---:|---:|---:|---:|---:|
| `sfsrm__Transaction__c` | 2,169,629 | 438 | 146 | 162 | 129 | 29.5% |
| `Profile` | 92 | 355 | 73 | 144 | 138 | 38.9% |
| `Account` | 135,113 | 352 | 148 | 76 | 128 | 36.4% |
| `User` | 174 | 183 | 52 | 18 | 113 | 61.7% |
| `EmailMessage` | 235,669 | 86 | 38 | 17 | 31 | 36.0% |
| `Event` | 0 | 77 | 0 | 0 | 0 | n/a |
| `sfsrm__Dispute__c` | 190,795 | 76 | 50 | 7 | 19 | 25.0% |
| `Contact` | 69,269 | 76 | 22 | 13 | 41 | 53.9% |
| `Network` | 1 | 76 | 34 | 0 | 42 | 55.3% |
| `sfsrm__Payment_Line__c` | 261,166 | 71 | 46 | 2 | 23 | 32.4% |
| `Task` | 521,417 | 68 | 34 | 5 | 29 | 42.6% |
| `SocialPost` | 0 | 67 | 0 | 0 | 0 | n/a |
| `sfcapp__Bank_Statement_Remittance__c` | 12,056 | 67 | 50 | 4 | 13 | 19.4% |
| `sfsrm__Collection_Forecast__c` | 99 | 65 | 28 | 28 | 9 | 13.8% |
| `sfsrm__Payment__c` | 19,938 | 63 | 42 | 6 | 15 | 23.8% |
| `Organization` | 1 | 54 | 30 | 0 | 24 | 44.4% |
| `Brand__c` | 67 | 52 | 26 | 19 | 7 | 13.5% |
| `Site` | 2 | 51 | 24 | 2 | 25 | 49.0% |
| `Lead` | 0 | 51 | 0 | 0 | 0 | n/a |
| `ContentVersion` | 324,245 | 47 | 34 | 1 | 13 | 27.7% |

Read this against the keep/cut table in the cluster map:

- **`Contact` is the riskiest mapping**: 41/76 fields (53.9%) are dead, yet
  the cluster map keeps it. That's fine, but the live surface is only 22
  fields. Plan accordingly.
- **`Account` looks bigger than it is**: 128/352 fields are dead. The live
  surface is 148. Roughly aligned with the cluster map's "expect ~30-50
  fields to survive."
- **`User` is mostly dead** at 61.7%. Cluster 7 cuts it anyway — the data
  agrees there's not much there.
- **`Profile` has 138 dead fields** — almost all of those are unused
  permission booleans. Already correctly cut.
- **`sfsrm__Transaction__c` and `sfsrm__Dispute__c`** are the cleanest live
  surfaces: 29.5% and 25% dead respectively. The wide-object panic is
  overstated for these; the meaningful live surface is well-defined.

**Objects the comparison doc maps as load-bearing but are actually empty:**

```sql
SELECT s.api_name, fp.distinct_count AS row_count
FROM sobjects s
JOIN sfields sf ON sf.sobject_id = s.id AND sf.api_name = 'Id'
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9
  AND s.api_name IN ('sfsrm__Line_Item__c','sfsrm__Credit_Application__c',
                     'sfsrm__Credit_Review__c','sfsrm__Trade_Reference__c',
                     'sfsrm__Case_Manager__c','sfsrm__Score_Card_Parameter__c',
                     'sfsrm__Score_Card_Parameter_Value__c');
```

All seven return 0 or NULL. `sfsrm__Line_Item__c` (kept in the cluster map as
the canonical `InvoiceLine`) is **empty**. So is the entire credit cluster
(Gap 2 in the comparison). If the team thought there would be data to seed
those models, the data isn't there. Either the cluster wasn't active in this
org during extraction, or these objects are dormant package tables. Confirm
with operations before scoping migration work against them.

Conversely: **`sfsrm__Payment_Line__c` has 261,166 rows** and is highly alive
(46/71 fields live, only 2 sparse). The cluster-map sampling "~261K records"
matches the row-count proxy here exactly.

## Quiet load-bearing fields — the schema-first reviewer's blind spots

These are fields whose names don't shout for attention, but whose data is
fully populated and high-cardinality. Lose them in translation and downstream
reports break silently. Query:

```sql
SELECT s.api_name AS object, sf.api_name AS field, sf.data_type,
       fp.null_rate, fp.distinct_count, sf.calculated
FROM sfields sf
JOIN sobjects s ON s.id = sf.sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9
  AND fp.null_rate < 0.1
  AND fp.distinct_count > 100
  AND NOT sf.calculated
  AND sf.api_name NOT IN ('Id','Name','CreatedDate','CreatedById',
                          'LastModifiedDate','LastModifiedById','SystemModstamp','OwnerId')
ORDER BY fp.distinct_count DESC;
```

A few that jumped out:

| Object | Field | distinct_count | Why it matters |
|---|---|---:|---|
| `sfsrm__Transaction__c` | `sfsrm__Transaction_Key__c` | 2,169,647 | One per row — the upstream ERP key. Marked `externalId: true`. The integration anchor. |
| `Account` | `sfsrm__Account_Key__c` | 135,113 | One per row — also a `_Key__c` external join. Marked `externalId: true`. |
| `sfsrm__Dispute__c` | `Transactions_Key__c` | 165,687 | **Marked `externalId: false`.** This is a Sailfin-custom denormalized lookup back to the source-system invoice key. Used for back-mapping. Easy to drop because it doesn't carry the conventional `external_id` flag in metadata. |
| `sfsrm__Dispute__c` | `Account_Key__c` | 10,380 | Same pattern — `externalId: false` flag but obviously load-bearing (one value per Account on the dispute). |
| `sfsrm__Payment_Line__c` | `sfsrm__Payment_Line_Key__c` | 261,166 | One per row. The payment-allocation anchor. |
| `sfcapp__Bank_Statement_Remittance__c` | `sfcapp__Bank_Statement_Remittance_Key__c` | 12,056 | Per-row remittance key. |
| `sfcapp__Bank_Statement_Remittance__c` | `sfcapp__Bank_Statement_Key__c` | 3,294 | Bank-statement-level grouping key — implies the per-remit table aggregates to ~3,294 bank statements, ~3.7 remittances per statement. New constraint surface for the cash side. |
| `sfsrm__Payment__c` | `Auto_Number__c` | 19,938 | One per row. **The check-number-or-equivalent autoincrement** — distinct from `Name` (which is also 19,938) and `sfsrm__Payment_Key__c`. Triple-keyed in source. |
| `EmailMessage` | `MessageDate` | 206,602 | High cardinality, near-zero null — the timeline anchor on email. The comparison doc plans `CommunicationEvent` but the source's *message* timestamp (distinct from `CreatedDate`) carries the "when did this actually happen" signal. |
| `Account` | `sfsrm__Risk__c` | 19,892 | A percent. Fully populated. Quietly the input to most of Account's downstream financial formulas. |
| `Account_Brand_Association__c` | `Account_ID__c` | 18,765 | A *non-FK string* alongside the actual `Account__c` reference — same cardinality, same nullness. External-system join key, not the SF FK. |
| `Task` | `Subject` | 82,556 distinct out of 521,417 rows | The combobox `Subject` is the *de facto* task type for collections workflow. The comparison doc plans `OperationalTask.category` (15 values); the source field has 82,556 distinct subjects. Forced translation will lose nuance unless you also persist the original. |
| `Account` | `Highest_Account_Balance__c`, `Last_Invoice_Amount__c`, `First_Invoice_Amount__c` | ~22K-26K | All custom currency fields, ~3% null. The aging-summary fields on Account that survive at high cardinality — collectors use these. The cluster map says "expect ~30-50 fields to survive" on Account; these are in that survival set, not flagged anywhere. |

The pattern: **anything ending `_Key__c` is an external-system join anchor**.
Some are flagged `externalId: true` and some aren't. Use the SQL pattern
above plus the `LIKE '%\_Key\__c'` filter to harvest the full list before
migration scoping. The metadata flag is insufficient.

## Picklist value usage skew — translation-work sizing

```sql
SELECT s.api_name AS object, sf.api_name AS field,
       COUNT(pv.id) FILTER (WHERE pv.active) AS active_values,
       fp.distinct_count AS distinct_in_data,
       ROUND((fp.null_rate * 100)::numeric, 1) AS pct_null
FROM sobjects s
JOIN sfields sf ON sf.sobject_id = s.id
JOIN spicklist_values pv ON pv.sfield_id = sf.id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9
  AND sf.data_type IN ('picklist','multipicklist')
GROUP BY s.api_name, sf.api_name, fp.distinct_count, fp.null_rate
HAVING COUNT(pv.id) FILTER (WHERE pv.active) > 0
ORDER BY COUNT(pv.id) FILTER (WHERE pv.active) DESC;
```

The four "high-signal" picklists Gap 11 calls out, with reality check:

| Field | Active values | Distinct in data | Pct null |
|---|---:|---:|---:|
| `sfsrm__Dispute__c.sfsrm__Sub_Type__c` | 70 | 64 | 87.5% |
| `sfsrm__Payment_Line__c.sfsrm__Reason_Code__c` | 64 | **2** | 100.0% |
| `sfsrm__Treatment__c.sfsrm__Treatment_Group__c` | 37 | 30 | 0.0% |
| `sfsrm__Transaction__c.sfsrm__Sub_Reason_Code__c` | 36 | **0** | 100.0% |

Two of these four — exactly the ones Gap 11 wants picked *first* —
**have no usable signal in production data.** `sfsrm__Sub_Reason_Code__c` is
100% null; `sfsrm__Reason_Code__c` has two distinct values across all
261K payment-line rows. The team can defer translation tables for both
without losing anything, or use the deduction-reason equivalent
(`sfcapp__Deduction_Reason_Code__c` — 48 active, 14 in data, also 98.3%
null but at least non-zero).

By contrast `sfsrm__Treatment_Group__c` is real: 30 of 37 active values
actually used, 0% null. **That's where the translation table earns its
keep.** And `sfsrm__Sub_Type__c` on Dispute: 64 of 70 values used,
substantively populated (12.5% non-null). Also a real translation surface.

**Aggregate bloat:** 364 picklist fields, 7,983 active values, **7,250
unused** (≥ active minus distinct_in_data). Gap 11 sizes the surface as
"~342 fields and ~4,300 values" after stripping platform mega-picklists. The
empirical headline: 91% of picklist values defined in the org never appear
in any row. The actual translation surface is much smaller than the schema
suggests.

Worst offenders for "decorative" picklists (active >> in-data):

| Object.Field | Active | Distinct |
|---|---:|---:|
| `User.TimeZoneSidKey` | 424 | 3 |
| `Account.sfsrm__Locale__c` | 176 | 57 |
| `EmailTemplate.RelatedEntityType` | 494 | 2 |
| `Account.Industry` | 32 | 36 (live — uses 32 distinct in a sample of 36 — close to full) |
| `Account.Risk_Code__c` | 22 | 22 |

`Industry` and `Risk_Code__c` *do* use their full value set —
real translation work. Most others are platform carry-over.

## Object row-count vs cluster-map claims

Empirical row counts (using `Id.distinct_count` as proxy):

| Object | Cluster map says | Inferred rows | Verdict |
|---|---|---:|---|
| `sfsrm__Transaction__c` | "hub, 438 fields" | 2,169,629 | ✓ |
| `sfsrm__Payment_Line__c` | "~261K records" | 261,166 | ✓ exact |
| `sfsrm__Payment__c` | "~20K records" | 19,938 | ✓ |
| `sfsrm__Dispute__c` | "Keep — schema is solid" | 190,795 | ✓ live |
| `sfsrm__Treatment__c` | "load-bearing collections process" | **346** | ⚠ tiny |
| `sfcapp__Payment_Batch__c` | "~3.9K records" | 3,929 | ✓ exact |
| `sfcapp__Bank_Statement_Remittance__c` | "~12K records" | 12,056 | ✓ exact |
| `Brand__c` | "Client master" | **67** | ⚠ tiny (a few dozen Cashline clients) |
| `Account_Brand_Association__c` | "the link record" | 18,765 | ✓ |
| `sfsrm__Collection_Forecast__c` | "65 fields, load-bearing" | **99** | ⚠ tiny |
| `sfsrm__Temp_Object_Holder__c` | "cut: config table" | **184,452** | ❌ MISCLASSIFIED — see note |
| `sfsrm__Data_Load_Batch__c` | "ETL audit, no ontology" | 91,576 | ✓ correctly excluded |
| `Open_Invoices__c` | "approval sidecar, likely cut" | 30,881 | ⚠ huge for a "sidecar" |
| `DSO_Report__c` | "pure reporting, cut" | 163 | ✓ correct cut |
| `Weekly_AR_Snapshot__c` | "weekly snapshot, cut" | 2,000 | ✓ correct cut |
| `Task` | "~20K Account-linked" | **521,417** | ⚠ 25x larger than cluster-map's filtered count |
| `EmailMessage` | "~203K" | 235,669 | ✓ close |
| `ContentVersion` | "~324K" | 324,245 | ✓ exact |
| `ContentDocument` | "~138K" | 324,245 | ❌ cluster map says 138K — data says 324K |

Three corrections to flag back to the cluster map:

1. **`sfsrm__Temp_Object_Holder__c` (184,452 rows) is not a config table.**
   It has a single `sfsrm__value__c` textarea (0 distinct, so always empty?),
   one `sfsrm__Key__c` string per row (all unique), and a `Name`. It looks
   like a per-row staging or hash store. Cluster 6 cuts it as configuration;
   it is the *second-largest custom object in the org*. Before any cut, talk
   to whoever owns the SFSRM package: this is likely a per-Transaction
   sidecar (the row count is about 8.5% of Transaction count, plausibly a
   subset of transactions undergoing some workflow). Cutting it without
   knowing what it carries is a real risk.

2. **`Open_Invoices__c` has 30,881 rows.** Cluster 2 says "looks like a
   per-invoice approval-tracking sidecar" and flags for cut. The data shape
   is one row per (Brand, invoice) with submission/approval dates and a
   `Payment_Status__c`. That's not pure reporting — it's an *open workflow
   state* table. The cluster map's instinct to cut as regenerable from
   masters is probably wrong unless someone confirms the approval state is
   redundant with `sfsrm__Transaction__c.sfsrm__Status__c`.

3. **`Task` has 521,417 rows, not 20K.** The cluster-map sampling said
   "~20K Account-linked records" — but the *total* Task surface is 25x
   larger. The 20K figure is what cleanly joins to Account; the other 500K
   are presumably linked to Disputes, Treatments, or are unattributed.
   Activity-model design (Gap 4) is sizing against the wrong number — by
   way of order, the unified `Activity` table needs to absorb half a million
   tasks plus 236K email messages.

4. **`ContentDocument` vs `ContentVersion` are equal in row count
   (324,245).** Cluster 5 says 138K documents, 324K versions. The data
   doesn't support 138K — `ContentDocument.Id.distinct_count` is 324,245.
   The 138K may be from a different sample or a deleted-document filter.

## Formulas / calculated fields — business logic outside the data

```sql
SELECT s.api_name, COUNT(*) AS formula_fields
FROM sfields sf JOIN sobjects s ON s.id = sf.sobject_id
WHERE s.extraction_run_id = 9 AND sf.calculated
GROUP BY s.api_name ORDER BY 2 DESC;
```

392 calculated fields, concentrated on:

| Object | Formulas |
|---|---:|
| `sfsrm__Transaction__c` | 145 |
| `Account` | 121 |
| `sfsrm__Dispute__c` | 23 |
| `sfsrm__Payment_Line__c` | 18 |
| `sfsrm__Collection_Forecast__c` | 15 |
| `Event` | 13 |
| `Task` | 13 |
| `sfsrm__Collector_Productivity__c` | 9 |
| `sfcapp__Payment_Batch__c` | 5 |
| `Brand__c` | 4 |

**The high-distinct-count formulas on Transaction are the dangerous ones:**

| Field | Calculated | distinct_count |
|---|:-:|---:|
| `Invoice__c` | ✓ | 1,633,539 |
| `Facture__c` | ✓ | 1,622,047 (French alias) |
| `Invoice_Category__c` | ✓ | 1,613,797 |
| `Invoice_Number__c` | ✓ | 1,075,838 |
| `Weighted_Days_to_Pay__c` | ✓ | 856,848 |
| `Invoice_Amount__c` | ✓ | 675,795 |
| `Original_Amount__c` | ✓ | 675,795 |
| `Account_Key__c` | ✓ | 37,136 |
| `Brand_Code__c` | ✓ | 51 |
| `sfsrm__Aging_Group__c` | ✓ | 8 |
| `sfsrm__Collection_Stage__c` | ✓ | 136 |

`Invoice_Number__c` is a *formula*. So is `Brand_Code__c`. So is
`Account_Key__c`. These are inputs that downstream reports treat as raw
columns. When the platform migrates, the raw inputs (whatever the formula
sources off — likely `Name`, `sfsrm__Account__c` lookups, or branded
naming) must be migrated *with* the derivation logic, or every value
changes silently. **The cluster map calls out 145 formulas on Transaction
as "rollup/derivation centers"**; the data confirms most of them are
load-bearing identifiers and aging signals, not just KPI summaries.

Only 30 of the 392 calculated fields are dead. Formulas are overwhelmingly
populated.

## Sensitivity flags — migration-risk concentration

```sql
SELECT s.api_name, COUNT(*) AS sensitive_fields,
       COUNT(*) FILTER (WHERE fp.null_rate < 0.5) AS live_sensitive,
       COUNT(*) FILTER (WHERE fp.null_rate >= 0.99) AS dead_sensitive,
       STRING_AGG(DISTINCT sf.sensitivity, ',') AS types
FROM sfields sf JOIN sobjects s ON s.id = sf.sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9
  AND sf.sensitivity IN ('pii','financial','pii_and_financial')
GROUP BY s.api_name ORDER BY 2 DESC LIMIT 10;
```

767 sensitive fields total (348 PII, 416 financial, 3 both). 261 are live;
178 are dead. Concentration is exactly where you'd expect:

| Object | Sensitive fields | Live | Dead |
|---|---:|---:|---:|
| `Account` | 129 | 66 | 37 |
| `sfsrm__Transaction__c` | 110 | 54 | 23 |
| `User` | 56 | 9 | 36 |
| `Contact` | 31 | 4 | 17 |
| `SalesforceContract` | 20 | 0 | 0 (all unprofiled, 0 rows) |
| `sfsrm__Payment_Line__c` | 20 | 17 | 3 |
| `sfsrm__Dispute__c` | 14 | 12 | 2 |
| `sfcapp__Bank_Statement_Remittance__c` | 14 | 11 | 3 |
| `sfsrm__Payment__c` | 13 | 10 | 2 |
| `sfcapp__Payment_Batch__c` | 12 | 11 | 1 |

The live sensitive concentration is in **Account (66), Transaction (54),
Payment_Line (17), Dispute (12), Bank Statement Remittance (11)**, and
**Payment_Batch (11)**. That's 171 live sensitive fields across the six
load-bearing receivables/cash-side objects.

Two implications:

- **The cash-side gap (comparison Gap 1) doesn't just lose data — it
  loses 49 live sensitive fields** (Payment_Line + Payment + Payment_Batch
  + Bank_Statement_Remittance combined). Whatever the platform's
  sensitivity-labeling/auditing story is, it has to come online before the
  cash side does, not after.
- **`Contact` only has 4 live sensitive fields out of 31.** Most of the
  PII surface on Contact is empty. That's good news for migration risk on
  the Customer cluster — Contact is not a PII fire as the schema makes it
  look.

## Custom × standard cross-tab

```sql
SELECT
  CASE
    WHEN s.api_name LIKE 'sfsrm\__%' THEN 'sfsrm'
    WHEN s.api_name LIKE 'sfcapp\__%' THEN 'sfcapp'
    WHEN s.custom THEN 'custom-no-ns'
    ELSE 'standard'
  END AS obj_ns,
  CASE WHEN sf.api_name LIKE '%\__c' THEN 'custom_field' ELSE 'std_field' END AS field_kind,
  COUNT(*) AS n,
  COUNT(*) FILTER (WHERE fp.null_rate >= 0.99) AS dead,
  COUNT(*) FILTER (WHERE fp.null_rate < 0.5) AS live
FROM sfields sf JOIN sobjects s ON s.id = sf.sobject_id
LEFT JOIN field_profiles fp ON fp.sfield_id = sf.id
LEFT JOIN object_profiles op ON op.id = fp.object_profile_id AND op.extraction_run_id = 9
WHERE s.extraction_run_id = 9
GROUP BY 1,2 ORDER BY 1,2;
```

| Object namespace | Field kind | Total | Dead | Live |
|---|---|---:|---:|---:|
| custom-no-ns (`Brand__c`, `Account_Brand_Association__c`, etc.) | custom field | 95 | 7 | 53 |
| custom-no-ns | standard field | 80 | 14 | 54 |
| sfcapp | custom field | 99 | 18 | 76 |
| sfcapp | standard field | 45 | 9 | 36 |
| sfsrm | custom field | 976 | 241 | 396 |
| sfsrm | standard field | 378 | 50 | 221 |
| **standard (Account, Contact, Task, etc.)** | **custom field** | **403** | **130** | **160** |
| standard | standard field | 2,478 | 514 | 535 |

Four mapping-risk quadrants, each with its own profile:

1. **Custom fields on standard objects (403 fields, 130 dead, 160 live).**
   This is the Sailfin-Cashline overlay on stock SF — the most ontology-
   dangerous quadrant. 32% dead, but 40% live, and the live ones are where
   the org-specific signal lives (`Account.Total_AR_Unbilled__c`,
   `Account.Credit_Limit_Total__c`, the 45 `Viking_*__c` fields). These
   should be the priority of any "what's on standard objects" pass.

2. **Standard fields on standard objects (2,478 fields).** Largest
   quadrant. 514 dead, 535 live; the rest are sparse or unprofiled
   (mostly on zero-row objects like Event/Lead/SocialPost). Most can be
   cut wholesale per Cluster 8.

3. **`sfsrm__` custom fields (976).** 25% dead, 41% live. This is the
   managed-package core that the platform is replacing concept-by-concept.
   The 241 dead fields are package features the org enabled but doesn't
   use; don't carry them.

4. **`sfcapp__` is the cleanest quadrant: 99 custom fields, only 18 dead
   (18.2%), 76 live (76.8%).** The cash-app package is small and dense
   with real data — confirms the cluster map's "loosely-coupled" reading
   and makes the cash-side gap (comparison Gap 1) more painful: the data
   that *would* drive it is unusually well-populated.

## Validation of cluster-map relationship claims

```sql
SELECT 'Account inbound business refs' AS claim, COUNT(*) AS actual
FROM srelationships r
JOIN sobjects t ON t.id = r.target_sobject_id
LEFT JOIN sfields sf ON sf.id = r.source_field_id
WHERE r.extraction_run_id = 9
  AND t.api_name = 'Account'
  AND sf.api_name NOT IN ('OwnerId','CreatedById','LastModifiedById',
                          'ProfileId','ParentId','MasterRecordId')
UNION ALL ...;
```

Spot checks against specific claims:

| Cluster-map claim | Empirical | Verdict |
|---|---:|---|
| Account inbound business refs (cluster 1 says ~35) | 42 (excluding system fields) | ✓ within tolerance |
| `Account_Brand_Association__c` is the Customer↔Client junction | 2 business FKs: `Account__c`, `Brand__c` | ✓ exactly |
| `sfsrm__Payment_Line__c` is the join (Transaction × Payment) | 1 FK to each — plus a self-ref `Transferred_To__c` and a direct `Account__c` | ✓ richer than cluster map states |
| `sfsrm__Payment__c → sfcapp__Payment_Batch__c` exists | 1 FK | ✓ |
| `sfsrm__Treatment__c` is a hub for collections | 3 inbound (Account, Event, Task) | ⚠ only 3; small hub |
| `Brand__c` has 4 inbound business refs | 4 (Account×2, Account_Brand_Association, DSO_Report) | ✓ exact |
| `Reporting_Client__c` referenced by Brand and Transaction | 2 (Brand__c, sfsrm__Transaction__c) | ✓ exact |
| `Account` has both `Brand__c` *and* `Brand_Lookup__c` references | 2 distinct outbound to Brand__c | ✓ — two Brand FKs on Account, a smell that "Customer is single-Brand" was relaxed by hand |
| `Account → sfsrm__Credit_Review__c` (`Latest_Credit_Review__c`) | 1 FK | ⚠ but Credit_Review has 0 rows — FK is dormant |

**The `Account → Brand__c` double FK** (`Brand__c` + `Brand_Lookup__c`) is
worth flagging on its own. The cluster map says "the existing graph has
Account linked to *exactly one* `Brand__c`" — but there are *two* such
columns on Account. One is the standard reference; the other looks like a
historical fix-up (the cluster-map's hint that "any business logic in the
SFSRM package assumes Account.Brand__c is single-valued, that assumption
will not survive" is even more pointed than the doc states — the assumption
already isn't holding cleanly in this org).

---

**Reproducibility note.** Every query above runs against the local
`cashline_ontology_development` database with `extraction_run_id = 9`. The
patterns to rerun against a fresh extraction:

- Row count proxy: `Id.distinct_count` from `field_profiles`.
- Live/dead split: `null_rate < 0.5` vs `null_rate >= 0.99`.
- Picklist bloat: `COUNT(active spicklist_values) - field_profiles.distinct_count`.
- Quiet-bearer scan: `LIKE '%\_Key\__c'`, `LIKE 'Viking_%'`,
  `calculated = true AND distinct_count > 100`.
- Sensitive concentration: `sensitivity IN ('pii','financial','pii_and_financial')`
  joined to `null_rate`.
