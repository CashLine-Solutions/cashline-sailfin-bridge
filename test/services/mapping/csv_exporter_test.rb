require "test_helper"

class Mapping::CsvExporterTest < ActiveSupport::TestCase
  setup do
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s",
      schema_json: JSON.parse(File.read(Rails.root.join("test/fixtures/files/cashline_snapshot.json"))))
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
    @field = Sfield.create!(sobject: @sobject, api_name: "Invoice_Number__c")
    @user = User.create!(email_address: "u@example.com", password: "secret-pass-1", role: :analyst)
  end

  def parse(csv) = CSV.parse(csv, headers: true)

  test "field_csv emits one row per mapping with columns in header order" do
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct",
      confidence: "high", reviewed: true, updated_by: @user,
      transformation_note: "trim whitespace", source_citation: "interview note")

    csv = parse(Mapping::CsvExporter.new(entries: [ entry ], snapshot: @snapshot, include_free_text: true).field_csv)
    assert_equal Mapping::CsvExporter::FIELD_HEADERS, csv.headers
    row = csv.first
    assert_equal "Invoice", row["cashline_class"]
    assert_equal "invoice_number", row["cashline_field"]
    assert_equal "string", row["cashline_type"]
    assert_equal "direct", row["mapping_type"]
    assert_equal "Account", row["sailfin_object"]
    assert_equal "Invoice_Number__c", row["sailfin_field"]
    assert_equal "trim whitespace", row["transformation_note"]
    assert_equal "interview note", row["source_citation"]
    assert_equal "u@example.com", row["last_updated_by"]
  end

  test "free-text columns are blanked when include_free_text is false" do
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct",
      transformation_note: "real value leak", source_citation: "another value")

    csv = parse(Mapping::CsvExporter.new(entries: [ entry ], snapshot: @snapshot, include_free_text: false).field_csv)
    row = csv.first
    assert_nil row["transformation_note"]
    assert_nil row["source_citation"]
    assert_equal "Invoice", row["cashline_class"] # structural columns still present
  end

  test "net_new row has blank source columns; dropped row has source and blank target" do
    net_new = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: nil,
      target_class: "Invoice", target_field: "amount_cents", mapping_type: "net_new")
    dropped = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: nil, target_field: nil, mapping_type: "dropped")

    csv = parse(Mapping::CsvExporter.new(entries: [ net_new, dropped ], snapshot: @snapshot, include_free_text: true).field_csv)
    nn_row = csv.find { |r| r["mapping_type"] == "net_new" }
    assert_nil nn_row["sailfin_object"]
    assert_equal "Invoice", nn_row["cashline_class"]

    dropped_row = csv.find { |r| r["mapping_type"] == "dropped" }
    assert_equal "Invoice_Number__c", dropped_row["sailfin_field"]
    assert_nil dropped_row["cashline_class"]
  end

  test "value_csv emits source to target enum value rows" do
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "status", mapping_type: "value_collapse")
    MappingValueEntry.create!(mapping_entry: entry, source_value: "Submitted", target_enum_value: "submitted", notes: "n")

    csv = parse(Mapping::CsvExporter.new(entries: [ entry ], snapshot: @snapshot, include_free_text: true).value_csv)
    row = csv.first
    assert_equal "Invoice#status", row["cashline_target"]
    assert_equal "Submitted", row["source_value"]
    assert_equal "submitted", row["target_enum_value"]
  end
end
