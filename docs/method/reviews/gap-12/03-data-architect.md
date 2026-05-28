# Gap 12 — target-side architecture for `ARPosting`

Round-2 follow-up. Three sibling reviewers cover the source (`sfsrm__Transaction__c`), the operational semantics (credit memos, on-account cash, reversals), and the analytics shape. My lens is **how `ARPosting` is built in the Rails 8 cashline-platform** — the inheritance choice, the field allocation, and the interaction with the previously-flagged structural omissions in [`../03-data-architect.md`](../03-data-architect.md) (state-transition log, field-level provenance, the `subject_type/subject_id` idiom from Risk 2) plus the new Gap 14 signed-amount question (comparison doc lines 319–323).

Context. The comparison doc currently maps `sfsrm__Transaction__c → Invoice` 1:1 (line 45). Gap 12 (lines 296–302) reframes it as `ARPosting` with `kind` enum and `Invoice` as one of twelve subtypes (`credit_memo / on_account / write_off / write_back / reversal / offset / applied_credit / payment_refund / deduction / discount / account_transfer`). The synthesis (`00-synthesis.md` lines 42–50) ratifies it as the panel's #1 P0 by reversal cost. Zero `Invoice` rows exist in production today; ~3 weeks of synthetic-data CRUD against the existing schema. The migration window is real and uncrowded.

---

## Inheritance shape

Five Rails-native options, briefly:

1. **STI** — one `ar_postings` table, `type` discriminator, subtype columns nullable on the parent.
2. **Class-table inheritance** — `ar_postings` parent + per-subtype child tables joined on `ar_posting_id`.
3. **Discriminator + nullable subtype-detail FKs** — half-STI, half-CTI.
4. **`subject_type/subject_id` polymorphic single table** — the `CommunicationEvent` idiom from round 1.
5. **Wide flat table, no inheritance** — one table, `kind` enum, columns hold semantic load by type.

### Winner: STI

STI is the right default here, for four concrete reasons:

- **The shared core is genuinely shared.** Every posting needs `(operator_id, client_group_id, customer_account_id, posting_date, signed_amount_cents, currency, type, status, source_system, source_external_id, created_by_user_id)`. AR aging, account balance, DSO, application coverage — none of these queries care about the subtype-specific columns. Splitting into per-subtype tables (options 2, 4) means every report joins twelve tables or `UNION ALL`s twelve queries.
- **Subtype payloads are small.** `Reversal.original_ar_posting_id`. `CreditMemo.linked_invoice_id`. `OnAccountCash.received_via` + `bank_reference`. `WriteOff.write_off_reason_code` + `write_off_authority_user_id`. Roughly 12 nullable columns total on a parent that already needs ~30 shared columns. Not pathological.
- **Postgres handles wide-but-sparse tables cheaply.** NULL columns cost 1 bit each in the row's null bitmap. The "wide STI table" objection is mostly a MySQL myth on this database.
- **`audited` works per-class.** STI gives separate audit streams for `Invoice`, `CreditMemo`, `Reversal` automatically. CTI splits the audit between parent and child rows; option 4 makes investigators chase two trails for one logical event.

### Why the `subject_type/subject_id` shape does **not** fit here

This deserves to be explicit because in round 1 I argued strongly for that idiom on `CommunicationEvent`. The shapes are opposite:

- `CommunicationEvent` is *an activity record about a subject* — the activity is not its subject; the subject is heterogeneous (invoice, dispute, promise, contact, standalone).
- `ARPosting` of `kind = invoice` **is an Invoice**. The twelve subtypes share a Liskov-substitutable contract (signed amount, posting date, account, status, lifecycle hooks). The right precedent is Salesforce's own `sfsrm__Transaction__c` + `sfsrm__Transaction_Type__c` — a 14-value enum on a single table (synthesis line 46).

Two carve-outs from pure STI:

1. **`InvoiceLineItem`, `InvoiceAttachment`, `InvoiceSubmission` stay attached to `Invoice` (the subtype), not the parent.** Line items are invoice-only; a `CreditMemo` doesn't expose `has_many :line_items`. STI permits this — associations declared on the subclass simply don't appear on siblings.
2. **`ar_posting_reversal_details` as a future sidecar if any subtype's column footprint crosses ~5 columns.** Pressure-release valve; not needed at first migration.

---

## Field allocation — parent vs subtype

**Parent (`ar_postings`):** `type`, `operator_id`, `client_group_id`, `customer_account_id`, `posting_date`, `effective_date`, `signed_amount_cents`, `currency`, `status`, `status_changed_at`, `source_system`, `source_external_id`, `source_tenant_key`, `source_updated_at`, `last_synced_at`, `field_provenance jsonb`, `metadata jsonb`, `discarded_at`, `created_by_user_id`, `created_at`, `updated_at`.

