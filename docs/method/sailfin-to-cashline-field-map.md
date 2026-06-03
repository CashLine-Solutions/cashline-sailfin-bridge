# Sailfin → cashline-platform field map

Per-field source proposal for every column on snapshot #1's 32 cashline classes.

## Empirical findings (2026-06-02 partial + 2026-06-03 full data download)

A ~17.6M-row full download of Sailfin (74 populated objects) has been verified against every proposed mapping for the 32 cashline classes. The combined findings:

### From the partial download (2026-06-02)

| Finding | Implication |
|---|---|
| `Account.Description` = **0% populated** | Re-routed `Customer::Account.notes` to `Account.sfsrm__Sticky_Note__c` (99.5%) |
| `Account.Website` = **0% populated** | `Customer::Org.website` is **net_new**; mapping deleted |
| `SalesforceInvoice` table has **0 rows** | `Invoice.total_cents`/`balance_due_cents` are operational (recalculate_totals callback) |
| `sfsrm__Line_Item__c` = **0 rows** | InvoiceLineItem synthesized 1:1 from Transaction |
| `sfsrm__Credit_Application__c` = **0 rows** | `Customer::Org.legal_name` fallback path moot; always `Account.Name` |
| `Account.Brand_Code__c` perfectly 1:1 with `Brand__c.Id`, **53 distinct brands** | Brand dedup key |

### From the full download (2026-06-03)

| Finding | Implication |
|---|---|
| `Account_ID_Text__c` is **byte-identical to `Account.Id`** in 100% of rows | Customer::AccountPortal.account_identifier has **no Sailfin source** — re-tag as net_new |
| `Account.Ecommerce_System__c` actually = **2.39%** (not 6.3% as 10K-sample suggested), 50+ spelling variants | Heavy normalization needed for `submission_channel` value_collapse |
| `Contact.AccountId` is **empty in 27% of rows** | `customer_accounts NOT NULL FK` will reject orphans — needs sync policy |
| `Brand__c` was **NOT downloaded** | Client::Group sourcing (`Brand__c.Reporting_Client__c`) unverifiable; field-map names `Brand_Address__c`/`Brand_State__c`/`Brand_Postal_Code__c` are **wrong** — actuals: `Brand_Street__c`/`Brand_State_Province__c`/`Brand_ZIP_PostalCode__c` |
| `User.CashLine_Employee__c` = 100% boolean (46 true / 129 false) | Canonical operator-vs-client classifier; drives OperatorMembership-vs-Client::Membership routing |
| `Brand_Manager__c` resolves to existing Sailfin Users 100% (5 distinct managers, all `CashLine_Employee__c=true`) | Path B is over-engineered — collapse into a `Client::Organization.brand_manager_user_id` FK |
| `Tax_Amount__c` = **97.0% populated** (2.12M rows) | Confirmed as Invoice.tax_cents source (existing field map already correct) |
| `Amount_Outstanding__c` = 100%, **95.9% are zero** | Strong primary signal for Invoice.status — `paid` = 95.9% just from this field |
| `Ecommerce_Category__c` = 100%, 7 clean values (Not Submitted / Paid / Approved / Submitted / Disputed / In Process / Unknown) | Secondary signal for Invoice.status (portal lifecycle) |
| `sfsrm__Status__c` (17.99%) is **brand-noisy** ("4. INVOICED/CLOSED", "A", "CC 7.1") | NOT usable as cross-brand Invoice.status source |
| `sfsrm__Aging_Group__c` = 100%, 8 clean buckets | NEW `Invoice.aging_bucket` column candidate |
| `sfsrm__Dispute__c.sfsrm__Type__c` = **99.89%** (30 distinct values); `sfsrm__Sub_Type__c` = 12.6% | InvoiceDispute.subtype re-routed to `sfsrm__Type__c` |
| `sfsrm__Dispute__c.sfsrm__Close_Date__c` = **93.74%**; `sfsrm__Dispute_Close_DateTime__c` = **0%** | InvoiceDispute.resolved_at re-routed to `sfsrm__Close_Date__c` |
| `ContentDocumentLink` = **0 rows downloaded**; ContentDocument.ParentId / ContentVersion.FirstPublishLocationId don't link to Transaction | **InvoiceAttachment join blocked** — need ContentDocumentLink in next sync |
| `Task.CallType` = **100% empty** on 528K rows | CommunicationEvent.direction must derive from `Type` + `TaskSubtype` + `sfsrm__Contact_Method__c` |
| `EmailMessage.RelatedToId` is 100% Account prefix (NOT a Contact ref) | Drop customer_contact_id mapping from EmailMessage |
| `Task.WhatId` is 100% Account (or ListEmail group) — never Transaction/Dispute | All Task-polymorphic crosswalks to invoice/dispute/payment_promise will be null |
| `Event` object = **NOT in dump** | CommunicationEvent.channel = meeting has no Sailfin source |
| `sfsrm__Payment__c.sfsrm__Memo__c` **does not exist** | PaymentPromise.notes re-routed to `sfcapp__Remarks_1__c` or `Entry_Description__c` |
| `sfsrm__Payment__c` ↔ `sfsrm__Transaction__c` has no direct link | Join goes via `sfsrm__Payment_Line__c` (262K lines / 20K payments, median ~13 lines each). **One PaymentPromise per (Payment, Payment_Line)** |
| `sfsrm__Collection_Detail__c` = 148 rows, no task-shaped fields | Dropped from OperationalTask origin list |
| Top 3 brands hold ~75% of accounts (Corrpro: 62%) | Useful for dedup test cases |

## Legend

| Shape | Meaning |
|---|---|
| **direct** | Sailfin value copies verbatim into the cashline column |
| **derived (cents)** | Sailfin currency (dollars/double) → cashline integer cents (× 100) |
| **derived (split)** | One Sailfin field → multiple cashline fields (e.g. `Name` → `first_name` + `last_name`) |
| **derived (other)** | Concat, parse, normalize, invert, or compose from multiple sources |
| **value_collapse** | Salesforce picklist string → cashline enum integer (per-value `MappingValueEntry` rows define the map) |
| **sync_reference** | Sailfin `Id`/lookup → cashline integer FK via `sailfin_*_id` crosswalk column at sync time |
| **net_new** | Cashline-only construct; no Sailfin origin |
| **operational** | Cashline lifecycle/internal (PKs, Rails timestamps, Devise fields, soft-delete flags). Sync writes its own values; not a mapping question. |
| **uncertain** | Best guess noted; needs further triage |

Annotations:
- ✓ = already committed as a `MappingEntry` on snapshot #1
- 🆕 = new cashline-platform column to add (a `sailfin_*_id` crosswalk column; see `sailfin-crosswalk-columns.md`)
- ⏳ = depends on a 🆕 crosswalk column landing first

**Crosswalk-column pattern**: every Sailfin lookup field (FK) maps to a **new** `sailfin_*_id` column on the cashline side as a `direct` mapping. The existing integer FK column (e.g. `customer_account_id`) then becomes **sync-managed** — the sync resolver looks up the crosswalk value against the parent table's `sailfin_*_id` and sets the integer FK. So one Sailfin lookup spawns two cashline columns: a `direct`-mapped crosswalk and a sync-managed integer FK.

---

## AR-core classes (real Sailfin origin)

