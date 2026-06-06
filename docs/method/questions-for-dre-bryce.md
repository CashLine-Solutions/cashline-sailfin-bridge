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

## 5. What is the canonical customer name — "whatever Salesforce says" or the real legal entity?

**Context.** The importer copies `Account.Name` from Sailfin verbatim into `Customer::Account.display_name` (no transformation). Salesforce casing is inconsistent by record — some accounts are entered ALL CAPS (`XTO - TYLER`, `DEVON ENERGY - NTX`, `TOKLAN OIL & GAS`), others are mixed case (`XTO Energy Incorporated`, `Javelin Oil & Gas, LLC`, `Central Maine Power (CMP) - Avangrid`). The names also often encode a location/division suffix (`- TYLER`, `- NTX`, `- Avangrid`) rather than a clean legal entity name.

This is AR / collections data — the customer name can end up on invoices, dispute correspondence, and potentially legal demand letters, so "what name is correct" is a real-world question, not cosmetic.

**Question.** What should cashline treat as the canonical customer name?

1. **Verbatim Salesforce** — preserve exactly what's in `Account.Name`, shouty caps and all. (Current behavior. Faithful to source, but inconsistent and sometimes location-suffixed rather than a clean entity name.)
2. **Normalized casing** — keep the Salesforce name but fix obvious casing (`XTO - TYLER` → `XTO - Tyler`) via a deterministic titlecase with an acronym/suffix allow-list (`LLC`, `Inc`, `XTO`, `&`, etc.). Cosmetic only; doesn't change identity.
3. **Resolved legal entity** — enrich each account with the real legal name (`XTO Energy Inc.`) matched against an authoritative registry (SEC EDGAR / OpenCorporates / D&B), with a confidence score and a human review queue for low-confidence matches. Higher effort; needed only if collections/legal documents require the true legal entity.

**Important constraint if we pursue (2) or (3).** Whatever we resolve, we would store it *alongside* the verbatim Salesforce name (e.g. `display_name` verbatim + `normalized_name` + `legal_name` + `legal_name_source` + `confidence`), never overwriting source — so provenance is preserved and we can always see what Sailfin actually said. We would **not** use a raw LLM as the source of truth for legal names (hallucination risk on `Inc.` vs `LLC`, merging unrelated same-named companies); an LLM, if used, would only fuzzy-match against a registry and return an ID + confidence, not invent a name.

**What the answer enables.** Decides whether the importer stays a verbatim copy (option 1, zero extra work), gains a cheap deterministic casing pass (option 2), or grows a separate registry-backed enrichment layer with a review queue (option 3). Also decides whether the location/division suffix in names matters — e.g. is `XTO - TYLER` a distinct customer from `XTO - NTX`, or two divisions of one legal entity that should roll up?

**Important finding — the legal name is *absent* in Sailfin, not just inconsistently cased.** cashline's `customer_organizations` table already has a nullable `legal_name` column, but it is `null` for every org — the importer doesn't map it, and there is no good Sailfin source to map *from*. Checked across all 135,366 Accounts in run #13:

| Sailfin field on `Account` | Population | Usable as legal name? |
|---|---|---|
| `Bill_To_Name__c` | **0 / 135,366 (0%)** | No — empty on every record |
| `Entity__c` | 7,812 (5.8%) | No — truncated 6-char codes (`XTO EN`, `CHEVRO`, `INACT`), not legal names |
| `Name` | ~100% | This is what we already use for `display_name` / `canonical_name` — the shouty, location-suffixed string |

So the only customer name Sailfin reliably carries is `Account.Name`. A clean legal billing name **does not exist in the source data** — it isn't lost in translation, it was never captured in Salesforce. That reframes option 3: it's not "pick the better of two names we have," it's "the legal name has to be *derived* (registry enrichment) or *entered by hand*, because there's nothing to copy." If `legal_name` staying null is acceptable, option 1 stands and no work is needed.

**Status.** Pending review. Raised 2026-06-05.

---

## 6. Should location-suffixed customer accounts roll up under one `Customer::Organization`? (And does the customer-group UI need building?)

**Context.** Browsing the imported data, the same parent appears as multiple separate customers distinguished only by a location suffix, e.g. `BREITBURN OPERATING - GAYLORD` and `BREITBURN OPERATING - HOUSTON`. Today the importer dedups customer orgs by the *full* normalized `Account.Name`, so each of these becomes its **own** `Customer::Organization` with a single account — they aren't related to each other.

**The data model already supports grouping.** cashline's customer side mirrors the client side exactly:

```
Customer::Organization  ──has_many──>  Customer::Group  ──has_many──>  Customer::Account
        (parent)                          (sub-division)                  (billing acct)
```