**Invoice subtype-specific:** `invoice_number`, `issue_date`, `due_date`, `subtotal_cents`, `tax_cents`, `total_cents`, `balance_due_cents`, `original_amount_cents`, `purchase_order_number`, `payment_terms_*`, the existing `area / division / job_number / region / repair_order_number / ticket_number / well_site` source-side denorms (db/schema.rb:537–595). These stay where they are.

**Other subtype-specific (mostly 1–3 columns each):**

- `CreditMemo`: `credit_memo_number`, `linked_invoice_id` (nullable FK → `ARPosting` of kind `Invoice`).
- `OnAccountCash`: `received_via` enum (check/ach/wire/credit_card/lockbox), `bank_reference`, future `payment_id`.
- `Reversal`: `original_ar_posting_id` (required), `reversal_reason_code`.
- `WriteOff`: `write_off_reason_code`, `write_off_authority_user_id`.
- `Offset` / `AppliedCredit` / `Deduction`: `applied_to_ar_posting_id` (required).
- `AccountTransfer`: `transfer_group_uuid`, plus the row pair lives in two `ar_postings` rows (one debit side, one credit side) — not a single row with two FKs.
- `PaymentRefund`: future `payment_id`.

**Associations that stay on `Invoice`, not `ARPosting`:** `line_items`, `attachments`, `submissions`, `status_events`, `payment_promises`, `invoice_disputes`, `communication_events`, `operational_tasks`. Every one of these is invoice-only domain. The current `app/models/invoice.rb:9–25` has-many block survives unchanged — only the class hierarchy moves.

---

## Money — Gap 14 interaction

Gap 14 (lines 319–323) called out that unsigned `*_cents` columns can't represent credits, reversals, and refunds. The polymorphic shape **simplifies** rather than complicates this.

The parent gets a single `signed_amount_cents` (signed integer, no `>= 0` validation). Per-`kind` sign convention:

| Kind | Sign |
|---|---|
| `Invoice`, `WriteBack`, `PaymentRefund` | positive |
| `CreditMemo`, `OnAccountCash`, `ApplyCash`, `WriteOff`, `Discount` | negative |
| `Reversal` | opposite sign of `original_ar_posting_id` |
| `Offset`, `AppliedCredit`, `Deduction` | sign by direction; per-subtype validator |
| `AccountTransfer` | one row each side; pair sums to zero |

The customer-balance query becomes single-column: `SELECT SUM(signed_amount_cents) FROM ar_postings WHERE customer_account_id = ? AND discarded_at IS NULL`. Today the same answer requires joining `invoices` (positive) to a not-yet-existent `payments` table (negative); under `ARPosting`, the operation is closed.

`Invoice` keeps its decomposed unsigned columns (`subtotal_cents`, `tax_cents`, `total_cents`, `balance_due_cents`, `original_amount_cents`) because an invoice's *gross* amount is always non-negative. The `recalculate_totals` callback (`app/models/invoice.rb:85–91`) extends to set `signed_amount_cents = total_cents`.

`balance_due_cents` on Invoice changes semantics: **un-applied portion of this specific posting**, not the customer's balance. The `force balance_due_cents to 0 on paid/closed/void` shortcut at `invoice.rb:90` becomes a derived value from a future `ar_posting_applications` join table — exactly the deferred-bug case I flagged in round 1 (`../03-data-architect.md` line 34). Worth flagging again here: that line will be load-bearing wrong once `OnAccountCash` and `ApplyCash` start writing to it.

Currency stays per-row on the parent. The `currencies` reference table from Gap 14 lives one level up.

---

## State machine — three lifecycles, one log table

Different subtypes have genuinely different lifecycles:

- **Invoice**: the current 17-value enum (`invoice.rb:29–47`, post-Gap-7 expansion).
- **CreditMemo**: `draft → issued → linked → applied → void`. Five states.
- **OnAccountCash**: `received → matched → applied → reversed`. The cash-app worklist.
- **Reversal**: `proposed → posted → applied`.
- **WriteOff**: `proposed → approved → posted` (with the segregation-of-duties invariant below).

STI does not force one enum across subtypes. The right shape:

