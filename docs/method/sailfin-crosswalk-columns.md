# Sailfin crosswalk columns for cashline-platform

Status: **proposed** — pending Dre's review and a coordinated cashline-platform migration.

## Why

Sailfin's foreign-key fields hold Salesforce 18-character string IDs (e.g. `001Aa0000012345ABC`). Cashline-platform uses integer primary keys. These are **different identifier spaces** — copying a Sailfin string into a cashline integer FK is meaningless, and even if it weren't, re-syncing data after schema or row changes in either system would lose the link.

The fix: every cashline entity that has a Sailfin counterpart gets nullable `sailfin_*_id` crosswalk columns that preserve the original Sailfin IDs. The sync resolver looks up cashline rows by these columns and sets the integer FKs at sync time.

This unblocks:
- Sailfin FK fields (~582 relationships) resolving cleanly as `sync_reference` shape
- The ~37 fields currently classed `sync_reference` getting an explicit cashline target
- Re-syncs after either side mutates without losing the row identity

## Column conventions

- Type: `varchar(18)` — Salesforce IDs are 18 chars exactly. (15-char insensitive form + 3-char checksum.)
- Nullable: yes — cashline rows created manually have no Sailfin origin.
- Indexed: yes (single-column B-tree) — sync resolver does per-row lookups.
- Uniqueness: documented per-column below; some are unique, some composite, some neither.

## Must-have for v1 sync (core AR loop)

### `Customer::Organization` — canonical customer identity

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_account_id` | Origin — the Sailfin `Account` row this org was derived from | yes when set (unique partial index) |
| `sailfin_alias_account_ids` *(jsonb array, optional)* | Other Sailfin Account IDs that resolved into this canonical org (identity merges) | — |

### `Customer::Account` — AR link (one per customer × client pairing)

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_account_id` | The Sailfin Account row | composite `(sailfin_account_id, client_organization_id)` |
| `sailfin_brand_id` | The Sailfin `Brand__c` this link represents | composite above |
| `sailfin_association_id` | If row came from `Account_Brand_Association__c` junction instead of direct lookup | unique partial when set |
| `sailfin_owner_user_id` | `Account.OwnerId` if collections-ownership matters in cashline | — |

