# Open questions for Dre & Bryce

Schema/design questions that came up while mapping Sailfin → cashline-platform. Each entry has the evidence we found and what the answer unlocks.

---

## 1. Should `Client::Organization` carry brand contact/address columns?

**Context.** Sailfin's `Account` table denormalizes the brand's contact and address info onto every customer row (the Brand_*_c fields on Account are 99%+ populated, see `sailfin-to-cashline-field-map.md`):

| Sailfin field on `Account` | Population | What it holds |
|---|---|---|
| `Brand_Name__c` | 99.998% | Canonical brand name |
| `Brand_Code__c` | 99.998% | Short code (CorrproUS, EnduranceLift) |
| `Brand_Phone__c` | 97.1% | Brand-level support phone |
| `Brand_Email__c` | 99.6% | Brand-level support email |
| `Brand_Fax__c` | 11.1% | Sparse |
| `Brand_City__c` | 99.9% | HQ city |
| `Brand_Street__c` | 99.9% | HQ street |
| `Brand_State_Province__c` | 99.9% | HQ state/province |
| `Brand_ZIP_PostalCode__c` | 99.9% | HQ postal code |
| `Brand_Country__c` | 99.7% | HQ country |
| `Brand_Manager__c` | 99.4% | Manager (free-text name string) |
| `Brand_Region__c` | 1.7% | Sparse |

Cashline's current `Client::Organization` schema has only `name`, `description`, `slug`, `operator_id`, `group_label`, timestamps — no contact or address columns.

**Question.** Should we add headquarters/contact columns to `Client::Organization` so the Sailfin Brand contact info comes across? Candidates:

- `headquarters_city`, `headquarters_street`, `headquarters_state`, `headquarters_postal_code`, `headquarters_country`
- `support_phone`, `support_email`
- `brand_manager_name` (free-text)

**Alternatives.**
- Keep `Client::Organization` lean; if cashline needs brand contact info later, add it then.
- Or stash brand contact/address in a generic `metadata jsonb` column so it doesn't require schema changes per field.

**What the answer enables.** Decides whether ~9 Sailfin Account.Brand_*_c fields map to real cashline columns or get dropped (net_new with no destination).

**Status.** Pending review. Raised 2026-06-02.

---

## 2. Should sync auto-create default `Client::Group` and `Customer::Group` rows on first sync?

**Context.** Sailfin has no concept of sub-groups — neither within a Brand (the 53 brand codes map 1:1 to 53 `Client::Organization` rows) nor within a customer organization (Accounts dedup to one Customer::Org each, with no further subdivision visible in source data). But cashline's data model attaches AR records (Customer::Accounts, Invoices, CommunicationEvents, OperationalTasks) to both a `client_group_id` and a `customer_group_id`, several of which are `null: false`.

**Question.** When sync creates a fresh `Client::Organization` or `Customer::Organization`, should it also create a default `Group` row (e.g. name="All", or name=`<org name>`) so all downstream AR records have a non-null `*_group_id` to point at? Or should sync defer group creation until the operator manually configures sub-groups?

**Applies symmetrically to:**
- `Client::Group` (sub-divisions within a Client::Org)
- `Customer::Group` (sub-divisions within a Customer::Org — e.g. "Chevron Texas" vs "Chevron South America")

**Alternatives.**
- Sync auto-creates `"All"` group per org on first import.
- Sync auto-creates a group named after the org on first import.
- Sync leaves group FKs null; operator must create groups before any AR can land.
- Make `client_group_id` / `customer_group_id` nullable on the AR tables that currently require them.

**What the answer enables.** Decides whether 50+ `*_group_id` `sync_managed` FK columns across `customer_accounts`, `invoices`, `communication_events`, `operational_tasks`, etc. can be filled without operator intervention on the first sync.

**Status.** Pending review. Raised 2026-06-02.

---

## 3. Are operator-side portal credentials (login URL, account ID at vendor) stored anywhere in Sailfin we haven't audited?

**Context.** `Customer::AccountPortal` holds the operator/client's login credentials for a customer-mandated invoice-submission portal (OpenInvoice, Ariba, Textura, etc.) — what login URL Corrpro uses, what their OpenInvoice account ID is when billing Chevron, etc.

The only Sailfin signal we've found is `Account.Ecommerce_System__c` (2.4% populated, free-text vendor name with spelling variants). It names the portal but doesn't carry credentials.

We've also checked: `Account.Account_ID_Text__c` is the Salesforce Id, not a portal-side ID; `Brand__c` config fields are limited to ABA/lockbox/bank details. No object in run #12's metadata has a `Portal_*` or `Login_*` pattern that looks like portal credentials.

**Question.** Before we conclude that portal credentials are net_new in cashline (operator enters them once per customer-portal pairing), can you confirm there isn't a Sailfin object we haven't looked at — a `sfsrm__Portal_Config__c`, an Attachment with credentials, a Custom Setting — that already holds this data?

**What the answer enables.** Decides whether sync can pre-populate ~3,233 portal rows with at least the login URL/identifier, or whether the operator has to enter every one manually.

**Status.** Pending review. Raised 2026-06-02.

---

## 4. `Invoice#recalculate_totals` overwrites `balance_due_cents` for partially-paid invoices

**Context.** `app/models/invoice.rb`'s `recalculate_totals` before_validation callback:

```ruby
self.balance_due_cents = paid? || closed? || void? ? 0 : total_cents
```

For `status = :paid` / `:closed` / `:void` → `balance_due_cents = 0` ✓.
For all other states (including `:partially_paid`, `:short_paid`) → `balance_due_cents = total_cents`.

This means an invoice in `:partially_paid` state with $300 of $1,000 still outstanding will end up with `balance_due_cents = 100000` (the total, not the remaining $30,000 cents).

**Question.** Is this intended? Sync would like to set `balance_due_cents = Amount_Outstanding__c × 100` from Sailfin for accurate AR aging, but the callback overwrites it. Options:

- Skip the recalculation for `:partially_paid` / `:short_paid` states (let sync's value stand).
- Add a `partial_paid_balance_cents` column the operator can set manually.
- Recompute from a separate `payments_received_cents` column: `balance_due_cents = total_cents - payments_received_cents`.
- Make the callback a no-op when `balance_due_cents` was set explicitly within the transaction.

**What the answer enables.** Accurate AR aging for partially-paid invoices on initial Sailfin sync. Currently sync can either (a) set `:paid` everywhere `Amount_Outstanding__c == 0` and lose the partial state, or (b) accept that partially-paid balances will be wrong until the operator manually updates them.

**Status.** Pending review. Raised 2026-06-03.

---
