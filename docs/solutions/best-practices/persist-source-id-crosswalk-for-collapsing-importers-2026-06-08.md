---
title: Persist a source-id crosswalk so downstream importers survive upstream record collapse
date: 2026-06-08
category: best-practices
module: sync
problem_type: best_practice
component: service_object
severity: high
related_components:
  - rails_model
  - database
  - background_job
applies_when:
  - "An upstream importer collapses, rolls up, or merges many source records into fewer canonical rows"
  - "A downstream importer joins to those canonical rows on a source foreign key"
  - "That source FK can point at a merged-in member, not the kept representative"
  - "Re-deriving the mapping downstream needs fields the downstream payload lacks"
  - "Importers run cross-database or in separate, non-atomic transactions"
tags:
  - data-import
  - crosswalk
  - record-merging
  - etl-pipeline
  - upsert
  - idempotency
  - cross-database
  - sync
---

# Persist a source-id crosswalk so downstream importers survive upstream record collapse

## Context

A Rails 8.1 bridge imports Sailfin into an external cashline "sync" DB across multiple, ordered stages. The **Account importer collapses many records into one**: it folds many Sailfin `Account` rows into a single `customer_account` per `(customer org/group × client org/group)` pairing, rolls accounts up under shared customer organizations, and merges operator-confirmed grouping variants. The persisted `customer_accounts` row keeps only the *representative* member's `sailfin_account_id` (chosen deterministically — prefers a member carrying an `account_number`, then the lexically-lowest id). Every other member account in that pairing is collapsed away with no row of its own.

The friction surfaces in the **downstream** stage. A Sailfin `Contact.AccountId` points at whatever Account the contact was filed under — and that is *often a merged-in member*, not the representative. So the obvious downstream join:

```ruby
# WRONG — silently drops/mis-routes contacts on any collapsed account
customer_accounts.sailfin_account_id == contact["AccountId"]
```

fails for exactly the records that were collapsed: the member's id is nowhere in `customer_accounts`, so the join misses. There's no error — the contact just vanishes (or, if a stale id collides, lands on the wrong customer). With ~72% of Accounts dormant and heavy roll-up (e.g. ~50 `KINDER MORGAN *` accounts → one org), the naive join would **silently lose a large fraction of contacts** and split one customer's people across the wrong orgs. The same trap waits for the future invoice importer, which also keys off `Account`.

## Guidance

**Have the upstream (collapsing) importer emit a persisted `source-id → canonical-record` crosswalk that covers every collapsed member, and resolve all downstream stages through it — never re-derive the collapse logic and never join on the representative id alone.**

**1. Track every member during the collapse**, not just the survivor:

```ruby
pairings = {}
members_by_pairing = Hash.new { |h, k| h[k] = [] }
scope.find_each do |rec|
  p = rec.payload
  # ... resolve org/group/client ...
  row = customer_account_row(p, customer_org_id, client_org_id, client_group_id, customer_group_id)
  key = [ customer_org_id, customer_group_id, client_org_id, client_group_id ]
  pairings[key] = merge_pairing(pairings[key], row)   # keeps the representative
  members_by_pairing[key] << p["Id"]                  # remembers ALL members
end
```

**2. Recover each pairing's persisted id with `returning:`** after the bulk upsert, so the crosswalk points at real ids without re-querying:

```ruby
def upsert_customer_accounts(rows)
  id_map = {}
  rows.each_slice(UPSERT_BATCH) do |slice|
    result = CashlineSync::CustomerAccount.upsert_all(
      slice, unique_by: %i[sailfin_account_id client_organization_id],
      returning: %i[id sailfin_account_id client_organization_id]
    )
    result.each { |r| id_map[[ r["sailfin_account_id"], r["client_organization_id"] ]] = r["id"] }
  end
  id_map  # { [sailfin_account_id, client_org_id] => customer_account_id }
end
```

**3. Fan the representative's persisted id out to every member** — this is what makes the merged-in members resolvable:

```ruby
def build_crosswalk(pairings, members_by_pairing, id_map)
  rows = []
  pairings.each do |key, rep|
    customer_account_id = id_map[[ rep[:sailfin_account_id], rep[:client_organization_id] ]]
    next unless customer_account_id
    customer_org_id, customer_group_id, = key
    members_by_pairing[key].each do |sailfin_account_id|   # EVERY member, not just rep
      rows << {
        extraction_run_id: @run_id,
        sailfin_account_id: sailfin_account_id,
        customer_account_id: customer_account_id,
        customer_organization_id: customer_org_id,
        customer_group_id: customer_group_id,
        created_at: Time.current, updated_at: Time.current
      }
    end
  end
  rows
end
```

**4. Persist after the sync-DB transaction commits — cross-DB, so not atomic; lean on idempotent full-refresh.** The crosswalk lives in the bridge *primary* DB (separate connection) while the rows it describes live in the *external sync* DB. They can't share one transaction, so `persist_crosswalk` runs *after* the sync transaction closes, and each run full-refreshes its own slice. A re-run rebuilds both sides in lockstep — a mid-run failure just means "run it again," never a permanently-skewed crosswalk:

