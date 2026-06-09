---
title: External (database_tasks:false) connection breaks transactional fixtures under parallel tests
date: 2026-06-07
category: test-failures
module: Sync
problem_type: test_failure
component: testing_framework
symptoms:
  - "ActiveRecord::NoDatabaseError: Database not found: cashline_sailfin_sync_test_8, raised from active_record/test_fixtures.rb (setup_transactional_fixtures / pin_connection!)"
  - "Unrelated transactional tests fail only in the full parallel suite, never when run in isolation"
  - "Failure only appears after some earlier test in the same worker has loaded a CashlineSync:: model"
root_cause: test_isolation
resolution_type: config_change
severity: high
related_components:
  - service_object
  - database
  - rails_model
rails_version: 8.1.3
tags:
  - rails-8
  - transactional-fixtures
  - parallel-testing
  - external-database
  - database-tasks-false
  - connection-pinning
  - test-isolation
  - multi-database
---

# External (database_tasks:false) connection breaks transactional fixtures under parallel tests

## Problem

Adding the first test that touched an external database (the `cashline_sync` connection,
configured `database_tasks: false`) silently broke **unrelated** tests across the whole
suite. Merely loading a `CashlineSync::*` model registers its connection pool, and Rails
transactional fixtures then try to pin (open a transaction on) that external pool for every
subsequent test in the worker — connecting to a database Rails never provisions.

## Symptoms

- Tests with nothing to do with the sync DB began failing with:
  ```
  ActiveRecord::NoDatabaseError: Database not found: cashline_sailfin_sync_test_8
  ```
