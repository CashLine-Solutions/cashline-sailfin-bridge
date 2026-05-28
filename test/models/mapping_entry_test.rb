require "test_helper"

class MappingEntryTest < ActiveSupport::TestCase
  setup do
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: {})
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account")
    @field = Sfield.create!(sobject: @sobject, api_name: "Name__c")
    @other = Sfield.create!(sobject: @sobject, api_name: "Other__c")
  end

  def edge(attrs = {})
    MappingEntry.create!({
      cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct"
    }.merge(attrs))
  end

  test "a direct mapping with a target persists and is findable by source field" do
    mapping = edge
    assert mapping.persisted?
    assert_equal mapping, @field.mapping_entries.first
  end

  test "a second entry for the same source+target violates the targeted-edge unique index" do
    edge
    assert_raises(ActiveRecord::RecordNotUnique) { edge }
  end

  test "a second null-target row for the same source violates the null-target unique index" do
    edge(target_class: nil, target_field: nil, mapping_type: nil, reviewed: true)
    assert_raises(ActiveRecord::RecordNotUnique) do
      edge(target_class: nil, target_field: nil, mapping_type: nil, reviewed: true)
    end
  end

  test "a reviewed-no-home row and a targeted split leg for the same source coexist" do
    reviewed_no_home = edge(target_class: nil, target_field: nil, mapping_type: nil, reviewed: true)
    split_leg = edge(target_class: "Invoice", target_field: "amount_cents", mapping_type: "split")
    assert reviewed_no_home.persisted?
    assert split_leg.persisted?
    assert reviewed_no_home.reviewed_no_home?
  end

  test "a net_new entry persists with a null source_field_id" do
    nn = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: nil,
      target_class: "Invoice", target_field: "new_field", mapping_type: "net_new")
    assert nn.persisted?
    assert_nil nn.source_field_id
    assert nn.net_new?
  end

  test "two net_new entries for the same target violate the unique index (COALESCE collapses null source)" do
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: nil,
      target_class: "Invoice", target_field: "new_field", mapping_type: "net_new")
    assert_raises(ActiveRecord::RecordNotUnique) do
      MappingEntry.create!(cashline_snapshot: @snapshot, source_field: nil,
        target_class: "Invoice", target_field: "new_field", mapping_type: "net_new")
    end
  end

  test "deleting one leg of a 2-leg split demotes the surviving split to direct" do
    leg_a = edge(target_field: "invoice_number", mapping_type: "split")
    leg_b = edge(target_field: "amount_cents", mapping_type: "split")
    leg_a.destroy!
    assert_equal "direct", leg_b.reload.mapping_type
  end

  test "deleting a split leg does not demote or relabel a coexisting reviewed-no-home row" do
    reviewed_no_home = edge(target_class: nil, target_field: nil, mapping_type: nil, reviewed: true)
    leg_a = edge(target_field: "invoice_number", mapping_type: "split")
    leg_b = edge(target_field: "amount_cents", mapping_type: "split")
    leg_a.destroy!
    assert_equal "direct", leg_b.reload.mapping_type
    assert_nil reviewed_no_home.reload.mapping_type
    assert_nil reviewed_no_home.target_class
  end

  test "upsert_edge is idempotent and concurrency-safe for the same key" do
    a = MappingEntry.upsert_edge(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", attributes: { mapping_type: "direct" })
    b = MappingEntry.upsert_edge(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", attributes: { confidence: "high" })
    assert_equal a.id, b.id
    assert_equal 1, MappingEntry.where(source_field: @field).count
    assert_equal "high", b.confidence
  end

  test "split_siblings counts only targeted rows, excluding the reviewed-no-home row" do
    reviewed_no_home = edge(target_class: nil, target_field: nil, mapping_type: nil, reviewed: true)
    leg_a = edge(target_field: "invoice_number", mapping_type: "split")
    leg_b = edge(target_field: "amount_cents", mapping_type: "split")
    assert_equal 1, leg_a.split_siblings.count
    assert_includes leg_a.split_siblings, leg_b
    assert_not_includes leg_a.split_siblings, reviewed_no_home
  end

  test "also_mapped_from_count surfaces the N:1 indicator" do
    edge # @field -> Invoice#invoice_number
    second = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @other,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct")
    assert_equal 1, second.also_mapped_from_count
  end

  test "validates target_class and target_field are set together" do
    bad = MappingEntry.new(cashline_snapshot: @snapshot, source_field: @field, target_class: "Invoice")
    assert_not bad.valid?
    assert_includes bad.errors.attribute_names, :target_field
  end

  test "validates source presence matches net_new" do
    no_source = MappingEntry.new(cashline_snapshot: @snapshot, source_field: nil,
      target_class: "Invoice", target_field: "x", mapping_type: "direct")
    assert_not no_source.valid?

    net_new_with_source = MappingEntry.new(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "x", mapping_type: "net_new")
    assert_not net_new_with_source.valid?
  end
end