### Customer::Organization — canonical customer identity (deduped across Brand pairings)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | PK |
| `sailfin_account_id` 🆕 | direct | `Account.Id` | Origin crosswalk — the Sailfin Account row this canonical Org was derived from |
| `sailfin_alias_account_ids` 🆕 | derived (other) | `Account.Id` (across duplicates) | jsonb array of all Sailfin Account IDs that merged into this canonical Org |
| `canonical_name` | derived (other) | `Account.Name` (across duplicates) | Sync resolver runs dedup + spell-correction across duplicate Account rows for the same legal entity |
| `legal_name` | direct | `Account.Name` | `sfsrm__Credit_Application__c` has 0 rows in this org (audited 2026-06-02); fallback path moot |
| `normalized_name` | derived (other) | `canonical_name` | Lowercase + strip punctuation; downstream of canonical_name |
| `website` | net_new | — | `Account.Website` = 0% populated in real data (audited 2026-06-02); mapping deleted |
| `notes` | net_new | — | Cashline-side org notes; no Sailfin origin |
| `operator_id` | net_new | — | Cashline platform construct |
| `created_at` | derived (other) | `Account.CreatedDate` | Backfilled from Sailfin on initial sync; Rails manages subsequently |
| `updated_at` | derived (other) | `Account.LastModifiedDate` | Same pattern as created_at |

### Customer::Account — AR link (one per customer × client pairing)

Cardinality: **Sailfin Account → cashline Customer::Account is 1:1 on the customer side**. The 1:N fanout happens on the client side instead: a single logical Client::Org may have many duplicate `Brand__c` rows in Sailfin (one per customer-Brand pairing), so dedup work happens at the Brand → Client::Org boundary, not at the Account → Customer::Account boundary.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `sailfin_account_id` 🆕 | direct | `Account.Id` | Origin crosswalk |
| `sailfin_brand_id` 🆕 | direct | `Account.Brand__c` (99.999%, denormalized lookup) | No junction needed; 2/135,366 rows have no Brand — sync fallback required |
| `account_number` ✓ | direct | `Account.AccountNumber` (99.99%) | committed |
| `display_name` ✓ | direct | `Account.Name` (100%) | committed |
| `customer_organization_id` | sync_managed | — | Set by sync resolver: looks up `Customer::Org` by `sailfin_account_id` |
| `client_organization_id` | sync_managed | — | Set by sync resolver: looks up `Client::Org` by `sailfin_brand_id` (resolves the *deduped* Client::Org — multiple Sailfin Brand__c rows for the same client land on the same Client::Org) |
| `customer_group_id`, `client_group_id` | sync_managed | — | Derived from Org→Group join |
| `status` ✓ | value_collapse | `Account.Status__c` | committed; **only 0.42% populated** (569/135,366) — 99.6% default to `active`. Picklist: Active(381)→active, Inactive(174)→inactive, "Pending MSA"(10)→active, "Bankrupt"(1)→archived, rest→active. |
| `submission_channel` | value_collapse | `Account.Ecommerce_System__c` (**2.39%** populated) | Required enum (unknown/portal/email/mail). 96.6% will default to `unknown`. All populated values map to `portal` per Cluster A audit. |
| `portal_name` ✓ | direct | `Account.Ecommerce_System__c` (2.39%) | committed; raw vendor label (50+ spelling variants — see Cluster A picklist table). Same source as submission_channel; complementary. |
| `notes` ✓ | direct | `Account.sfsrm__Sticky_Note__c` (99.5%) | committed (re-routed 2026-06-02 from `Account.Description` which is 0%) |
| `collection_notes` | derived (other) | `sfsrm__Collection_Detail__c.sfsrm__Notes__c` aggregated per Account | Description fallback dropped (0% populated). Collection_Detail__c is only 148 rows — sparse aggregation source. |
| `payment_terms_notes` ✓ | direct | `Account.Payment_Terms_Description__c` (78.8%) | committed; "Net 30 Days"/"NET 30 DAYS" casing variants |
| `check_run_schedule_notes` | net_new | — | No Sailfin source |
| `created_at` | derived (other) | `Account.CreatedDate` | Backfilled on initial sync; Rails manages subsequently |
| `updated_at` | derived (other) | `Account.LastModifiedDate` | Same pattern |

**New columns to consider** (high-population Account fields with no current destination): `billing_street`/`city`/`state`/`postal_code`/`country` (BillingStreet 78%, City 77%, etc.); `phone` (Account.Phone 78.8%); `email` (Account.EMAIL__c 22.8%); `credit_limit_cents` (sfsrm__Credit_Limit__c 78.9%); `bank_name`/`bank_account_number`/`bank_routing`/`bank_aba` (65-88%, PII review needed); `parent_account_id` reference (Parent_Account__c); plus booleans `auto_emails_disabled`/`contact_restricted`/`bankruptcy`/`legal_status` (each 100% populated). See "Proposed new cashline columns" appendix below.

### Customer::Contact

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `sailfin_contact_id` 🆕 | direct | `Contact.Id` (100%) | Origin crosswalk |
| `sailfin_account_id` 🆕 | direct | `Contact.AccountId` (**73.16%**) | 18,749/69,821 Contacts have empty AccountId — sync orphan policy required |
| `email` ✓ | direct | `Contact.Email` (79.0%) | committed |
| `first_name` ✓ | direct | `Contact.FirstName` (70.4%) | committed |
| `last_name` ✓ | direct | `Contact.LastName` (100%) | committed; Salesforce-required |
| `phone` ✓ | direct | `Contact.Phone` (49.3%) | committed |
| `title` ✓ | direct | `Contact.Title` (15.9%) | committed |
| `customer_account_id` | sync_managed | — | **Schema conflict**: 27% of Contacts have no AccountId, but cashline `NOT NULL` will reject them. Drop orphans, attach to sentinel, or relax NOT NULL — see Q6 in `questions-for-dre-bryce.md`. |
| `customer_organization_id` | sync_managed | — | Derived from customer_account_id join |
| `customer_group_id` | sync_managed | — | Derived |
| `role_label` | net_new | — | `Contact.Customer_Group__c` audited (2026-06-02): populated in 0.1% of contacts (45/69,821) with customer-industry segments (NONOILGAS, IOC, INDEP, SERVICE), not contact roles. Confirmed net_new. |
| `notes` | direct | `Contact.Description` | |
| `created_at` | derived (other) | `Contact.CreatedDate` | Backfilled on initial sync |
| `updated_at` | derived (other) | `Contact.LastModifiedDate` | |

### Client::Organization — the brand/billing entity (NOT the customer)

Dedup key: `Account.Brand_Code__c` (53 distinct brands, perfectly 1:1 with `Brand__c.Id`, 99.998% populated). Sourced entirely from `Account` denormalized columns; Brand__c was not downloaded for v1.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `sailfin_brand_id` 🆕 | direct | `Account.Brand__c` | Origin crosswalk |
| `sailfin_brand_code` 🆕 | direct | `Account.Brand_Code__c` | Dedup key + debugging affordance |
| `name` | direct | `Account.Brand_Name__c` (100%) | E.g. "Corrpro Companies, Inc." (53 distinct) |
| `description` | net_new | — | No source on Brand_* fields |
| `slug` | derived (other) | `Account.Brand_Code__c` (lowercased) | E.g. `corrpro-us`, `endurance-lift` |
| `group_label` | net_new | — | Cashline-side. Groups are sub-divisions within the same client; label distinguishes the segment. Defaults to `"Group"`. |
| `brand_manager_user_id` 🆕 | sync_reference | `Account.Brand_Manager__c` matched to `User` by FirstName+LastName | **Replaces Client::Contact Path B** — all 5 distinct brand managers resolve 100% to existing Sailfin Users (`CashLine_Employee__c=true`). N-to-1 relationship (one manager covers many brands). |
| `operator_id` | sync_managed | — | Cashline platform construct |
| `created_at` | derived (other) | earliest `Account.CreatedDate` across that brand's Accounts | |
| `updated_at` | derived (other) | latest `Account.LastModifiedDate` across that brand's Accounts | |