```ruby
CashlineSync::CustomerAccount.transaction do   # external sync DB
  purge_customer_data(operator_id)
  # ... build pairings, upsert, capture id_map ...
  crosswalk = build_crosswalk(pairings, members_by_pairing, id_map)
end
persist_crosswalk(crosswalk)                   # primary DB, AFTER commit

def persist_crosswalk(rows)
  SyncAccountCrosswalk.where(extraction_run_id: @run_id).delete_all      # full refresh per run
  rows.each_slice(UPSERT_BATCH) { |slice| SyncAccountCrosswalk.insert_all(slice) } if rows.present?
end
```

The table has a unique index on `[extraction_run_id, sailfin_account_id]` (one row per run × source account) and **no FKs on the `customer_*` columns** because those ids reference the external sync DB. (session history) It is scoped per extraction run, not global, so re-running a run regenerates only that run's slice.

**5. Downstream: resolve through the crosswalk, skip the unresolvable.**

```ruby
def crosswalk
  @crosswalk ||= SyncAccountCrosswalk
    .where(extraction_run_id: @run_id)
    .pluck(:sailfin_account_id, :customer_account_id, :customer_group_id, :customer_organization_id)
    .each_with_object({}) { |(sid, account, group, org), h| h[sid] = { account:, group:, org: } }
end

scope.find_each do |rec|
  p = rec.payload
  target = crosswalk[p["AccountId"]]
  unless target            # no AccountId (~27%), or a dormant account not in the crosswalk
    @stats[:skipped_unresolved] += 1
    next
  end
  rows << contact_row(p, target)
end
rows.each_slice(UPSERT_BATCH) do |slice|
  CashlineSync::CustomerContact.upsert_all(slice, unique_by: :sailfin_contact_id)  # idempotent re-runs
end
```

**6. Make the ordering dependency explicit.** Accounts must run before contacts so the crosswalk is fresh. A `cashline_sync:import_all` one-shot runs both in order in one process ("accounts (emits the crosswalk) then contacts (route through it). The safe one-shot.").

**Decisions / rationale:**
- **Persist vs. re-derive the mapping downstream → persist.** Single source of truth, reusable by every later importer, and re-deriving is impossible here: the collapse logic needs the account's `Name` for org/group resolution, which the `Contact` payload doesn't carry.
- **Skip vs. synthesize an "Unassigned" customer → skip.** No real `customer_account` to hang unresolvable contacts on; a synthetic bucket would pollute the collections workspace.

## Why This Matters

The failure this prevents is **silent data loss / mis-routing** — the worst kind. The naive representative-id join throws no error, just a smaller-than-expected result set and a few customers whose contacts scatter across the wrong orgs. On a heavily collapsed dataset that's tens of thousands of dropped records hiding behind a green run.

Beyond correctness, the crosswalk is a **single source of truth** for "where did source account X land after roll-up." Every downstream stage (contacts now, **invoices next**) resolves through the same table instead of re-implementing — and drifting from — the upstream collapse rules. That duplication is especially dangerous because the collapse depends on operator-confirmed groupings and on payload fields (`Name`) downstream objects don't have. Emit-once, resolve-everywhere keeps canonicalization in exactly one place.

## When to Apply

Any **multi-stage import where an upstream stage dedups, rolls up, or merges source records** and a **downstream stage references the original source ids**. Trigger signs:

- The upstream stage produces *fewer* canonical rows than source rows (N:1 collapse), keeping only a representative's source id on the persisted row.
- A downstream object references source ids that can be *any* of the collapsed members, not just the survivor.
- The collapse logic depends on inputs the downstream payload lacks (re-deriving downstream is impossible or fragile).
- Stages run against different databases / connections (you need a deliberate persist-after-commit + idempotent refresh, not one big transaction).

Then: have the collapsing stage emit a persisted `source-id → canonical-record` crosswalk covering **every** member, key it on a per-run natural key, full-refresh it each run, and make stage ordering explicit (one-shot task).

## Examples

- **KINDER MORGAN roll-up.** ~50 `KINDER MORGAN *` accounts that operator-confirmed groupings rolled into a single `KINDER MORGAN` customer organization (a group per variant: `NGPL`, `SNG`, …). The 94 contacts on those member accounts all carried *member* `AccountId`s — none the representative. Verified: **all 94 routed to the single KM org** via the crosswalk.
- **Merged-in member resolution.** Contacts whose `AccountId` was a collapsed member (an id absent from `customer_accounts.sailfin_account_id`) still resolved to the representative `customer_account`, because the crosswalk fans the representative's id out to every member id.
- **Run 13 totals:** 49,087 contacts imported, 20,734 skipped (= 69,821 total; skips = ~27% with no `AccountId` plus contacts on dormant accounts the activity gate excluded). **0 dangling account ids**, **0 denormalized-org mismatches**.

## Related

- `docs/solutions/test-failures/external-database-breaks-transactional-fixtures-2026-06-07.md` — sibling: it tests the very `Sync::AccountImporter` whose collapse this crosswalk survives, but its subject is test isolation, not record resolution.
- `docs/plans/2026-06-03-001-feat-sailfin-cashline-data-importer-plan.md` — **stale on this topic.** It models FK resolution as an in-memory single-pass map and frames `Contact.AccountId` as a naive parent→child join with an orphan policy; it predates the account collapse/roll-up/merge and this persisted crosswalk. Worth updating: in-memory map → persisted `SyncAccountCrosswalk`; contacts resolve via crosswalk, not a naive join.
- No related GitHub issues found.