> **Roll-up & invoice resolution.** The importer collapses every Sailfin Account
> that lands in the same (customer org/group × client org/group) pairing into one
> `Customer::Account` (`AccountImporter`), so `sailfin_account_id` holds only a
> *representative* member — not every Sailfin Account that belongs to the pairing.
> A transaction's `sfsrm__Account__c` therefore can't always resolve by a direct
> `Customer::Account.find_by(sailfin_account_id:)`: the invoice importer must
> first map the account id → its pairing via `CustomerGroupingMember`
> (and the account's brand → client), then attach to that pairing's account.
> Direct lookup remains correct for accounts that aren't rolled up.
> Also note: only Accounts with ≥1 AR transaction are synced at all (activity
> filter), so dormant accounts have no `Customer::Account` to resolve to.

### `Customer::Contact`

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_contact_id` | Origin — Sailfin `Contact` row | yes when set |
| `sailfin_account_id` | Resolves `Contact.AccountId` → cashline `customer_account_id` | — |

### `Client::Organization`

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_brand_id` | Origin — Sailfin `Brand__c` row | yes when set |
| `sailfin_reporting_client_brand_id` | Resolves `Brand__c.Reporting_Client__c` (parent brand in operator's corporate structure) | — |
| `sailfin_owner_group_id` | `Brand__c.OwnerId` (Salesforce Group) — skip if not used | — |

### `Invoice`

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_transaction_id` | Origin — Sailfin `sfsrm__Transaction__c` | yes when set |
| `sailfin_account_id` | Resolves `sfsrm__Account__c` → `customer_account_id` | — |
| `sailfin_brand_id` | If transaction denormalizes the brand | — |
| `sailfin_owner_user_id` | `OwnerId` for collections-ownership tracking | — |

### `InvoiceLineItem`

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_line_item_id` | Origin — `sfsrm__Line_Item__c` | yes when set |
| `sailfin_transaction_id` | Parent invoice — resolves to `invoice_id` | — |
| `sailfin_account_id` | Denormalized account ref (Sailfin pattern) | — |

### `InvoiceDispute`

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_dispute_id` | Origin — `sfsrm__Dispute__c` | yes when set |
| `sailfin_transaction_id` | Disputed invoice → `invoice_id` | — |
| `sailfin_account_id` | Disputed account → `customer_account_id` | — |

### `PaymentPromise`

Sailfin's `sfsrm__Payment__c` is a *received* payment; cashline's `PaymentPromise` is a *commitment*. The two pathways below cover both: promises generated from a Transaction's `sfsrm__Promised_Amount__c` field, and promises that originated from a Payment record.

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_payment_id` | If row originated from `sfsrm__Payment__c` | yes when set |
| `sailfin_transaction_id` | If row originated from a Transaction's promise field, or used to resolve `invoice_id` | — |
| `sailfin_account_id` | Parent account → `customer_account_id` | — |

If cashline grows a separate `Payment` class (distinct from PaymentPromise), it gets its own `sailfin_payment_id` and the column moves there.

### `User` (operator-side personnel)

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_user_id` | Origin — Sailfin `User` row | yes when set |

## Should-have for v1 (activity feed)

### `CommunicationEvent`

Source can be `EmailMessage`, `Task` (call-type), or `Event` (logged-call). The origin lives in one of the first three columns, the rest resolve cross-references.

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_email_message_id` | If row originated from EmailMessage | yes when set |
| `sailfin_task_id` | If row originated from Task | yes when set |
| `sailfin_event_id` | If row originated from Event | yes when set |
| `sailfin_account_id` | Resolves `WhatId` / `AccountId` → `customer_account_id` | — |
| `sailfin_contact_id` | Resolves `WhoId` → `customer_contact_id` | — |
| `sailfin_transaction_id` | If linked to a specific invoice | — |
| `sailfin_dispute_id` | If linked to a dispute | — |

### `OperationalTask`

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_task_id` | If from Task (non-call types) | yes when set |
| `sailfin_collection_detail_id` | If from `sfsrm__Collection_Detail__c` | yes when set |
| `sailfin_account_id` | — | — |
| `sailfin_contact_id` | — | — |
| `sailfin_transaction_id` | — | — |
| `sailfin_dispute_id` | — | — |
| `sailfin_owner_user_id` | `OwnerId` → `assigned_to_user_id` | — |

### `InvoiceAttachment`

| Column | Purpose | Unique? |
|---|---|---|
| `sailfin_attachment_id` *or* `sailfin_content_version_id` | Origin | yes when set |
| `sailfin_transaction_id` | Parent invoice | — |

## Deferred / probably not needed v1

- **`Client::Contact`** — origin unclear (Brand__c.IT_Contact__c is a string, not a Contact; client-side personnel may come from User instead). Defer until design clears.
- **`Customer::AccountPortal`** — depends on whether a Sailfin portal-config object exists. Audit first.
- **`Client::Group`**, **`Customer::Group`**, **`OperatorMembership`**, **`Ingestion::*`**, **`SubmissionArtifact`**, **`SubmissionRequirement`**, **`ExternalPortalStatus`** — cashline-only constructs. No Sailfin origin.
- **`InvoiceSubmission`**, **`InvoiceStatusEvent`** — derived from cashline-side state machines, not directly synced.

## Index recommendations

- Single-column B-tree index on every `sailfin_*_id`.
- Composite unique index on `Customer::Account` = `(sailfin_account_id, client_organization_id)` — same Sailfin Account spawns one row per client pairing.
- Unique partial index where columns should be unique but are also nullable:
  `CREATE UNIQUE INDEX index_<table>_on_sailfin_<x>_id ON <table>(sailfin_<x>_id) WHERE sailfin_<x>_id IS NOT NULL;`

## Alternative considered: generic JSONB origin column

Instead of one `sailfin_*_id` column per FK, each table could have a single `sailfin_origin jsonb` like `{"object": "Account", "id": "001Aa…"}`. Tradeoffs:

- Pro: tidier schema (one column instead of 5-7 on busy tables like `CommunicationEvent`).
- Con: every sync-resolver query becomes a JSONB extract + cast; harder to index per-object; loses the self-documenting "this table has Sailfin origins from these object types" affordance.

Recommendation: stick with explicit columns. The schema bloat (≤7 columns on the busiest tables) is worth the index efficiency and clarity.

## What this unlocks

Once these land in cashline-platform and the snapshot is re-exported here:

1. The Resolutions `by_target` view surfaces the new `sailfin_*_id` columns as untouched cashline targets.
2. The LLM adjudicator can be re-prompted with the rule "FK fields → matching `sailfin_*_id`, shape = sync_reference."
3. The ~37 fields currently classed `sync_reference` get explicit cashline targets instead of "stored but not mapped."
4. The sync resolver becomes mechanical for FKs: read the source field's Sailfin ID, look up the cashline row by `sailfin_*_id`, set the integer FK.

## Sync-time resolution example

```
# Sailfin row:
#   Contact.Id = "003ABC..."
#   Contact.AccountId = "001Aa0000012345"
#   Contact.LastName = "Smith"
#
# Sync resolver for Customer::Contact:
customer = Customer::Account.find_by(sailfin_account_id: "001Aa0000012345")
Customer::Contact.upsert(
  sailfin_contact_id: "003ABC...",        # origin
  sailfin_account_id: "001Aa0000012345",  # crosswalk
  customer_account_id: customer.id,        # resolved integer FK
  last_name: "Smith"
)
```

Idempotent: re-running upserts by `sailfin_contact_id`. Re-resolvable: if a Customer::Account row is replaced, the crosswalk column still points at the original Sailfin ID, and the next sync re-resolves `customer_account_id`.