**Pending Dre/Bryce review #1**: whether to add headquarters/contact columns to receive these 9 Account.Brand_*_c denorms that currently have no destination. **Field-name corrections from 2026-06-03 audit:** `Brand_Street__c` (99.90%), `Brand_State_Province__c` (99.90%), `Brand_ZIP_PostalCode__c` (99.90%) — NOT `Brand_Address__c` / `Brand_State__c` / `Brand_Postal_Code__c` as previously listed. `Brand_Website__c` does **not exist**. Bonus: `Brand_Logo__c` (100%) and `Brand_Region__c` (1.75%) also available.

### Client::Contact — operator-side personnel

**2026-06-03 redesign**: Path B (Brand_Manager extraction) is dropped. All 5 distinct `Account.Brand_Manager__c` values resolve 100% to existing Sailfin Users with `CashLine_Employee__c=true`. The brand-manager relationship is captured by the new `Client::Organization.brand_manager_user_id` FK above; no separate Client::Contact rows needed for brand managers.

Cardinality: 175 Sailfin Users; ~91 active. The single source path:

**Sailfin User with brand affinity** (becomes a cashline User row + Client::Contact + Client::Membership, no auto-invite):

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `first_name` | direct | `User.FirstName` (98.86%) | |
| `last_name` | direct | `User.LastName` (100%) | Strip trailing `" (Inactive)"` (Salesforce deactivation convention; ~5 cases) |
| `email` | direct | `User.Email` (100%) | |
| `phone` | direct | `COALESCE(User.Phone, User.MobilePhone)` | Phone=57.71%, MobilePhone=66.86% — combined ~80% |
| `title` | direct | `User.Title` (81.71%) | |
| `role_label` | direct | `User.UserRole.Name` (93.71%) | Format: `"AR Collector (Corrpro)"` — strip the brand-suffix paren. Fallback: `Profile.Name` (100%) when UserRole absent. |
| `user_id` | sync_managed | Links to cashline User row | |
| `sailfin_user_id` 🆕 | direct | `User.Id` (100%) | |
| `client_organization_id` | sync_managed | derived from `UserRole.Name` brand suffix, `Profile.Name`, `Department` (71.4%), or Account ownership graph | |
| `client_group_id` | sync_managed | derived | |
| `notes` | net_new | — | |
| `created_at` | derived (other) | `User.CreatedDate` (100%) | |
| `updated_at` | derived (other) | `User.LastModifiedDate` | |

**Sync filters:**
- Only `User.UserType = "Standard"` (drops 4 system/integration accounts from the 175)
- `User.CashLine_Employee__c == false` → Client::Contact + Client::Membership (129 users)
- `User.CashLine_Employee__c == true` → User + OperatorMembership instead (46 users) — see Operator section

**Decisions captured 2026-06-02:** Auto-create cashline User rows; **no Devise invites** — separate invite-flow feature.

### Client::Group — sub-grouping of Brands under a reporting parent

**Status: unverifiable from current data** — `Brand__c` was not in the 2026-06-03 download. The proposed `Brand__c.Reporting_Client__c` source cannot be confirmed. Account has no `Reporting_Client__c` denorm. Candidate alternative `Account.Brand_Lookup__c` is 13.86% populated (reference ID, unresolvable without Brand__c). Decision needed: either include Brand__c in next sync, or declare Client::Group cashline-managed.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `name` | direct | `Brand__c.Reporting_Client__c` (**unverifiable**) | Need Brand__c download |
| `description` | net_new | — | |
| `slug` | derived (other) | derived from `name` | |
| `client_organization_id` | sync_reference | derived | |
| `created_at`, `updated_at` | operational | — | |

### Client::Membership — User ↔ Client::Org join (access control)

**Entirely cashline-side, NOT derived from Sailfin.** Memberships represent which cashline users can view a given client's data. When an operator/client user onboards on cashline, the membership is assigned fresh by the platform admin. Not copied across from Sailfin.

All columns are **net_new / operational** — no Sailfin sourcing.

### Invoice — 43 columns, the AR core

Source: `sfsrm__Transaction__c` (2,182,406 rows) + Account denorm. Many fields have a Transaction-side denorm that's higher-pop than the Account-side equivalent — preferences below reflect that.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `sailfin_transaction_id` 🆕 | direct | `sfsrm__Transaction__c.Id` (100%) | Origin crosswalk |
| `sailfin_account_id` 🆕 | direct | `sfsrm__Transaction__c.sfsrm__Account__c` (100%) | FK crosswalk |
| `sailfin_brand_id` 🆕 | direct | `sfsrm__Transaction__c.Brand_Code_Invoice__c` (100%) | Transaction-side denorm of Brand code; cleaner than join through Account |
| `invoice_number` ✓ | direct | `sfsrm__Transaction__c.Invoice_Number__c` (100%) | committed |
| `area` ✓ | direct | `sfsrm__Transaction__c.Area__c` | committed; sparse |
| `division` ✓ | direct | `sfsrm__Transaction__c.DIVISION__c` (15.8%) | committed; sparse |
| `region` | direct | `sfsrm__Transaction__c.ELS_Region__c` (100%) | **Re-routed 2026-06-03 from `Account.Region__c` (0.1%) — Transaction-side denorm is universal** |
| `currency` ✓ | direct | `sfsrm__Transaction__c.CurrencyIsoCode` (100%) | committed |
| `issue_date` ✓ | direct | `sfsrm__Transaction__c.sfsrm__Create_Date__c` (100%) | committed |
| `due_date` ✓ | direct | `sfsrm__Transaction__c.sfsrm__Due_Date__c` (100%) | committed |
| `payment_terms_code` ✓ | direct | `sfsrm__Transaction__c.sfsrm__Payment_Terms__c` (100%) | committed |
| `payment_terms_days` ✓ | direct | `sfsrm__Transaction__c.Terms__c` (100%) | committed |
| `payment_terms_description` | direct | `Account.Payment_Terms_Description__c` (78.8%) | Account-denormalized |
| `purchase_order_number` ✓ | direct | `sfsrm__Transaction__c.Order__c` | committed; sparse — `sfsrm__Po_Number__c` (8.5%) is an alt |
| `ticket_number` ✓ | direct | `sfsrm__Transaction__c.Field_Ticket__c` | committed; sparse |
| `original_amount_cents` ✓ | derived (cents) | `sfsrm__Transaction__c.Original_Amount__c × 100` (100%) | committed |
| `total_cents` | operational | — | Recomputed by `Invoice#recalculate_totals`: `subtotal + tax` |
| `subtotal_cents` | operational | — | Recomputed by `Invoice#recalculate_totals`: sum of line item amounts |
| `tax_cents` | derived (cents) | `sfsrm__Transaction__c.Tax_Amount__c × 100` (**97.0%** verified) | Sync sets directly; callback uses it |
| `balance_due_cents` | operational | — | Recomputed by `Invoice#recalculate_totals`: 0 if paid/closed/void, else total_cents. Partial-paid edge case — see Q4 in `questions-for-dre-bryce.md`. |
| `status` | derived (other) + value_collapse | multi-source — see derivation rule below | **17-state enum**; primary signal = `Amount_Outstanding__c` (100% pop, 95.9% zero); secondary = `Ecommerce_Category__c` (100%, 7 values); plus `sfsrm__DisputedFlag__c` (0.5% true) and `Is_Broken_Promise__c` (24.2% true). See "Invoice.status derivation rule" below. |
| `job_number` | direct | `sfsrm__Transaction__c.Job_Number_Job_Name__c` (100%) | **Re-routed from `JOB_Number__c` (<1%) — composite field is universal** |
| `location_name` | direct | `sfsrm__Transaction__c.Location_Name__c` | sparse |
| `well_site` | direct | `sfsrm__Transaction__c.Well_Name__c` | sparse |
| `repair_order_number` | uncertain | `sfsrm__Transaction__c.Repair_Order__c` if exists; else net_new | Sparse |
| `description` | direct | `sfsrm__Transaction__c.Latest_Notes_Entered_by_CE__c` (100%) | **Re-routed from `Action_Notes__c` (<1%) — collector-entered latest note is universal** |
| `customer_account_id` ⏳ | sync_reference | `sfsrm__Transaction__c.sfsrm__Account__c` → `Customer::Account.sailfin_account_id` | Deferred |
| `customer_group_id`, `client_group_id`, `client_organization_id` | sync_reference | derived from Account | |
| `source_account_number` | direct | `sfsrm__Transaction__c.Account_Number__c` (100%) | **Re-routed from `Account.AccountNumber` join — Transaction denorm is cleaner** |
| `source_customer_number` | direct | `sfsrm__Transaction__c.JDE_Customer__c` | sparse — JDE is one of many ERPs |
| `source_document_type` | direct | `sfsrm__Transaction__c.Document_Type_Description__c` | sparse |
| `source_transaction_id` | direct | `sfsrm__Transaction__c.sfsrm__Transaction_Key__c` (100%) | |
| `source_external_id` | direct | `sfsrm__Transaction__c.Id` (= `sailfin_transaction_id`) | Same value as crosswalk |
| `source_system` | derived (other) | literal `"sailfin"` written by sync | |
| `source_tenant_key` | net_new | — | Cashline multi-tenancy tag |
| `source_updated_at` | direct | `sfsrm__Transaction__c.LastModifiedDate` (100%) | |
| `last_synced_at` | operational | — | Set by sync resolver |
| `metadata` | net_new (sink) | — | jsonb bucket — recommend payload: `aging_group`, `days_past_due`, `disputed_amount`, `is_broken_promise`, `ecommerce_category`, `upstream_source` snapshots |
| `approved_at` | operational | candidate: `Invoice_Ecommerce_Approval_Date__c` (sparse) | Cashline lifecycle prevails; Sailfin signal sparse |
| `submitted_at` | operational | candidate: `Invoice_Ecommerce_Submission_Date__c` / `Ecommerce_Upload_Date__c` | Same |
| `paid_at` | derived (other) | `sfsrm__Close_Date__c` (100%) when Amount_Outstanding=0 | Backfill on initial sync |
| `created_by_user_id` | sync_reference | `sfsrm__Transaction__c.CreatedById` (100%) | |
| `created_at`, `updated_at` | operational | — | |

