require "test_helper"

class MappingValueEntriesTest < ActionDispatch::IntegrationTest
  setup do
    @analyst = User.create!(email_address: "analyst@example.com", password: "secret-pass-1", role: :analyst)
    @analyst_pii = User.create!(email_address: "pii@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    @schema = JSON.parse(File.read(Rails.root.join("test/fixtures/files/cashline_snapshot.json")))
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: @schema)

    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false, user: @analyst, status: "complete", completed_at: Time.current)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account", raw_describe: {})
    @field = Sfield.create!(sobject: @sobject, api_name: "Status__c", data_type: "picklist", sensitivity: "safe", raw_describe: {})
    SpicklistValue.create!(sfield: @field, value: "Submitted", label: "Submitted", active: true)
    SpicklistValue.create!(sfield: @field, value: "Open", label: "Open", active: true)
    @op = ObjectProfile.create!(extraction_run: @run, sobject: @sobject, status: "complete", record_count: 100, profiled_at: Time.current)
    FieldProfile.create!(object_profile: @op, sfield: @field, null_rate: 0.0,
      top_values: [ { "v" => "Submitted", "c" => 60 }, { "v" => "Legacy", "c" => 5 } ], sample_values: [])

    # Invoice#status is enum-bearing in the fixture (draft/submitted/approved).
    @entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "status", mapping_type: "value_collapse")
  end

  def sign_in(user)
    sign_in_as(user)
  end

  test "index renders declared and undeclared source values with frequency and enum options" do
    sign_in(@analyst)
    get mapping_values_path(@entry)
    assert_response :success
    assert_match "Submitted", response.body          # declared
    assert_match "Legacy", response.body              # undeclared (in top_values only)
    assert_match "undeclared", response.body
    assert_match "submitted", response.body           # target enum option
    assert_match "60", response.body                  # in-data frequency
  end

  test "mapping a source value to an enum value persists a value entry" do
    sign_in(@analyst)
    assert_difference -> { MappingValueEntry.count }, 1 do
      post mapping_values_path(@entry), params: { mapping_value_entry: { source_value: "Submitted", target_enum_value: "submitted" } }
    end
    ve = @entry.mapping_value_entries.find_by(source_value: "Submitted")
    assert_equal "submitted", ve.target_enum_value
  end

  test "an undeclared in-data value is mappable by its raw string" do
    sign_in(@analyst)
    post mapping_values_path(@entry), params: { mapping_value_entry: { source_value: "Legacy", target_enum_value: "draft" } }
    ve = @entry.mapping_value_entries.find_by(source_value: "Legacy")
    assert_equal "draft", ve.target_enum_value
  end

  test "a source value mapped to drop persists with the drop sentinel" do
    sign_in(@analyst)
    post mapping_values_path(@entry), params: { mapping_value_entry: { source_value: "Open", target_enum_value: MappingValueEntry::DROP } }
    assert @entry.mapping_value_entries.find_by(source_value: "Open").dropped?
  end

  test "selecting blank clears an existing value mapping" do
    MappingValueEntry.create!(mapping_entry: @entry, source_value: "Submitted", target_enum_value: "submitted")
    sign_in(@analyst)
    assert_difference -> { MappingValueEntry.count }, -1 do
      post mapping_values_path(@entry), params: { mapping_value_entry: { source_value: "Submitted", target_enum_value: "" } }
    end
  end

  test "a picklist field with no field_profile renders declared values without erroring" do
    FieldProfile.where(sfield: @field).delete_all
    sign_in(@analyst)
    get mapping_values_path(@entry)
    assert_response :success
    assert_match "Submitted", response.body
  end

  test "a non-privileged user cannot view the value sub-table for a sensitive-run field" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true)
    sf = Sfield.create!(sobject: Sobject.create!(extraction_run: sensitive_run, api_name: "Lead"), api_name: "Stage__c", data_type: "picklist", raw_describe: {})
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: sf,
      target_class: "Invoice", target_field: "status", mapping_type: "value_collapse")

    sign_in(@analyst)
    get mapping_values_path(entry)
    assert_response :not_found
  end

  test "a PII field in a non-sensitive run shows a locked message instead of values" do
    pii = Sfield.create!(sobject: @sobject, api_name: "SSN__c", data_type: "picklist", sensitivity: "pii", raw_describe: {})
    SpicklistValue.create!(sfield: pii, value: "X", label: "X", active: true)
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: pii,
      target_class: "Invoice", target_field: "status", mapping_type: "value_collapse")

    sign_in(@analyst)
    get mapping_values_path(entry)
    assert_response :success
    assert_match(/hidden for this sensitive field/i, response.body)
    refute_match "X", response.body
  end
end