`Customer::Account` already `belongs_to :customer_group, optional: true`. So the schema can express "BREITBURN OPERATING (org) → Gaylord, Houston (groups/accounts)" — nothing needs to be added to the data model. This is purely a question of *how the importer maps Sailfin's flat names into the hierarchy*, plus a UI gap (below).

**Evidence (run #13, 135,366 Accounts).** The ` - ` suffix pattern is real but not dominant:

| Metric | Value |
|---|---|
| Accounts whose `Name` contains ` - ` | 2,658 (**2.0%**) |
| Example shared prefixes (= candidate parent orgs) | DFAS (142 accounts), TIC (60), USAF (39), National Grid (24), EOG Resources (17), Equistar Chemicals LP (17), Anadarko (13) |
| Caveat | Some prefixes are clean parents; others are messy codes (`RAL25008-130-PROGRESS ENERGY`) that shouldn't be parsed naively |

**Questions.**
1. **Semantics.** Is `PARENT - LOCATION` genuinely one customer with multiple billing locations (→ roll up under one `Customer::Organization`, locations become `Customer::Group`s or sibling `Customer::Account`s), or are these intentionally distinct customers that just share a name prefix? This likely varies — DFAS (a government paymaster) vs. an oil operator's regional offices may want different treatment.
2. **Automation vs. curation.** If they should roll up, is the ` - ` naming reliable enough to auto-parse during import, or is this operator-curated (importer keeps them flat; operator merges/groups by hand later)? Given only 2% use the pattern and some prefixes are codes, auto-parsing risks both false merges and missed ones.
3. **UI gap.** The operator interface currently has **no way to edit customer groups** — there's a full `client_groups` controller + views (create/edit/delete) on the client side, but **no `customer_groups` controller or views** at all. So even manual curation isn't possible in the UI today. If the answer to (1)/(2) involves any operator grouping of customers, the customer-group management UI needs to be built to match the client side.

**What the answer enables.** Decides (a) whether the importer's customer-org dedup key changes from "full name" to "parsed parent," (b) whether we build customer-group CRUD UI to mirror clients, and (c) how AR rolls up for reporting — per-location vs. per-parent-customer aging.

**Status.** Pending review. Raised 2026-06-05.

---

## 7. When an org has only ONE group, what do we do — name it "Default"/"Main", or hide groups until there are 2+? (Clients AND customers)

**Context.** As we roll Sailfin accounts up into `Organization → Group → Account`, most orgs will have a single group (or none). Example: the `DALLAS, CITY OF` grouping decomposes into two real groups — `ELM FORK WTP.` (9 accounts) and `WATER UTILITIES` (4 accounts) — plus 2 plain `DALLAS, CITY OF` accounts with **no** location suffix. The "no suffix" accounts, and any org with just one group, raise the single-group question. This applies symmetrically to **`Client::Group`** and **`Customer::Group`** (and overlaps Q2's "auto-create default group" question).

**The tension.** Several cashline FKs are **NOT NULL** — `Customer::Account.client_group_id`, and `client_group_id`/`customer_group_id` on invoices/communication_events/operational_tasks. So at the *data* layer a group row often must exist to satisfy the FK, even for a single-group org. "Hiding" single groups is therefore mostly a **UI** decision (the default group row still exists in the DB) — unless we make those FKs nullable.

**Operator's decision on the data model.** The data layer **always** puts every account in a group — uniform structure, every NOT NULL `*_group_id` satisfied, no nullable special-case. Suffix-less accounts (e.g. the 2 plain `DALLAS, CITY OF`) get a default/lone group like any other. The **UI hides the group axis when an org has only one group**, surfacing it only once there are 2+. So "hiding" is purely presentation; the structure holds true underneath. This applies symmetrically to **Client** and **Customer** groups. (This is option 2 below, now chosen.)

**What still needs expert input.** Only the **name of the default/lone group**:
1. `"Default"`
2. `"Main"`
3. `"General"`
4. The org's own name (e.g. `Dallas, City Of`)

Plus confirmation that "always create a group at the data layer, hide singletons in the UI" is the right call vs. the alternatives below.

**Alternatives (recorded, not chosen).**
- Make group FKs nullable so single-group orgs genuinely have no group (bigger schema change; rejected in favor of uniform structure).
- Name and always-show a single group (rejected — clutters the UI when there's only one).

**What the answer enables.** Settles the lone-group label the importer creates for suffix-less accounts, and the cashline-platform UI rule (hide group axis until ≥2). Tightly coupled to [Q2] (auto-create default group) and [Q6] (suffix → group decomposition).

**Status.** Data-model approach decided by operator (always-group + hide-singletons-in-UI). **Open for expert (Dre/Bryce + others) input: the default-group name + sanity-check the approach.** Raised 2026-06-05.

---