**Invoice.status derivation rule** (priority order, first match wins):

```ruby
if disputed_flag                              # sfsrm__DisputedFlag__c == "true"  (0.5%)
  :disputed
elsif amount_outstanding == 0
  invoice_amount < 0 ? :closed : :paid         # 95.9% of all invoices land here
elsif 0 < amount_outstanding < invoice_amount
  :partially_paid                                # 0.3%
elsif ecommerce_category == "Paid"              # outstanding>0 but ecommerce says paid
  :short_paid
elsif ecommerce_category == "Approved"
  :approved                                      # ~15%
elsif ecommerce_category == "Submitted"
  :submitted                                     # ~3%
elsif ecommerce_category == "In Process"
  :in_review                                     # ~0.1%
elsif ecommerce_category == "Not Submitted" && invoice_channel == "E-Commerce"
  :ready_to_submit
elsif is_broken_promise
  :awaiting_customer_action
else
  :received                                      # default for open non-portal invoices
end
```

No Sailfin source exists for: `draft`, `void`, `rejected`, `scheduled_for_payment`, `needs_resubmission`, `awaiting_documentation` — these are cashline-only states. **Brand-specific portal status fields** (`Ticket_Ecommerce_Status__c` 1.37% KLX-only, `ELS_Portal_Status__c`/`Endurance_Status__c` 3.32% Endurance-only, `Warrior_Status_Update__c` 0.05%) are too sparse for the primary rule but can refine status on those brands' invoices in a follow-up pass. `sfsrm__Status__c` (17.99%) is brand-noisy — NOT a clean cross-brand source.

### InvoiceLineItem — **synthesized 1:1 from Transaction** (sfsrm__Line_Item__c has 0 rows in this org)

The audit confirmed `sfsrm__Line_Item__c` is empty. Sailfin in this org carries one billable's worth of data per `sfsrm__Transaction__c` (single `sfsrm__Amount__c`, single `Product_Line__c`, single `Type_Description__c`). The sync resolver synthesizes one InvoiceLineItem per Invoice with literal qty=1.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `invoice_id` ⏳ | sync_managed | — | Same as parent Invoice's sailfin_transaction_id lookup |
| `quantity` | derived (other) | literal `1` | Synthesized constant — each Transaction is exactly one line |
| `unit_price_cents` ✓ | derived (cents) | `(sfsrm__Transaction__c.sfsrm__Amount__c - Tax_Amount__c) × 100` | committed; tax-exclusive so `subtotal + tax = total` |
| `amount_cents` ✓ | derived (cents) | `(sfsrm__Transaction__c.sfsrm__Amount__c - Tax_Amount__c) × 100` | committed (re-routed 2026-06-03); tax-exclusive — Invoice.recalculate_totals sums line items into subtotal then adds Invoice.tax_cents to produce total |
| `description` ✓ | direct | `sfsrm__Transaction__c.Type_Description__c` | committed (re-routed 2026-06-02) — e.g. "Temp Fence" |
| `item_code` ✓ | direct | `sfsrm__Transaction__c.Product_Line__c` | committed (re-routed 2026-06-02) — e.g. "Plunger" |
| `line_number` | derived (other) | literal `1` | Synthesized constant |
| `service_date` ✓ | direct | `sfsrm__Transaction__c.sfsrm__Create_Date__c` | committed (re-routed 2026-06-02) — `Transaction.Service_Date__c` also 0%, using Create_Date as proxy |
| `source_line_id` ✓ | direct | `sfsrm__Transaction__c.Id` | committed (re-routed 2026-06-02) — Transaction Id doubles as line Id |
| `service_period_start`, `service_period_end` | net_new | — | |
| `service_code` | net_new | — | |
| `tax_code` ✓ | direct | `sfsrm__Transaction__c.Header_Tax_Code__c` | committed |
| `unit_of_measure` | net_new | — | No UOM field in Sailfin |
| `position` | derived (other) | literal `1` | Synthesized constant |
| `metadata` | net_new (sink) | — | |
| `created_at` | derived (other) | `sfsrm__Transaction__c.CreatedDate` | Backfilled on initial sync |
| `updated_at` | derived (other) | `sfsrm__Transaction__c.LastModifiedDate` | |