- The error originated in the framework, not app code — `active_record/test_fixtures.rb`,
  in `setup_transactional_fixtures` → `pin_connection!` (the per-test "open a transaction on
  every writing pool" step).
- **Order- and worker-dependent:** only tests that ran *after* some test in the same parallel
  worker had loaded a `CashlineSync::*` model failed. The same test passed when run in
  isolation and failed in the full parallel suite (e.g. `ModularityClustererTest`,
  `HeuristicMatcherTest` — neither touches the sync DB).
- The DB name carried a `_8` suffix — the per-worker parallel-test suffix — even though
  `cashline_sync` is `database_tasks: false`, so Rails never created
  `cashline_sailfin_sync_test_8`. Hence "Database not found."

## What Didn't Work

**Dead end 1 — a per-test skip guard.** The first instinct was to have the sync-DB test
return early (`skip`) when the DB was unreachable. It didn't help: Rails transactional
fixtures **eagerly pin every registered pool in `setup_transactional_fixtures` before any
test body runs**, so the guard never executed. The pool was already registered (by loading
the model) and the pin failed during fixture setup.

**Dead end 2 — `self.use_transactional_tests = false` on the sync test class.** Turning off
transactional fixtures *only on the test that touched the sync DB* (plus manual cleanup) did
**not** stop the cross-test pollution. The problem was never that one class: once *any* test
loads a `CashlineSync::*` model, the sync pool is registered process-wide, and **every other**
test class — still using transactional fixtures — keeps trying to pin it. The fix had to be
global. After applying it, this class reverted to normal transactional fixtures for its
primary-DB records.

**Dead end 3 — Minitest `Object#stub` for the rollback test.** Stubbing `upsert_all` to raise
via Minitest's `stub` failed at load time: `LoadError: cannot load such file -- minitest/mock`
(Minitest 6.x dropped the bundled mock). Replaced with a real subclass that overrides the
rebuild seam to raise, guarded by `assert_raises` so a future rename can't silently turn the
test into a no-op.

## Solution

**1. The global one-liner — `test/test_helper.rb`.** Exclude the external pool from the
fixtures pinning loop for the entire suite, the moment the connection is wired up:

```ruby
module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)
    fixtures :all

    # cashline_sync is an external (cashline-platform) database with
    # database_tasks:false — Rails neither migrates it nor creates per-worker
    # parallel copies. Keep it out of the transactional-fixtures machinery so any
    # test that loads a CashlineSync model doesn't make every other test in the
    # worker try (and fail) to pin a connection to it.
    skip_transactional_tests_for_database(:cashline_sync)
  end
end
```

**2. Injectable operator — `app/services/sync/scaffolding_builder.rb`.** The external DB can't
use transaction rollback for isolation, so tests isolate by *data*: a unique throwaway
operator per test (the purge is operator-scoped). That required making the operator
name/slug constructor args (defaults reproduce production):

```ruby
def initialize(operator_name: OPERATOR_NAME, operator_slug: OPERATOR_SLUG)
  @operator_name = operator_name
  @operator_slug = operator_slug
end
```

**3. The integration test — `test/services/sync/account_importer_test.rb`.** Self-skip when
the sync DB is unreachable, unique operator per test, `FailingImporter` subclass for the
rollback test, explicit teardown (its writes commit for real):

```ruby
class Sync::AccountImporterTest < ActiveSupport::TestCase
  # Fails AFTER the purge (rebuild step) to prove the transaction rolls back.
  # assert_raises guards against this override going stale if the hook is renamed.
  class FailingImporter < Sync::AccountImporter
    private
    def upsert_customer_accounts(_rows) = raise "rebuild blew up"
  end

  setup do
    @op_slug = "test-op-#{SecureRandom.hex(8)}"
    @scaffolding = Sync::ScaffoldingBuilder.new(operator_name: @op_slug, operator_slug: @op_slug)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sync_available = sync_available?
  end

  teardown { purge_sync_operator if @sync_available }

  test "a failure during rebuild rolls back the purge so the prior import survives" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available
    # ...baseline import...
    assert_raises(RuntimeError) do
      FailingImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
    end
    assert_equal 2, account_count(%w[ACC1 ACC9]),
      "purge rolled back with the failed rebuild — the prior import is intact"
  end

  private

  def sync_available?
    CashlineSync::Operator.connection.select_value("SELECT 1 FROM operators LIMIT 1")
    true
  rescue StandardError
    false
  end
end
```

**4. Provision the local test DB.** Schema-only dump of the self-contained tables (their FKs
reference only each other), since `database_tasks: false` means Rails never creates it:

```bash
pg_dump --schema-only \
  -t operators -t client_organizations -t client_groups \
  -t customer_organizations -t customer_groups -t customer_accounts \
  cashline_sailfin_sync \
  | psql cashline_sailfin_sync_test
```

## Why This Works

The failure chain is **pool registration → eager pin → parallel suffix**:

1. **Registration.** Loading any `CashlineSync::*` model (each inherits `CashlineSyncRecord`,
   which `connects_to database: {writing: :cashline_sync, reading: :cashline_sync}`) registers
   a writing pool for `:cashline_sync` in the process — even if no row is ever read.
2. **Eager pin.** Transactional fixtures don't connect lazily. `setup_transactional_fixtures`
   → `pin_connection!` walks **every registered writing pool** and opens a transaction on it
   before each test, establishing a real connection to each.
3. **Parallel suffix.** Under `parallelize`, Rails appends a per-worker suffix (`_8`) to
   database names — including the external one. But `database_tasks: false` means Rails never
   *created* `cashline_sailfin_sync_test_8`, so the eager pin hits a nonexistent DB →
   `NoDatabaseError`.

`skip_transactional_tests_for_database(:cashline_sync)` (Rails 8.1) writes the exclusion into
the `database_transactions_config` class attribute. The fixtures machinery consults it via
`transactional_tests_for_pool?`, which now returns `false` for the sync pool, so
`pin_connection!` **skips** it. The pool stays registered (models still query fine), but it's
never eagerly pinned — no unrelated test tries to open a transaction against the nonexistent
per-worker DB. Primary-DB records still get full transactional rollback.

## Prevention

- **Any pool with `database_tasks: false` must be excluded from transactional fixtures.** If
  Rails won't provision/migrate a DB (external, owned by another service), it must not be in
  the pinning loop. Add `skip_transactional_tests_for_database(:that_db)` to `test_helper.rb`
  when you wire up the connection — before the first test loads one of its models, not after
  the suite mysteriously goes red.
- **Recognize the signature:** a `NoDatabaseError` / "Database not found" with a `_N` suffix,
  raised from `test_fixtures.rb` (`setup_transactional_fixtures` / `pin_connection!`), failing
  in *unrelated* tests that only fail in the parallel suite — that's an unexcluded external
  pool, not a bug in the failing test.
- **Gate external-infra integration tests on a self-skip** so CI stays green until the DB is
  wired up, rather than hard-failing.
- **Isolate the shared external DB by data, not by transaction.** A unique throwaway operator
  per test plus an operator-scoped purge in `teardown` (its writes commit for real). Such tests
  run when invoked directly and skip cleanly in the full parallel suite (the shared DB isn't
  per-worker-provisioned).
- **Don't rely on Minitest's bundled `mock`/`stub`** (gone in Minitest 6.x). Prefer a real
  subclass that overrides the seam, wrapped in `assert_raises`.

## Related Issues

- Originating feature: the test locks in a **full-refresh importer** — `Sync::AccountImporter#call`
  purges the operator's customer orgs/groups/accounts then rebuilds inside one transaction, so
  re-syncing after a customer grouping is confirmed leaves no orphaned rows. Verified live
  against grouping "AECOM ENERGY & CONSTRUCTION, INC" (135,366 accounts → 6 accounts collapse
  to one org, 0 orphans).
- Refresh candidate: `docs/plans/2026-06-03-001-feat-sailfin-cashline-data-importer-plan.md`
  still describes importer re-runs as additive ("upsert, never duplicating", "re-runs replace
  in place", "re-run is a no-op on counts"). The full-refresh change makes those claims
  partially stale — re-runs now purge then rebuild, and counts can change.
- No related GitHub issues found (`gh issue list` searches returned none).
