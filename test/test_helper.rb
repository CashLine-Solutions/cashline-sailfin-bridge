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

    # SessionsController#create rate-limit counters live in Rails.cache, which
    # is a process-wide memory_store in test. Without this, throttling state
    # accumulates across tests in a worker and a later test's login silently
    # 302s back to /session/new. Clear it before each test for isolation.
    setup { Rails.cache.clear }

    # Add more helper methods to be used by all tests here...
  end
end
