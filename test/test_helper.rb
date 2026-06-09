ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # cashline_sync is an external (cashline-platform) database with
    # database_tasks:false — Rails neither migrates it nor creates per-worker
    # parallel copies. Keep it out of the transactional-fixtures machinery so any
    # test that loads a CashlineSync model doesn't make every other test in the
    # worker try (and fail) to pin a connection to it. Sync-DB tests manage their
    # own isolation. See Sync::AccountImporterTest.
    skip_transactional_tests_for_database(:cashline_sync)

    # SessionsController#create rate-limit counters live in Rails.cache, which
    # is a process-wide memory_store in test. Without this, throttling state
    # accumulates across tests in a worker and a later test's login silently
    # 302s back to /session/new. Clear it before each test for isolation.
    setup { Rails.cache.clear }

    # Add more helper methods to be used by all tests here...
  end
end