- `ar_postings.status` is an integer column **with no Rails enum at parent level**. Per-subtype enum mappings declared on `Invoice`, `CreditMemo`, etc. Integer values can overlap across subtypes (e.g., `0` = `draft` on Invoice, `proposed` on Reversal). Reads through the subtype get the right label; cross-subtype reports use `(type, status)` as a composite category.
- The `state_transitions` event log I called for in round 1 (`../03-data-architect.md` lines 123–130) becomes the **single transition log across all subtypes**. Polymorphic `transitioner_type / transitioner_id`. One table; uniform "how long did this posting sit in its current state" query.
- The existing `invoice_status_events` table (db/schema.rb:481–497) — added between round 1 and now — is already half this thing, scoped to Invoice. **Rename to `ar_posting_status_events` and generalize the FK to polymorphic `ar_posting_type / ar_posting_id`.** One migration, ~30 lines.

Adopt `state_machines-activerecord` **per subtype**. Each subtype owns its own transition guards; the library writes to the shared log via the existing after_commit hook. Same recommendation as round 1 (`../03-data-architect.md` line 131); STI generalizes it.

---

## Identity & uniqueness

Current Invoice: `unique(client_group_id, invoice_number)` (db/schema.rb:581) + `unique(source_system, source_external_id)` (db/schema.rb:593). Both survive on `ar_postings` as partial unique indexes. Per-subtype natural keys differ:

| Subtype | Natural key |
|---|---|
| `Invoice` | `(client_group_id, invoice_number)` — unchanged |
| `CreditMemo` | `(client_group_id, credit_memo_number)` — separate numbering sequence per Client is common |
| `OnAccountCash` | `(customer_account_id, bank_reference, posting_date)` |
| `Reversal` | `(original_ar_posting_id)` — unique partial; a posting can be reversed at most once |
| `Offset` / `AppliedCredit` | `(source_ar_posting_id, target_ar_posting_id)` |
| `AccountTransfer` | `transfer_group_uuid` shared across the row pair; pair must sum to zero |
| `WriteOff` | no natural key beyond `id`; linked via `applied_to_ar_posting_id` |

Implementation: partial unique indexes with `WHERE type = 'Invoice'` (etc.) clauses, all excluding `discarded_at IS NOT NULL`. Example:

```sql
CREATE UNIQUE INDEX idx_ar_postings_invoice_natural_key
  ON ar_postings (client_group_id, invoice_number)
  WHERE type = 'Invoice' AND discarded_at IS NULL AND invoice_number IS NOT NULL;

CREATE UNIQUE INDEX idx_ar_postings_reversal_uniqueness
  ON ar_postings (original_ar_posting_id)
  WHERE type = 'Reversal' AND discarded_at IS NULL;
```

A note on the discriminator name. Gap 12 (line 302) describes a `kind` enum. Rails-idiomatic STI uses `type`. **Use `type`** — it lights up `becomes`, eager-loading via `includes`, and `ActiveRecord::Base#type` introspection. The Gap-12 wording is correct in intent; in Rails STI the `type` column *is* the `kind` enum. One column, two names depending on whether you're talking to Rails or to SQL. Don't carry two columns.

---

## Sync / provenance

Current Invoice carries nine source-side columns (db/schema.rb:564–571) and the composite uniqueness `unique(source_system, source_external_id)`. All of these **move to the parent** (`ar_postings`). Every subtype is sync-able; every subtype needs the same identity lattice. Source-side IDs are globally unique within the source org regardless of kind — a Sailfin Reversal has its own `sfsrm__Transaction__c.Id` that never collides with its sibling Invoice ID.

Two source-side fields argue for moving elsewhere rather than to the parent:

- `source_document_type` is just the source's flavor of `type` — map it onto the discriminator at ingest, don't store twice.
- `source_customer_number` and `source_account_number` belong on `Ingestion::ImportRecord`, not on the posting. They're identifier-resolution scratch; once resolved, the posting only needs `customer_account_id`.

`field_provenance jsonb` (Gap 15 item 3, round 1 lines 162–166) lives on the parent. Keys are field paths; subtype fields include the subtype in the path implicitly (e.g., `invoice.purchase_order_number`). The load-bearing fields (`signed_amount_cents`, `status`, `customer_account_id`) all live on the parent, so most provenance entries don't need subtype qualification.

---

## Migration

Zero `Invoice` rows in production. The migration is mechanical, not semantic.

