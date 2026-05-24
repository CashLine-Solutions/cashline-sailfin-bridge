require "test_helper"

module Ontology
  class ProfilingPolicyTest < ActiveSupport::TestCase
    setup do
      @user_with = User.create!(email_address: "ops@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
      @user_without = User.create!(email_address: "viewer@example.com", password: "secret-pass-1", role: :read_only)
      @run_sensitive = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, user: @user_with, seed_objects: [])
      @run_plain = ExtractionRun.create!(api_version: "62.0", include_sensitive: false, user: @user_with, seed_objects: [])

      sobject = Sobject.create!(extraction_run: @run_sensitive, api_name: "Contact", raw_describe: {})
      @safe_field = Sfield.create!(sobject: sobject, api_name: "Title", data_type: "string", sensitivity: "safe", raw_describe: {})
      @pii_field = Sfield.create!(sobject: sobject, api_name: "Email", data_type: "email", sensitivity: "pii", raw_describe: {})
      @unknown_field = Sfield.create!(sobject: sobject, api_name: "Foo__c", data_type: "string", sensitivity: "unknown_sensitivity", raw_describe: {})
    end

    test "safe field is always allowed" do
      policy = ProfilingPolicy.new(extraction_run: @run_plain, user: @user_without)
      assert policy.allow_sensitive_values?(@safe_field).allowed?
    end

    test "unknown_sensitivity field is denied even with override flag and role" do
      policy = ProfilingPolicy.new(extraction_run: @run_sensitive, user: @user_with)
      decision = policy.allow_sensitive_values?(@unknown_field)
      refute decision.allowed?
      assert_equal "unknown_sensitivity", decision.reason
    end

    test "pii field denied when run lacks include_sensitive" do
      policy = ProfilingPolicy.new(extraction_run: @run_plain, user: @user_with)
      decision = policy.allow_sensitive_values?(@pii_field)
      refute decision.allowed?
      assert_equal "sensitive_run_flag_missing", decision.reason
    end

    test "pii field denied when user lacks sensitive_data_access" do
      policy = ProfilingPolicy.new(extraction_run: @run_sensitive, user: @user_without)
      decision = policy.allow_sensitive_values?(@pii_field)
      refute decision.allowed?
      assert_equal "user_lacks_sensitive_data_access", decision.reason
    end

    test "pii field allowed when both flags are set" do
      policy = ProfilingPolicy.new(extraction_run: @run_sensitive, user: @user_with)
      decision = policy.allow_sensitive_values?(@pii_field)
      assert decision.allowed?
      assert_equal "override_active", decision.reason
    end

    test "deny_all class method denies everything" do
      policy = ProfilingPolicy.deny_all
      refute policy.allow_sensitive_values?(@pii_field).allowed?
      assert policy.allow_sensitive_values?(@safe_field).allowed?
    end
  end
end
