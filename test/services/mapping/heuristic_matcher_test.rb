require "test_helper"

class Mapping::HeuristicMatcherTest < ActiveSupport::TestCase
  setup do
    schema = {
      "classes" => [
        { "class_name" => "Invoice", "namespace" => nil, "columns" => [
          { "name" => "id", "type" => "integer" },
          { "name" => "invoice_number", "type" => "string" },
          { "name" => "stage_label", "type" => "string" },
          { "name" => "status", "type" => "integer", "enum_values" => { "draft" => 0, "submitted" => 1, "approved" => 2 } }
        ] }
      ]
    }
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: schema)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
    @matcher = Mapping::HeuristicMatcher.new(snapshot: @snapshot)
  end

  test "proposes the lexically matching target above unrelated candidates" do
    field = Sfield.create!(sobject: @sobject, api_name: "Invoice_Number__c", data_type: "string")
    candidates = @matcher.candidates_for(field)
    assert_equal "invoice_number", candidates.first[:target_field]
    refute candidates.any? { |c| c[:target_field] == "id" }, "noise targets like id are skipped"
  end

  test "a type-compatible picklist-overlapping candidate outranks a closer string match" do
    field = Sfield.create!(sobject: @sobject, api_name: "Stage__c", data_type: "picklist")
    SpicklistValue.create!(sfield: field, value: "Draft", active: true)
    SpicklistValue.create!(sfield: field, value: "Submitted", active: true)

    candidates = @matcher.candidates_for(field)
    status = candidates.find { |c| c[:target_field] == "status" }
    stage_label = candidates.find { |c| c[:target_field] == "stage_label" }

    assert status, "expected status among candidates"
    assert stage_label, "expected stage_label among candidates"
    # stage_label is the closer pure-lexical match, but status wins on the
    # combined type + picklist-overlap signal.
    assert status[:score] > stage_label[:score], "picklist-overlapping candidate must outrank the closer string match"
    assert_equal "status", candidates.first[:target_field]
    assert_equal 1.0, status[:signals]["picklist"]
  end
end
