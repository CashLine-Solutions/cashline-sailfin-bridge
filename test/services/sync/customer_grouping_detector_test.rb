require "test_helper"

class Sync::CustomerGroupingDetectorTest < ActiveSupport::TestCase
  setup { @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false) }

  test "legal-suffix variants auto-confirm as one grouping" do
    acct("A1", "AIR PRODUCTS & CHEMICALS")
    acct("A2", "AIR PRODUCTS & CHEMICALS INC")
    acct("A3", "AIR PRODUCTS & CHEMICALS, INC.")

    Sync::CustomerGroupingDetector.call(@run)

    g = grouping_named("AIR PRODUCTS")
    assert_equal 1, CustomerGrouping.for_run(@run.id).count, "all suffix variants land in one grouping"
    assert_equal "normalized_name", g.detection_method
    assert_equal "confirmed", g.state, "suffix-only variants auto-confirm"
    assert_not g.user_modified, "auto-confirmed, not operator-confirmed"
    assert_equal 3, g.members.count
  end

  test "location/project roll-ups auto-confirm (name_prefix)" do
    acct("B1", "ALCOA")
    acct("B2", "ALCOA, INC")
    acct("B3", "ALCOA - POINT COMFORT") # the " - POINT COMFORT" becomes a group at import

    Sync::CustomerGroupingDetector.call(@run)

    g = grouping_named("ALCOA")
    assert_equal "name_prefix", g.detection_method
    assert_equal "confirmed", g.state
    assert_equal 3, g.members.count
  end

  test "internal-code-looking parents stay open for review" do
    acct("C1", "RAL25008-130 - PHASE 1")
    acct("C2", "RAL25008-130 - PHASE 2")

    Sync::CustomerGroupingDetector.call(@run)

    assert_equal "open", grouping_named("RAL25008").state, "code-like parents are not auto-confirmed"
  end

  test "exact duplicates still auto-confirm" do
    acct("F1", "VIKING SANITATION")
    acct("F2", "VIKING SANITATION")

    Sync::CustomerGroupingDetector.call(@run)

    g = grouping_named("VIKING SANITATION")
    assert_equal "exact_duplicate", g.detection_method
    assert_equal "confirmed", g.state
  end

  test "re-detect upgrades a still-open machine grouping to confirmed" do
    acct("E1", "BATSON-COOK COMPANY")
    acct("E2", "BATSON-COOK")
    # Seed it as if a prior, stricter run left it open and untouched.
    g = CustomerGrouping.create!(extraction_run: @run, parent_name: "BATSON-COOK",
      detection_method: "normalized_name", confidence: "high", state: "open", user_modified: false)

    Sync::CustomerGroupingDetector.call(@run)

    assert_equal "confirmed", g.reload.state
  end

  test "re-detect never overrides an operator's reject" do
    acct("D1", "DELTA FAUCET COMPANY")
    acct("D2", "DELTA FAUCET")
    Sync::CustomerGroupingDetector.call(@run)
    g = grouping_named("DELTA FAUCET")
    g.update!(state: "rejected", user_modified: true)

    Sync::CustomerGroupingDetector.call(@run)

    assert_equal "rejected", g.reload.state, "operator's decision is preserved on re-detect"
  end

  private

  def acct(id, name)
    SfRecord.create!(extraction_run: @run, object_api_name: "Account", sf_id: id,
      exported_at: Time.current, payload: { "Id" => id, "Name" => name })
  end

  def grouping_named(prefix)
    CustomerGrouping.for_run(@run.id).where("parent_name ILIKE ?", "#{prefix}%").first
  end
end
