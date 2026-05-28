require "test_helper"

class MappingEntryPolicyTest < ActiveSupport::TestCase
  setup do
    @analyst = User.create!(email_address: "a@example.com", password: "secret-pass-1", role: :analyst)
    @analyst_pii = User.create!(email_address: "p@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    @admin = User.create!(email_address: "ad@example.com", password: "secret-pass-1", role: :admin, sensitive_data_access: true)
    @reader = User.create!(email_address: "r@example.com", password: "secret-pass-1", role: :read_only)

    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: {})

    @plain_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @plain_field = Sfield.create!(sobject: Sobject.create!(extraction_run: @plain_run, api_name: "Account"), api_name: "Name__c")

    @sensitive_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true)
    @sensitive_field = Sfield.create!(sobject: Sobject.create!(extraction_run: @sensitive_run, api_name: "Lead"), api_name: "SSN__c")
  end

  def mapping_for(field, target_field)
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: field,
      target_class: "Invoice", target_field: target_field, mapping_type: "direct")
  end

  test "analyst can create/update, read_only cannot, admin can destroy" do
    record = mapping_for(@plain_field, "a")
    assert MappingEntryPolicy.new(@analyst, record).create?
    assert MappingEntryPolicy.new(@analyst, record).update?
    refute MappingEntryPolicy.new(@reader, record).create?
    refute MappingEntryPolicy.new(@analyst, record).destroy?
    assert MappingEntryPolicy.new(@admin, record).destroy?
  end

  test "read_only can view" do
    record = mapping_for(@plain_field, "a")
    assert MappingEntryPolicy.new(@reader, record).show?
    assert MappingEntryPolicy.new(@reader, record).index?
  end

  test "a user without sensitive_data_access cannot see a mapping whose source belongs to a sensitive run" do
    plain = mapping_for(@plain_field, "a")
    sensitive = mapping_for(@sensitive_field, "b")

    ids = MappingEntryPolicy::Scope.new(@analyst, MappingEntry.all).resolve.pluck(:id)
    assert_includes ids, plain.id
    refute_includes ids, sensitive.id
  end

  test "a net_new mapping (no source) is visible to all authenticated users" do
    net_new = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: nil,
      target_class: "Invoice", target_field: "new_field", mapping_type: "net_new")

    ids = MappingEntryPolicy::Scope.new(@analyst, MappingEntry.all).resolve.pluck(:id)
    assert_includes ids, net_new.id
  end

  test "users with sensitive_data_access see everything" do
    plain = mapping_for(@plain_field, "a")
    sensitive = mapping_for(@sensitive_field, "b")
    ids = MappingEntryPolicy::Scope.new(@analyst_pii, MappingEntry.all).resolve.pluck(:id)
    assert_includes ids, plain.id
    assert_includes ids, sensitive.id
  end

  test "Scope returns nothing for unauthenticated users" do
    mapping_for(@plain_field, "a")
    assert_equal 0, MappingEntryPolicy::Scope.new(nil, MappingEntry.all).resolve.count
  end
end
