require "test_helper"

class ExtractionRunPolicyTest < ActiveSupport::TestCase
  setup do
    @analyst = User.create!(email_address: "a@example.com", password: "secret-pass-1", role: :analyst)
    @analyst_pii = User.create!(email_address: "p@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    @admin = User.create!(email_address: "ad@example.com", password: "secret-pass-1", role: :admin, sensitive_data_access: true)
    @reader = User.create!(email_address: "r@example.com", password: "secret-pass-1", role: :read_only)
    @plain_run = ExtractionRun.new(api_version: "62.0", status: "queued", include_sensitive: false)
    @sensitive_run = ExtractionRun.new(api_version: "62.0", status: "queued", include_sensitive: true)
  end

  test "analyst with sensitive_data_access is permitted to trigger_with_pii?" do
    assert ExtractionRunPolicy.new(@analyst_pii, @sensitive_run).trigger_with_pii?
  end

  test "analyst without sensitive_data_access is denied trigger_with_pii?" do
    refute ExtractionRunPolicy.new(@analyst, @sensitive_run).trigger_with_pii?
  end

  test "read_only user is denied create?" do
    refute ExtractionRunPolicy.new(@reader, @plain_run).create?
  end

  test "read_only user cannot show a sensitive run" do
    refute ExtractionRunPolicy.new(@reader, @sensitive_run).show?
  end

  test "analyst without role can show non-sensitive runs but not sensitive ones" do
    assert ExtractionRunPolicy.new(@analyst, @plain_run).show?
    refute ExtractionRunPolicy.new(@analyst, @sensitive_run).show?
  end

  test "admin with role can show sensitive runs" do
    assert ExtractionRunPolicy.new(@admin, @sensitive_run).show?
  end

  test "Scope excludes sensitive runs for users without sensitive_data_access" do
    plain = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    sensitive = ExtractionRun.create!(api_version: "62.0", include_sensitive: true)

    scope = ExtractionRunPolicy::Scope.new(@analyst, ExtractionRun.all).resolve
    ids = scope.pluck(:id)

    assert_includes ids, plain.id
    refute_includes ids, sensitive.id, "Scope must hide sensitive runs from users without sensitive_data_access"
  end

  test "Scope includes sensitive runs for users with sensitive_data_access" do
    plain = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    sensitive = ExtractionRun.create!(api_version: "62.0", include_sensitive: true)

    scope = ExtractionRunPolicy::Scope.new(@analyst_pii, ExtractionRun.all).resolve
    ids = scope.pluck(:id)

    assert_includes ids, plain.id
    assert_includes ids, sensitive.id
  end

  test "Scope returns nothing for unauthenticated users" do
    ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    scope = ExtractionRunPolicy::Scope.new(nil, ExtractionRun.all).resolve
    assert_equal 0, scope.count
  end
end