### InvoiceDispute — `sfsrm__Dispute__c` is the source (191,457 rows)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `sailfin_dispute_id` 🆕 | direct | `sfsrm__Dispute__c.Id` (100%) | Origin crosswalk |
| `invoice_id` ⏳ | sync_reference | `sfsrm__Dispute__c.sfsrm__Transaction__c` (98.92%) | Deferred |
| `customer_account_id` ⏳ | sync_reference | `sfsrm__Dispute__c.sfsrm__Account__c` (100%) | Deferred |
| `status` ✓ | value_collapse | `sfsrm__Dispute__c.sfsrm__Status__c` (99.76%) | committed. Values: Closed (94.2%)→`resolved`; Assigned (5.3%) / Open (0.2%) / Reopened (0.01%) → `open`. **No native "canceled".** |
| `subtype` | value_collapse | `sfsrm__Dispute__c.sfsrm__Type__c` (**99.89%**) | **Re-routed 2026-06-03 from `sfsrm__Sub_Type__c` (12.6%) — `Type__c` is the actual subtype carrier with 30 distinct values** |
| `summary` | direct | `sfsrm__Dispute__c.sfsrm__Notes__c` (96.4%) | |
| `resolution_summary` | direct | `sfsrm__Dispute__c.sfsrm__Latest_Note__c` (86.9%) | `sfsrm__Resolution_Code__c` (0.56%) dropped as too sparse |
| `opened_at` | direct | `sfsrm__Dispute__c.sfsrm__Created_Date__c` (100%, date) | Use this over `CreatedDate` (datetime) |
| `resolved_at` | direct | `sfsrm__Dispute__c.sfsrm__Close_Date__c` (**93.74%**, date) | **Re-routed 2026-06-03 from `sfsrm__Dispute_Close_DateTime__c` (0% — empty)** |
| `opened_by_user_id` | sync_reference | `sfsrm__Dispute__c.CreatedById` (100%) | |
| `resolved_by_user_id` | sync_reference | `sfsrm__Dispute__c.sfsrm__Owner__c` (100%) | |
| `client_visible` | derived (other) | `!Dispute_Created_by_CE__c` (99.1% of disputes are CE-created → 99.1% invisible) | **Confirmation needed** — see new question for Dre/Bryce. The default makes near-all disputes hidden from clients. |
| `waiting_on_party` | value_collapse | derived from `sfsrm__Status__c` | Cashline-side rule |
| `disputed_amount_cents` 🆕 | derived (cents) | `sfsrm__Dispute__c.sfsrm__Amount__c × 100` (100%) | NEW column — dispute $ amount |
| `balance_cents` 🆕 | derived (cents) | `sfsrm__Dispute__c.sfsrm__Balance__c × 100` (100%) | NEW column — remaining unresolved balance |
| `client_group_id` | sync_reference | derived | |
| `created_at`, `updated_at` | operational | — | |

### InvoiceAttachment

**BLOCKED: invoice→attachment join unavailable in current download.**
- `ContentDocumentLink` (the junction table): **0 rows downloaded** — not extracted
- `Attachment` (legacy object): **0 rows** in this org
- `ContentDocument.ParentId` is 100% `058` prefix (= ContentWorkspace folder, NOT linked entity)
- `ContentVersion.FirstPublishLocationId` is 100% `005` prefix (= User uploader, NOT Transaction)

There is no usable path from ContentDocument/ContentVersion back to the originating Invoice/Dispute in the current data. **Re-running the download with `ContentDocumentLink` included is required** before InvoiceAttachment can sync. See new question for Dre/Bryce.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `invoice_id` ⏳ | sync_reference | `ContentDocumentLink.LinkedEntityId` → `Invoice.sailfin_transaction_id` | **Pending re-download with ContentDocumentLink** |
| `sailfin_content_document_id` 🆕 | direct | `ContentDocument.Id` | Origin crosswalk |
| `description` | direct | `ContentVersion.Title` (100%) | |
| `file_type` 🆕 | direct | `ContentDocument.FileType` (100%) | NEW column — file MIME/extension type |
| `file_size_bytes` 🆕 | direct | `ContentDocument.ContentSize` (100%) | NEW column — bytes |
| `source` | derived (other) | literal `"salesforce-content"` | |
| `uploaded_by_user_id` | sync_reference | `ContentVersion.CreatedById` (100%) | |
| `created_at`, `updated_at` | operational | — | |

### PaymentPromise — dual origin (Transaction-side promise, or Payment_Line application)

**2026-06-03 redesign**: Payment-side origin is via `sfsrm__Payment_Line__c`, NOT `sfsrm__Payment__c` directly. Payment has no direct Transaction link; the join goes through Payment_Line (262K lines / 20K Payments, median ~13 lines per Payment). One PaymentPromise per **(Payment, Payment_Line)** pair.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `sailfin_transaction_id` 🆕 | direct | `sfsrm__Transaction__c.Id` (for Transaction-promise origin) | one of these two crosswalks populated |
| `sailfin_payment_line_id` 🆕 | direct | `sfsrm__Payment_Line__c.Id` (for Payment-line origin) | |
| `promised_amount_cents` ✓ | derived (cents) | `sfsrm__Transaction__c.sfsrm__Promised_Amount__c × 100` (24.4% of Transactions; 533K with ACTIVE status) | committed |
| `promise_date` | direct | `sfsrm__Transaction__c.sfsrm__Promise_Date__c` (777K populated) | |
| `currency` | direct | `sfsrm__Transaction__c.CurrencyIsoCode` (100%) or `sfsrm__Payment__c.CurrencyIsoCode` (100% USD) | |
| `payment_method` | value_collapse | `sfsrm__Payment__c.sfsrm__Payment_Type__c` | ACH(14,354)→ach; Check(5,617)→check; Wire Transfer(58)→wire; OFFSET(3)/Write Off(3)→other. **No source for `credit_card` enum value.** |
| `cleared_at` | direct | `sfsrm__Payment__c.sfsrm__Payment_Date__c` (99.98%) | |
| `status` | derived (other) | computed from `Is_Broken_Promise__c` (24.2% true), `Promise_Status__c` ("ACTIVE"/blank), `Promise_Marked_by_CE__c` (2.9% true), and presence of `cleared_at` | |
| `source` | derived (other) | literal `"transaction-promise"` or `"payment-line"` | |
| `notes` | direct | `sfsrm__Transaction__c.sfsrm__Latest_Note_Title__c` (Transaction side) **OR `sfcapp__Remarks_1__c` / `Entry_Description__c` (Payment side)** | **Re-routed 2026-06-03**: `sfsrm__Payment__c.sfsrm__Memo__c` **does not exist** in the schema |
| `invoice_id` ⏳ | sync_reference | Transaction side: `sfsrm__Transaction__c.Id` itself. Payment side: `sfsrm__Payment_Line__c.sfsrm__Transaction__c` | Deferred |
| `customer_account_id` ⏳ | sync_reference | `sfsrm__Payment__c.sfsrm__Account__c` (100%, Payment side) or derived from invoice | Deferred |
| `client_group_id` | sync_reference | derived | |
| `created_by_user_id` | sync_reference | `CreatedById` of origin row | |
| `resolved_at`, `resolved_by_user_id` | operational | — | cashline-side resolution lifecycle |
| `created_at`, `updated_at` | operational | — | |

**Rich Payment-side fields with no destination** (candidates for `metadata` jsonb or new columns): `sfsrm__Cheque_Number__c`, `sfsrm__Cheque_Amount__c`, `sfsrm__Lock_Box__c`, `sfsrm__Bank_Name__c`, `sfsrm__Deposit_Date__c`, `sfsrm__Applied_Amount__c`, `sfsrm__UnApplied_Balance__c`, `sfcapp__Posting_Date__c`, `Settlement_Date__c`. Cash-app/reconciliation context worth carrying.

**See also**: the reverse-sweep proposed `Payment::Batch` and `Payment::BankRemittanceLine` as new cashline classes — they sit upstream of PaymentPromise as the deposit/lockbox header + raw remittance detail.

### User (cashline-internal — operator personnel)

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `email` ✓ | direct | `User.Email` | committed |
| `first_name` ✓ | direct | `User.FirstName` | committed |
| `last_name` | direct | `User.LastName` | **uncommitted, ready to commit** |
| `blocked` | derived (other) | `!User.IsActive` (boolean inversion) | |
| `theme_preference` | net_new | — | Cashline UI pref, not Salesforce theme |
| `invitation_token`, `invitation_created_at`, `invitation_sent_at`, `invitation_accepted_at`, `invitation_limit`, `invited_by_id`, `invited_by_type` | net_new | — | Devise invitation flow |
| `encrypted_password`, `reset_password_token`, `reset_password_sent_at`, `remember_created_at` | operational | — | Devise auth internals |
| `created_at`, `updated_at` | operational | — | |

