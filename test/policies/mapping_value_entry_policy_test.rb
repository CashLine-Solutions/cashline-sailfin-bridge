require "test_helper"

class MappingValueEntryPolicyTest < ActiveSupport::TestCase
  setup do
    @analyst = User.create!(email_address: "a@example.com", password: "secret-pass-1", role: :analyst)
    @analyst_pii = User.create!(email_address: "p@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)

    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: {})

    @plain_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @plain_field = Sfield.create!(sobject: Sobject.create!(extraction_run: @plain_run, api_name: "Account"), api_name: "Status__c")
    @plain_entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @plain_field,
      target_class: "Invoice", target_field: "status", mapping_type: "value_collapse")
    @plain_value = MappingValueEntry.create!(mapping_entry: @plain_entry, source_value: "Open", target_enum_value: "draft")

    @sensitive_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true)
    @sensitive_field = Sfield.create!(sobject: Sobject.create!(extraction_run: @sensitive_run, api_name: "Lead"), api_name: "Stage__c")
    @sensitive_entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @sensitive_field,
      target_class: "Invoice", target_field: "stage", mapping_type: "value_collapse")
    @sensitive_value = MappingValueEntry.create!(mapping_entry: @sensitive_entry, source_value: "Hot", target_enum_value: "submitted")
  end

  test "value-entry scope hides child rows whose parent's source is sensitive, for non-privileged users" do
    ids = MappingValueEntryPolicy::Scope.new(@analyst, MappingValueEntry.all).resolve.pluck(:id)
    assert_includes ids, @plain_value.id
    refute_includes ids, @sensitive_value.id
  end

  test "value-entry scope shows everything for privileged users" do
    ids = MappingValueEntryPolicy::Scope.new(@analyst_pii, MappingValueEntry.all).resolve.pluck(:id)
    assert_includes ids, @plain_value.id
    assert_includes ids, @sensitive_value.id
  end

  test "child of a net_new parent (null source) stays visible" do
    net_new = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: nil,
      target_class: "Invoice", target_field: "new_status", mapping_type: "net_new")
    value = MappingValueEntry.create!(mapping_entry: net_new, source_value: "X", target_enum_value: "draft")

    ids = MappingValueEntryPolicy::Scope.new(@analyst, MappingValueEntry.all).resolve.pluck(:id)
    assert_includes ids, value.id
  end

  test "analyst can create/update/destroy value entries; unauthenticated cannot" do
    assert MappingValueEntryPolicy.new(@analyst, @plain_value).create?
    assert MappingValueEntryPolicy.new(@analyst, @plain_value).destroy?
    refute MappingValueEntryPolicy.new(nil, @plain_value).create?
  end
end
