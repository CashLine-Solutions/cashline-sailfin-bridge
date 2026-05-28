# Sailfin EDA — 2026-05-27

Exploratory data analysis of the Sailfin Salesforce metadata extract.

- **Source:** `storage/runs/2026-05-24T23-27-12Z-be06/`
- **Shape:** 123 object `describe` payloads (1 JSONL line each, ~8.2 MB total)
- **Tooling:** `/tmp/sailfin_eda.rb` (one-shot script — not committed)
- **Companion docs:** [sailfin-cluster-map.md](sailfin-cluster-map.md), [cashline-platform-ontology-comparison.md](cashline-platform-ontology-comparison.md)

This report focuses on **schema metadata only**. The extract contains object/field
descriptions, not customer rows.

---

## 1. Namespace / package breakdown

The 123 objects split across four namespaces:

| Count | %      | Namespace          | Notes |
|------:|-------:|--------------------|-------|
|    77 | 62.6%  | `(standard)`       | Stock Salesforce objects (Account, Contact, Case, …) |
|    35 | 28.5%  | `sfsrm__`          | Sailfin's primary managed package (collections/receivables) |
|     7 |  5.7%  | `(custom-no-ns)`   | Org-local custom objects: `Account_Brand_Association__c`, `Brand__c`, `Business_Entity__c`, `DSO_Report__c`, `Open_Invoices__c`, `Reporting_Client__c`, `Weekly_AR_Snapshot__c` |
|     4 |  3.3%  | `sfcapp__`         | `Bank_Statement_Remittance__c`, `Cash_App_Configuration__c`, `GL_Account__c`, `Payment_Batch__c` — a smaller cash-application package |

**Read:** the org is built on `sfsrm` as the system of record for collections,
with a thin layer of org-local custom objects bolted onto standard CRM (Account,
Brand) and a separate `sfcapp` package handling cash-application/bank-remit.

---

## 2. Schema shape

### Field totals
- **4,554 fields** across 123 objects
- **Mean 37 fields/object**, **median 21**, **max 438** (`sfsrm__Transaction__c`)

| min | p25 | median | mean | p75 | p90 | max |
|----:|----:|-------:|-----:|----:|----:|----:|
| 1   | 15  | 21     | 37.0 | 35  | 67  | 438 |

The mean is ~75% larger than the median — a few mega-objects pull the average
up. The bottom half of objects are slim (≤21 fields).

### Top 10 widest objects

| Fields | Custom | Object |
|-------:|-------:|--------|
|    438 |    426 | `sfsrm__Transaction__c` |
|    355 |      0 | `Profile` |
|    352 |    295 | `Account` |
|    183 |      3 | `User` |
|     86 |     45 | `EmailMessage` |
|     77 |     25 | `Event` |
|     76 |      0 | `Network` |
|     76 |      9 | `Contact` |
|     76 |     64 | `sfsrm__Dispute__c` |
|     71 |     60 | `sfsrm__Payment_Line__c` |

Two centers of mass:
1. **`sfsrm__Transaction__c`** — 438 fields, 426 custom, 145 formulas. The
   workhorse table for receivables.
2. **`Account`** — 352 fields, 295 custom (83.8% of its fields are extensions),
   121 formulas. Account is being used as a wide CRM-plus-AR-summary record.

### Field type histogram

| Type            | Count | % of fields |
|-----------------|------:|------------:|
| string          |   985 | 21.6% |
| boolean         |   859 | 18.9% |
| reference (FK)  |   582 | 12.8% |
| datetime        |   535 | 11.7% |
| picklist        |   363 |  8.0% |
| double          |   313 |  6.9% |
| textarea        |   214 |  4.7% |
| date            |   182 |  4.0% |
| currency        |   169 |  3.7% |
| id              |   123 |  2.7% |
| int             |    77 |  1.7% |
| percent         |    60 |  1.3% |
| phone / url / email / address | 85 | 1.9% (combined) |
| multipicklist / combobox / base64 / location | 7 | 0.2% |

Notable:
- **19% boolean** — heavy use of flags (typical of process-automation-heavy SF orgs).
- **8% picklists, 7,999 values total** (~22 values/picklist average) — picklist
  inventory is a real surface; worth its own report if we map enums to the
  ontology.
- **Only 19 email fields and 26 phone fields** across the whole schema — most
  contact handles live on `Contact`/`User`/`Account`.