### CommunicationEvent — `EmailMessage` + Task with channel signal (Event NOT in dump)

**2026-06-03 corrections**: `Event` object has **0 rows** in the dump (not extracted from Salesforce). `Task.CallType` is **100% empty** across 528,883 rows — must derive direction from `Type` + `TaskSubtype` + `sfsrm__Contact_Method__c`. `EmailMessage.RelatedToId` is 100% Account prefix (NOT Contact) — drop `customer_contact_id` proposal.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `channel` | value_collapse | derived from origin: `EmailMessage`→email; `Task` with `TaskSubtype=Email`→email; `Task` with `Type=Call/Phone`→call; else→note | |
| `direction` | value_collapse | EmailMessage: `Incoming` boolean (false=outbound 150K, true=inbound 88K). Task: derived from `Type` (Email→outbound, DNC→outbound, Call→ambiguous) + `sfsrm__Contact_Method__c` | **Re-routed 2026-06-03 — Task.CallType is 100% empty** |
| `summary` | direct | EmailMessage.Subject (99.1%) / Task.Subject (100%) | |
| `body` | direct | EmailMessage.TextBody (100%) / Task.Description (27.8%) | |
| `occurred_at` | direct | EmailMessage.MessageDate (98.7%) / Task.CompletedDateTime (99.96%) | **Task.CompletedDateTime preferred over ActivityDate (date only)** |
| `contact_email` | direct | EmailMessage.ToAddress (99.5%) outbound or FromAddress (99.5%) inbound — branch on `Incoming` | |
| `contact_name` | direct | EmailMessage.FromName (99.0%) | |
| `customer_account_id` ⏳ | sync_reference | EmailMessage.`sfsrm__Account__c` (100% Account prefix) / `Task.AccountId` (100%, cleaner than WhatId) | Deferred |
| `customer_contact_id` ⏳ | (DROPPED) | — | **2026-06-03**: EmailMessage.RelatedToId is 100% Account ref (not Contact); Task.WhoId only 1.0% populated. No clean Contact link from Activity data. Heuristic fallback: match FromAddress → Contact.Email. |
| `invoice_id`, `invoice_dispute_id`, `payment_promise_id`, `operational_task_id` ⏳ | (DROPPED for Task) | — | Task.WhatId is 100% Account or ListEmail — never Transaction/Dispute/Payment. These FKs only populated by cashline-side context resolution. |
| `created_by_user_id` | sync_reference | `CreatedById` (100%) of origin row | |
| `client_group_id` | sync_reference | derived | |
| `visibility` | net_new | — | Cashline-side visibility flag |
| `created_at`, `updated_at` | operational | — | |

