require "test_helper"

class MappingValueEntryTest < ActiveSupport::TestCase
  setup do
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: {})
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
    @field = Sfield.create!(sobject: @sobject, api_name: "Status__c")
    @entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "status", mapping_type: "value_collapse")
  end

  test "a value entry with an undeclared source_value persists and associates to its parent" do
    # "Legacy" is not a declared spicklist value — raw strings are tolerated.
    value = MappingValueEntry.create!(mapping_entry: @entry, source_value: "Legacy", target_enum_value: "draft")
    assert value.persisted?
    assert_equal @entry, value.mapping_entry
  end

  test "source_value is unique within a mapping entry" do
    MappingValueEntry.create!(mapping_entry: @entry, source_value: "Submitted", target_enum_value: "submitted")
    dup = MappingValueEntry.new(mapping_entry: @entry, source_value: "Submitted", target_enum_value: "approved")
    assert_not dup.valid?
  end

  test "drop and derive sentinels are recognized" do
    dropped = MappingValueEntry.create!(mapping_entry: @entry, source_value: "Void", target_enum_value: MappingValueEntry::DROP)
    derived = MappingValueEntry.create!(mapping_entry: @entry, source_value: "Calc", target_enum_value: MappingValueEntry::DERIVE)
    assert dropped.dropped?
    assert derived.derived?
    assert dropped.sentinel?
  end

  test "destroying the parent entry destroys its value entries" do
    MappingValueEntry.create!(mapping_entry: @entry, source_value: "Submitted", target_enum_value: "submitted")
    assert_difference -> { MappingValueEntry.count }, -1 do
      @entry.destroy!
    end
  end
end
