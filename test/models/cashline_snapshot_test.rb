require "test_helper"

class CashlineSnapshotTest < ActiveSupport::TestCase
  def schema_json
    JSON.parse(File.read(Rails.root.join("test/fixtures/files/cashline_snapshot.json")))
  end

  def build_snapshot
    CashlineSnapshot.create!(loaded_at: Time.current, sha256: "abc", schema_json: schema_json)
  end

  test "classes enumerates sorted class names" do
    snapshot = build_snapshot
    assert_equal [ "Ingestion::Connector", "Invoice" ], snapshot.classes
  end

  test "classes_by_namespace groups by directory namespace" do
    snapshot = build_snapshot
    grouped = snapshot.classes_by_namespace
    assert_equal [ "Ingestion::Connector" ], grouped["Ingestion"]
    assert_equal [ "Invoice" ], grouped[nil]
  end

  test "fields_for returns column descriptors including enum-bearing fields" do
    snapshot = build_snapshot
    names = snapshot.fields_for("Invoice").map { |c| c["name"] }
    assert_includes names, "invoice_number"
    assert_includes names, "status"
    assert_empty snapshot.fields_for("DoesNotExist")
  end

  test "field returns the column descriptor for a natural key" do
    snapshot = build_snapshot
    field = snapshot.field("Invoice", "invoice_number")
    assert_equal "string", field["type"]
    assert_nil snapshot.field("Invoice", "missing_column")
  end

  test "enum_bearing? and enum_values resolve enum columns" do
    snapshot = build_snapshot
    assert snapshot.enum_bearing?("Invoice", "status")
    assert_not snapshot.enum_bearing?("Invoice", "invoice_number")
    assert_equal({ "draft" => 0, "submitted" => 1, "approved" => 2 }, snapshot.enum_values("Invoice", "status"))
    assert_nil snapshot.enum_values("Invoice", "invoice_number")
  end

  test "current returns the most recently loaded snapshot" do
    older = CashlineSnapshot.create!(loaded_at: 2.days.ago, sha256: "old", schema_json: schema_json)
    newer = CashlineSnapshot.create!(loaded_at: 1.hour.ago, sha256: "new", schema_json: schema_json)
    assert_equal newer, CashlineSnapshot.current
    assert_not_equal older, CashlineSnapshot.current
  end
end