**Rich EmailMessage fields with no destination**: `HtmlBody` (99.2%), `sfsrm__Category__c`/`Category_1..4__c` + classification confidence scores (Sailfin's email-classifier output), `Headers`, `ThreadIdentifier`, `MessageIdentifier`, `HasAttachment`, `IsBounced`, `CcAddress` (34%), `IsExternallyVisible`. Worth capturing classification on `metadata` jsonb — it's Sailfin's value-add. Task fields: `sfsrm__Contact_Method__c` (Promise To Pay/Dispute/Send Statement/Contact Customer), `sfsrm__Notes__c`, `sfsrm__Treatment__c`, `sfsrm__Treatment_Stage__c`.

### OperationalTask — non-call `Task` rows only

**2026-06-03 corrections**: `sfsrm__Collection_Detail__c` (148 rows, 11 fields — just Account+Collected_Amount, no task shape) is **dropped** as a source. All Task-polymorphic FK crosswalks (invoice/dispute/payment_promise) are dropped — `Task.WhatId` is 100% Account, never Transaction/Dispute. Task.Type is a **channel** signal not a category — `sfsrm__Contact_Method__c` is the better category source.

| Column | Shape | Sailfin source | Note |
|---|---|---|---|
| `id` | operational | — | |
| `priority` ✓ | value_collapse | `Task.Priority` | committed. Only Normal (279,963) and High (248,915) appear; Low has 5 rows, Urgent has 0 — cashline enum fills the middle two only. |
| `title` | direct | `Task.Subject` (100%) | |
| `description` | direct | `Task.Description` (27.8%) + `sfsrm__Notes__c` (18.2%) | |
| `category` | value_collapse | `sfsrm__Contact_Method__c` (19.9%) | **Re-routed 2026-06-03 from `Task.Type`** — Contact_Method values: "Contact Customer" (58,657)→general, "Promise To Pay" (39,427)→payment_follow_up, "Dispute" (12,678)→dispute_follow_up, "Send Statement" (8)→information_request. Type used as fallback. |
| `status` | value_collapse | `Task.Status` | Completed (525,926, 99.4%)→resolved; Not Started (2,881)→open; In Progress (64)→in_progress; Waiting on someone else (12)→blocked. **OperationalTask will be overwhelmingly resolved on first sync.** |
| `due_at` | direct | `Task.ActivityDate` (99.9%, date) | cast to datetime |
| `resolved_at` | direct | `Task.CompletedDateTime` (99.96%) | |
| `assigned_to_user_id` | sync_reference | `Task.OwnerId` (100%, User prefix) → `User.sailfin_user_id` | |
| `created_by_user_id` | sync_reference | `Task.CreatedById` | |
| `customer_account_id` ⏳ | sync_reference | `Task.AccountId` (100%, cleaner than WhatId) | Deferred |
| `customer_contact_id` ⏳ | (DROPPED) | — | Task.WhoId only 1.0% populated — almost no Contact link. |
| `customer_organization_id` | sync_reference | derived | |
| `invoice_id`, `invoice_dispute_id`, `payment_promise_id`, `communication_event_id` ⏳ | (DROPPED) | — | Task.WhatId is 100% Account/ListEmail. Cashline-side context resolution only. |
| `client_organization_id`, `client_group_id`, `operator_id` | sync_reference / net_new | derived from assignee context | |
| `visibility` | net_new | — | |
| `created_at`, `updated_at` | operational | — | |

**Cashline `category` enum values with no Sailfin source**: portal_access, portal_submission_gap, approval_follow_up, broken_promise_follow_up, account_setup, client_escalation, contact_research, data_quality. The Transaction-level `Is_Broken_Promise__c` (527,867 true) could synthesize OperationalTask rows of category `broken_promise_follow_up` outside the Task→OperationalTask pipeline.

**Sailfin Task fields with no destination**: `sfsrm__Treatment__c`, `sfsrm__Treatment_Stage__c` (collections playbook step — see `Dunning::TreatmentRule` proposal in reverse sweep), `IsHighPriority`, `IsRecurrence` + 11 Recurrence* fields, `sfsrm__Closed_Date__c`, `sfsrm__Auto_Dunning_Error__c`, `sfsrm__Dunning_Status__c`.

---

## Cashline-only classes (no Sailfin origin)

These represent cashline-platform constructs that have no counterpart in Sailfin's data model. Every business field is **net_new**; only sync-related metadata (e.g., a source filename) might originate elsewhere.

### Operator

Platform-tier entity (the firm operating cashline for a brand). No Sailfin equivalent — Brand__c is the *Client* identity, Operator is one level above.

| Column | Shape | Note |
|---|---|---|
| `id`, `created_at`, `updated_at` | operational | |
| `name`, `description`, `slug`, `sector` | net_new | The LLM proposal `Account.Sector__c → Operator.sector` is a false positive — that's customer industry, not operator sector |

### OperatorMembership

| Column | Shape | Note |
|---|---|---|
| all columns | net_new / operational | Cashline platform RBAC join. The `UserLicense.Status` proposal is a false positive. |

### Customer::Group

| Column | Shape | Note |
|---|---|---|
| `name`, `description` | net_new | Cashline-side sub-grouping of Customer::Orgs (e.g. parent companies). Sailfin has no equivalent. |
| `customer_organization_id` | sync_reference | derived |
| rest | operational | |

### Customer::AccountPortal — per-account portal credentials/notes

| Column | Shape | Sailfin source / note |
|---|---|---|
| `account_identifier` | **net_new** | **Re-tagged 2026-06-03**: `Account.Account_ID_Text__c` is byte-identical to `Account.Id` in 100% of rows (it's a formula echoing the SF Id) — NOT a portal-side identifier. `sfsrm__Account_Identifier__c` is 0.009% populated with random scratch text. No Sailfin source. |
| `portal_name` | derived (other) | `Account.Ecommerce_System__c` (2.39%) normalized; only ~3,233 of 135K accounts have one |
| `status` | **net_new** (hardcode `active` on creation) | **Re-tagged**: `Account.Status__c` (0.42%) doesn't apply to portal credentials; cashline-side lifecycle |
| `customer_account_id` | sync_reference | |
| `sailfin_account_id` 🆕 | direct | `Account.Id` — origin crosswalk so we know which Sailfin Account spawned this portal row |
| `login_url`, `metadata`, `name`, `notes` | net_new | Portal config lives in cashline; Sailfin doesn't track logins |
| rest | operational | |

### ExternalPortalStatus — polled portal status events

All fields are cashline-side polling state. **net_new** across the board. The LLM proposal `Weekly_AR_Snapshot__c.ELS_Portal_Status__c → status_label` is a real signal but it's a polled snapshot, not a Sailfin record — cashline polls portals directly, not via Sailfin.

### InvoiceStatusEvent — cashline-side audit trail

Every state change to an Invoice generates one row. No Sailfin source — cashline's own state machine writes these. **net_new**.

The LLM proposals (`sfsrm__Transaction__c.Ticket_Ecommerce_Status__c → new_status`, `sfsrm__Latest_Note_Title__c → note`) are misdirected: those fields are denormalized current state on Transaction, not an event log. They feed Invoice.status (current), not InvoiceStatusEvent.

### InvoiceSubmission — cashline's portal-submission lifecycle

Tracks a cashline-mediated push of an invoice to an external portal. Some fields may carry Sailfin metadata, but the lifecycle itself is cashline-side.

| Column | Shape | Note |
|---|---|---|
| `source_system` ✓ | direct | `Account.Ecommerce_System__c` — committed |
| `external_reference` | direct | `sfsrm__Transaction__c.Reference__c` (portal-side invoice ID, if Sailfin tracks it) |
| `portal_name` | derived (other) | `Account.Ecommerce_System__c` normalized |
| all other business fields | net_new | Cashline tracks submission state; Sailfin doesn't |
| FK columns | sync_reference | |

### SubmissionArtifact, SubmissionRequirement

Cashline-only artifact/requirement model for portal submissions. **net_new** across the board.

### Ingestion::Connector, Ingestion::ImportBatch, Ingestion::ImportRecord, Ingestion::MappingTemplate, Ingestion::FieldMapping, Ingestion::ValidationIssue, Ingestion::ResolutionDecision, Ingestion::CustomerAccountAlias

Cashline's CSV-ingestion subsystem (Aging Reports, Open Invoices uploads). **Entirely net_new** — these power a parallel ingest path, not the Sailfin API sync.

A few apparent LLM matches (`sfsrm__Data_Load_Batch__c.sfsrm__Batch_Job_End_Time__c → ImportBatch.committed_at`, `sfsrm__Object_Configuration__c.CreatedById → Connector.created_by_user_id`) are false positives — those Sailfin objects are internal to Sailfin's own data-loader tooling, not a source for cashline's customer-facing ingest.

---

## Summary — counts by shape

(Approximate; uncertain rows are noted in-row. Counts include the 2026-06-03 corrections.)

| Shape | ~count | Examples |
|---|---|---|
| direct | ~60 | Names, emails, dates, codes, descriptions |
| derived (cents) | 8 | All `*_cents` invoice/line/dispute/payment amounts |
| derived (split) | 0 | (Path B name-splitting eliminated by 2026-06-03 redesign) |
| derived (other) | ~14 | Slugs, normalized names, computed status, channel-from-origin, multi-source status derivation |
| value_collapse | ~15 | Picklists → enums (Account.Status, Account.Ecommerce_System, Dispute.Status/Type, Payment_Type, Task.Status/Priority/Contact_Method, Invoice.status derivation, etc.) |
| sync_reference | ~55 | Every cashline `*_id` FK with a Sailfin origin |
| net_new | ~175 | Entire Ingestion::*, Operator/OperatorMembership, Submission*, ExternalPortalStatus, lifecycle/visibility fields on AR-core, plus 7 dropped polymorphic Task crosswalks |
| operational | ~125 | PKs, Rails timestamps, Devise fields, sync timestamps, recalculate_totals-managed amounts |
| (BLOCKED) | 1 | InvoiceAttachment.invoice_id — pending ContentDocumentLink download |
| (DROPPED) | ~8 | Path B crosswalk, Task polymorphic crosswalks, EmailMessage→Contact link, Account_ID_Text formula |

---

## Proposed new cashline columns + tables (2026-06-03 reverse sweep)

The 2026-06-03 full-data audit surfaced material Sailfin data with no current cashline destination. Three categories:

### A. New columns on existing cashline tables

| cashline table | Column | Sailfin source | Pop% | Rationale |
|---|---|---|---|---|
| `customer_organizations` | (no new columns proposed) | — | — | All meaningful Account fields belong elsewhere |
| `customer_accounts` | `billing_street`, `billing_city`, `billing_state`, `billing_postal_code`, `billing_country` | Account.Billing* | 71-78% | Mailing address — material if delivery matters |
| `customer_accounts` | `phone` | Account.Phone | 78.8% | Account-level phone |
| `customer_accounts` | `email` | Account.EMAIL__c | 22.8% | Account-level email |
| `customer_accounts` | `credit_limit_cents` | sfsrm__Credit_Limit__c × 100 | 78.9% | AR risk signal |
| `customer_accounts` | `bank_name`, `bank_account_number`, `bank_routing_number`, `bank_aba` | Bank_Name__c / Bank_Account_No__c / Routing_No__c / ABA__c | 65–88% | PII review needed |
| `customer_accounts` | `auto_emails_disabled`, `contact_restricted`, `bankruptcy`, `legal_status` booleans | No_Auto_Emails__c, Restricted_Contact__c, Bankruptcy__c, In_Legal_Status__c | 100% each | Operational flags for AR automation |
| `customer_accounts` | `parent_account_id` (sailfin_parent_account_id crosswalk) | Account.Parent_Account__c | 100% formula | Models customer parent/child graph |
| `customer_contacts` | `cc_on_emails`, `bcc_on_emails` booleans | Contact.CC__c / Bcc__c | 100% each | Collections email automation |
| `customer_contacts` | `email_opt_out`, `email_bounced` booleans | HasOptedOutOfEmail / IsEmailBounced | 100% each | Email deliverability gating |
| `customer_contacts` | `primary` boolean | sfsrm__Default__c | 100% | "Default contact" flag — useful for resolver |
| `customer_contacts` | `mailing_street`, `mailing_city`, etc. | Contact.Mailing* | ~23% | Optional contact-level address |
| `client_organizations` | `headquarters_street`, `headquarters_city`, `headquarters_state`, `headquarters_postal_code`, `headquarters_country` | Account.Brand_Street__c / Brand_City__c / Brand_State_Province__c / Brand_ZIP_PostalCode__c / Brand_Country__c | 99.9% each | Pending Dre/Bryce review #1 |
| `client_organizations` | `support_phone`, `support_email`, `logo_url` | Brand_Phone__c (97.1%) / Brand_Email__c (99.6%) / Brand_Logo__c (100%) | high | Pending Dre/Bryce review #1 |
| `client_organizations` | `brand_manager_user_id` (FK) | Account.Brand_Manager__c → matched User | 99.4% | Replaces dropped Client::Contact Path B |
| `users` (cashline) | (no new columns proposed) | — | — | Intentionally minimal Devise model |
| `invoices` | `aging_bucket` (8-value enum) | sfsrm__Aging_Group__c | 100% | "0-30 Past Due"/"31-60"/.../"181+"/"Not Yet Due"; heavily used for AR ops |
| `invoices` | `days_past_due` (integer) | sfsrm__Days_Past_Due__c | 100% | Numeric companion to aging_bucket |
| `invoices` | `disputed_amount_cents` | sfsrm__Disputed_Amount__c × 100 | 100% | Dispute $ amount carried on invoice |
| `invoices` | `account_owner_user_id` (FK) | Account_Owner__c | 100% | AR rep who owns the account at invoice time |
| `invoices` | `upstream_source` (string) | sfsrm__Source_System__c | 100% | "KLXTickets", "ProPetro", "EnduranceLift" — upstream ERP attribution |
| `invoices` | `collection_stage` (string or enum) | sfsrm__Collection_Stage__c | 100% | (Value distribution audit needed) |
| `invoices` | `invoice_channel` (boolean or enum) | Invoice_Channel__c | 100% | "Non-Ecommerce" (65%) vs "E-Commerce" (35%) — informs submission_channel default |
| `invoices` | `receipt_confirmed` (boolean) | Invoice_Receipt_Confirmed__c | 37.9% | "YES"/"NO" — operations signal |
| `invoice_disputes` | `disputed_amount_cents`, `balance_cents` | sfsrm__Dispute__c.sfsrm__Amount__c / Balance__c × 100 | 100% each | NEW dispute amounts |
| `invoice_attachments` | `file_type`, `file_size_bytes` | ContentDocument.FileType / ContentSize | 100% each | Useful metadata |
| `client_contacts` | `mobile_phone` (optional, or merge with phone via COALESCE) | User.MobilePhone | 66.86% | Either store separately or COALESCE into phone |
| `client_contacts` | `department` | User.Department | 71.43% | Brand-affinity input; could surface |

### B. New cashline tables (from cross-object reverse sweep)

| Proposed cashline class | Sailfin source | Rows | Purpose |
|---|---|---|---|
| `Payment::Batch` | `sfcapp__Payment_Batch__c` | 3,951 | Bank deposit / lockbox header (parent of remittance lines and payments) |
| `Payment::BankRemittanceLine` | `sfcapp__Bank_Statement_Remittance__c` | 12,394 | Raw bank-file remittance detail; ~26% unmatched (cash-app exception queue) |
| `Accounting::GeneralLedgerAccount` | `sfcapp__GL_Account__c` | 48 | GL string registry for discount/write-off/payment postings |
| `Forecast::CollectionForecast` | `sfsrm__Collection_Forecast__c` | 99 | Monthly cash-collection plan per entity |
| `Forecast::DailyCashCheckpoint` | `sfsrm__Cash_Monitoring__c` | 484 | Daily actual-vs-target receipts (child of CollectionForecast) |
| `Forecast::CollectorTarget` | `sfsrm__Collector_Target__c` | 41 | Per-collector slice of a CollectionForecast |
| `Dunning::TreatmentRule` | `sfsrm__Treatment__c` | 346 | Dunning playbook (rule definitions; Task rows are instances) |

These cluster into three new ontology areas:
- **Payment cluster expansion**: Batch + BankRemittanceLine sit upstream of the existing Payment / Payment_Line pair.
- **Forecast cluster (genuinely new)**: CollectionForecast + DailyCashCheckpoint + CollectorTarget — none in cashline today.
- **Dunning rules (genuinely new)**: TreatmentRule complements the existing Task instances. Migration note: `sfsrm__Custom_Logic_Class__c` is a free-text reference to Sailfin Apex classes — these will need to be re-expressed as Ruby rule-engine entries.

Plus the stand-alone `Accounting::GeneralLedgerAccount` — load-bearing for any downstream accounting export.

See `/tmp/reverse-sweep-findings.md` for full per-table column sketches.

### C. Cross-cutting field gaps

1. **`Entity__c` is the implicit tenant dimension** across Account, Payment, Payment_Line, Payment_Batch, Bank_Statement_Remittance, Treatment, Collection_Forecast (called `Region__c` there). Recommend a first-class `Entity` model in cashline (lookup table + `entity_id` FK on every transactional table) rather than the current implicit string column. **Highest-leverage cross-cutting gap.**
2. **Bank-detail shape repeats 3 places** (Account.Bank_*, Payment bank fields, BankRemittanceLine.Receiving_*) — extract a thin `BankingDetail` value object reused by Customer (remit-to) and Payment (deposit account).
3. **ACH/NACHA file metadata** is dual-stored on `sfsrm__Payment__c` and `sfcapp__Bank_Statement_Remittance__c`. Treat BankRemittanceLine as source of truth; promote relevant fields onto Payment only after application.
4. **Natural keys (`*_Key__c`)** exist alongside opaque IDs on most cash-app objects (`Payment_Key__c`, `Bank_Statement_Remittance_Key__c`, `PaymentBatch_Key__c`, `GL_ACCOUNT_KEY__c`). Adopt as `sailfin_natural_key` columns on cashline staging tables so re-syncs are idempotent.

### D. New questions for Dre/Bryce surfaced by this audit

Add to `questions-for-dre-bryce.md`:
- **Q5** (Cluster C): `ContentDocumentLink` was not in the 2026-06-03 download. Re-run with `ContentDocumentLink` included? Without it, attachments cannot be linked to invoices.
- **Q6** (Cluster A): 27% of `Contact` rows have empty `AccountId`. Policy for orphan contacts: drop, attach to sentinel account, or relax `customer_account_id NOT NULL`?
- **Q7** (Cluster B): `Brand__c` was not downloaded. Include in next sync to verify `Client::Group.name ← Brand__c.Reporting_Client__c`, or declare Client::Group cashline-managed?
- **Q8** (Cluster C): `Dispute_Created_by_CE__c = true` in 99.1% of disputes, so `client_visible = !Dispute_Created_by_CE__c` makes near-all disputes invisible. Is this the intended default semantic?
- **Q9** (reverse sweep): Adopt a first-class `Entity` model to replace the implicit `Entity__c` string dimension that recurs across 7+ Sailfin objects?

---

## Reading this file

- **For Dre**: the `sync_reference` rows are the migration's payload — every one of them is a Sailfin lookup that needs the matching `sailfin_*_id` crosswalk column to land in cashline-platform. The companion doc `sailfin-crosswalk-columns.md` lists exactly which columns and on which tables.
- **For the sync resolver design**: the `derived (cents)` and `value_collapse` rows are where transformation code lives — currency × 100 helpers and per-picklist enum maps.
- **For the LLM adjudicator's next pass**: feed in the conventions above (Account=customer, Brand=client, currency=cents, picklist=enum, FK=sync_reference) so it stops proposing string-Id → integer-FK direct mappings.
- **Confidence**: ✓-marked rows are the validated baseline. Uncommitted-direct rows in this doc are the next-tier commit candidates — most can land as soon as we agree on the shape calls per class.