### Field-level flags

| Flag                 | Count  | % of fields |
|----------------------|-------:|------------:|
| `custom`             |  1,573 | 34.5% |
| `nillable`           |  2,667 | 58.6% |
| `calculated`         |    392 |  8.6% |
| `unique`             |     15 |  0.3% |
| `externalId`         |     14 |  0.3% |
| `autoNumber`         |     30 |  0.7% |
| `encrypted`          |      0 |  0.0% |
| `deprecatedAndHidden`|      0 |  0.0% |

**One-third of all fields are custom**, and **9% are calculated/formula** —
expect mapping work to spend disproportionate time on these.

The lack of encrypted/deprecated fields is itself a finding: the org has not
enabled Shield encryption, and there is no metadata-level deprecation flag we
can rely on for sunsetting (we'll need usage signal from rows instead).

---

## 3. Customization signal

- **46 custom objects / 77 standard** (37% custom-object share)
- **0 deprecated/hidden objects** at the metadata layer
- All 123 objects are `queryable`; 105 `createable`, 109 `updateable`, 100
  `deletable` — the ~20 read-only objects are SF system tables (Network,
  Profile, etc.).
- **`feedEnabled` on 13 objects** — Chatter is on for a curated set.
  `activateable` on only 2 (Contract, Product2).

### Standard objects most heavily extended

| Custom fields added | Total fields | % custom | Object |
|--------------------:|-------------:|---------:|--------|
|                 295 |          352 |   83.8%  | `Account` |
|                  45 |           86 |   52.3%  | `EmailMessage` |
|                  25 |           77 |   32.5%  | `Event` |
|                  25 |           68 |   36.8%  | `Task` |
|                   9 |           76 |   11.8%  | `Contact` |

**`Account` is the most over-extended standard object** — 83.8% of its fields
were added by Sailfin. This is the highest-risk mapping surface: any ontology
that treats `Account` as the standard SF shape will miss the bulk of the data.

### Heaviest formula/calculated logic

| Formula fields | Object |
|---------------:|--------|
|            145 | `sfsrm__Transaction__c` |
|            121 | `Account` |
|             23 | `sfsrm__Dispute__c` |
|             18 | `sfsrm__Payment_Line__c` |
|             15 | `sfsrm__Collection_Forecast__c` |

Two objects (`Transaction`, `Account`) hold **68% of all formula logic** in the
org. These are the rollup/derivation centers — when their inputs change,
downstream consumers feel it.

---

## 4. Relationships

> The naive fan-in count is dominated by **system fields**
> (`OwnerId`/`CreatedById`/`LastModifiedById`/`ProfileId`/`ParentId`) and
> **polymorphic mega-refs** (`ApprovalWorkItem` and `ApprovalSubmission` each
> reference ~150 objects). The numbers below **exclude both**, surfacing
> business relationships only.

### True fan-in hubs (business edges only)

| Inbound business refs | Object |
|----------------------:|--------|
| 50 | `User` |
| 35 | `Account` |
| 15 | `EmailTemplate` |
| 15 | `Contact` |
| 11 | `Profile` |
| 11 | `Organization` |
|  6 | `sfsrm__Transaction__c` |
|  6 | `Individual` |
|  5 | `Lead` / `ContentDocument` / `Asset` / `ContentAsset` |
|  4 | `sfsrm__Payment__c` / `Brand__c` / `Network` / `Location` |

**`Account` is the dominant business hub** (35 inbound). `User` is higher (50)
but a large share of those are assignment/owner-style refs on operational
objects; `Account` is the customer-data hub.

### True fan-out (objects making many distinct business references)

| Distinct targets | Object |
|-----------------:|--------|
| 13 | `CommSubscriptionConsent` |
|  8 | `WorkOrder` |
|  7 | `EmailMessage` / `SocialPost` / `WorkOrderLineItem` |
|  6 | `Order` / `Opportunity` |
|  5 | `Task` / `Event` / `Account` |

Two patterns:
- **Engagement objects** (`EmailMessage`, `Task`, `Event`, `SocialPost`) reach
  across many entities — typical CRM activity pattern.
- **`Account`** itself has 5 outbound refs — Sailfin uses Account-to-Account
  hierarchy plus refs to Brand, Owner, RecordType.

### Junction-object candidates

Filtered to custom objects with 2–3 distinct business targets and <30 fields:

- **Real junction:** `Account_Brand_Association__c` (Account ↔ Brand) — the
  only clean N-to-N join in the dataset.
- **Likely junctions:** `sfsrm__Line_Item__c` (Transaction ↔ Account),
  `sfsrm__Collector_Target__c` (Collection_Forecast ↔ User).
- **Configuration singletons (false positives):** ~10 `sfsrm__*_Configuration__c`
  objects + `sfcapp__Cash_App_Configuration__c` each reference
  `Organization` + `Profile` + `User`. These are admin/settings records, not
  true junctions — `Organization` and `Profile` refs indicate "this setting
  belongs to this org/profile scope," not a relationship.

### True orphans

13 objects have **zero business inbound AND zero business outbound** refs
(once system fields are removed). All are config tables, reporting snapshots,
or staging tables:

- **Reporting snapshots:** `Open_Invoices__c`, `Weekly_AR_Snapshot__c`, `DSO_Report__c` (not orphaned — see below)
- **Config/lookup tables:** `sfsrm__Archival_Configuration__c`,
  `sfsrm__Case_Manager__c`, `sfsrm__Data_Service__c`,
  `sfsrm__Email_Log_Monitor__c`, `sfsrm__Object_Configuration__c`,
  `sfsrm__Screens__c`, `sfsrm__Temp_Object_Holder__c`, `sfcapp__GL_Account__c`
- **Productivity/observability:** `sfsrm__Collector_Productivity__c`
- **Other:** `Business_Entity__c`, `Solution`

These don't need to participate in the entity graph — they're either
denormalized reporting tables or admin singletons. **None of them should appear
in a customer-facing ontology view** without a clear annotation.

### Cross-namespace edges

| Edges | From → To |
|------:|-----------|
|   166 | `(standard)` → `sfsrm` |
|    81 | `(standard)` → `(custom-no-ns)` |
|    81 | `sfsrm` → `(standard)` |
|    16 | `(standard)` → `sfcapp` |
|    14 | `(custom-no-ns)` → `(standard)` |
|     9 | `sfcapp` → `(standard)` |
|     3 | `sfcapp` → `sfsrm` |
|     1 | `sfsrm` → `sfcapp` |
|     1 | `sfsrm` → `(custom-no-ns)` |

**Standard ↔ sfsrm dominates** (166 + 81 = 247 edges). Standard SF and the
collections package are tightly woven; you cannot meaningfully model one
without the other. `sfcapp` is loosely coupled (28 edges total in/out, mostly
to standard objects) — it could be migrated/replaced more independently.

### Self-referencing hierarchies

24 objects reference themselves (Account/ParentId, Case/ParentId, etc.). Worth
flagging for graph traversal in the mapper: these need cycle detection.

---

## 5. Headline takeaways for the ontology

1. **Two-center gravity:** the entire data model orbits `Account` and
   `sfsrm__Transaction__c`. Any mapping work that doesn't have full coverage of
   these two objects (~790 fields combined, 266 formulas) will leak.
2. **`Account` is not a standard `Account`:** 83.8% of its fields are custom.
   Treat it as a Sailfin-specific entity.
3. **`sfcapp` is the loose joint:** weakest cross-namespace coupling (~28
   edges). If we ever modularize the extraction, this is the natural seam.
4. **13 orphan/config tables can be hidden by default** in any
   relationship-graph view (the existing `/reports/hub_orphan` already surfaces
   these; this report names them).
5. **Picklists are a non-trivial surface:** 8,000 picklist values across 366
   fields. Worth a dedicated mapping pass once the entity layer is settled.
6. **Formula-heavy objects = blast-radius risk:** changes to inputs feeding the
   145 formulas on `Transaction` and 121 on `Account` will ripple silently.
   Worth a separate "formula dependency" report later.

---

## 6. What this report does not cover

- **Row data.** This is metadata only; no profiling of value distributions,
  null rates, or cardinality from actual records. The
  [`object_profiles`](../../app/models/object_profile.rb) /
  [`field_profiles`](../../app/models/field_profile.rb) tables, populated by
  the profiling stage, are where that would live.
- **Picklist value inventory.** Counted (8K values) but not listed.
- **Formula dependency graph.** Counted (392 calculated fields) but not parsed.
- **Sharing / FLS / record-type rules.** Not in the describe payload at the
  level we sample it.