1. Rename `invoices → ar_postings`. Add `type` defaulting to `'Invoice'`. Add `signed_amount_cents` populated from `total_cents`. Add nullable subtype-specific columns (`original_ar_posting_id`, `linked_invoice_id`, `applied_to_ar_posting_id`, `bank_reference`, `received_via`, `write_off_reason_code`, `credit_memo_number`, `transfer_group_uuid`).
2. Rename `invoice_status_events → ar_posting_status_events` with polymorphic `transitioner_type / transitioner_id`.
3. `class Invoice < ApplicationRecord` becomes `class Invoice < ARPosting`. Associations stay. Validations stay. Enum stays.
4. Existing FKs (`invoice_line_items.invoice_id` etc.) re-target `ar_postings.id` after the rename; Postgres handles atomically.
5. New subtypes are skeletal: `CreditMemo < ARPosting`, `OnAccountCash < ARPosting`, `Reversal < ARPosting`. Each adds its own enum, validators, and subtype-only `has_many`'s.

No back-fill. No two-phase deploy. No production back-pressure. This is the cheapest the polymorphic move will ever be — and the deadline is the first real Sailfin sync (comparison doc Decision 4, line 358).

---

## Validation invariants

- **`Reversal`**: `original_ar_posting_id` required; original must share `customer_account_id` and `currency`; original must not itself be a `Reversal` (use `WriteBack` for that); `signed_amount_cents == -1 * original.signed_amount_cents`; original's status transitions to `reversed`.
- **`CreditMemo`**: `linked_invoice_id` nullable but if present must be an `Invoice` on the same `customer_account_id`; `signed_amount_cents < 0`.
- **`OnAccountCash`**: `customer_account_id`, `received_via`, `bank_reference` all required; `signed_amount_cents < 0`.
- **`WriteOff`**: `write_off_authority_user_id` required and **must differ from `created_by_user_id`** (segregation of duties — proposer can't approve their own write-off).
- **`Offset` / `AppliedCredit`**: `applied_to_ar_posting_id` required; pair must share customer account and currency.
- **`AccountTransfer`**: the row pair must share `operator_id` (already enforced one level up by `client_and_customer_share_operator` on `Customer::Account`, `app/models/customer/account.rb:66–71`).
- **Cross-subtype**: a soft-deleted `ARPosting` cannot be the target of `original_ar_posting_id` / `applied_to_ar_posting_id` from a live posting. Soft-delete propagation through the FK graph.

---

## Risk table — what's reversible later vs what locks things in

| Choice | Reversible later? | If wrong, cost is |
|---|---|---|
| STI vs CTI vs polymorphic-subject | STI → CTI by splitting tables, doable. STI → polymorphic-subject, near-impossible once AR-aging queries depend on the unified shape. | Schema migration, 1–2 days, no data loss while volumes are small |
| `signed_amount_cents` on parent | Adding signed columns later requires backfill | Trivial now; days later |
| Rename `invoices → ar_postings` | Catastrophically hard once Sailfin sync runs | Must not defer past first real sync |
| Per-subtype natural-key partial unique indexes | Fully reversible | Cheap either direction |
| Polymorphic `state_transitions` log | Hard to back-fill historical transitions if started Invoice-only | Add the polymorphic shape now, even before all subtypes are wired |
| `kind` value list (the 12 from Gap 12) | Adding new values cheap; removing/renaming expensive | Err toward fewer values; split a subtype later if needed |
| `Reversal.original_ar_posting_id` required | `required → nullable` easy; nullable → required hard | Default to required |
| Discriminator column = `type` | Renaming a Rails STI discriminator after binding is painful | Use the framework default |
| Per-subtype `status` integer mappings | Per-subtype refactor easy; cross-subtype renumbering ugly | Lock Invoice's existing integer mapping now |
| `Payment` association on cash subtypes | Forward-compatible (nullable FK when `Payment` lands) | Defer until Gap 1 resolves |
| Sidecar `ar_posting_reversal_details` table | Pressure-release valve; reversible | No cost to defer |

The two **non-reversible** choices are (a) the inheritance shape itself and (b) the per-subtype natural keys. Both must be settled before the first real Sailfin sync. That's the only hard date on this list.

---

## Closing

The cleanest combined read of Gap 12 + Gap 14 + Gap 15 is: **STI parent `ARPosting`, twelve subtypes, `signed_amount_cents` at parent level, status as a polymorphic transition log generalized from `invoice_status_events`, source identity at parent level, per-subtype natural keys as partial unique indexes.** The migration path is short because there's no production data. The validation invariants are well-defined per subtype. The interaction with the previously-flagged structural omissions is additive — every one of (state-transition log, soft-delete, field-level provenance, structured extensibility) becomes a parent-level capability that twelve subtypes inherit for free.

One flag for the other Gap-12 reviewers: this is the largest structural change on the comparison doc's roadmap, and it's also the cheapest. Comparison doc Decision 4 (migration fidelity, line 358) and Decision 7 (picklist translation, line 360) both implicitly assume `Invoice` is the receiving shape; both need re-reading against `ARPosting` once this lands.
