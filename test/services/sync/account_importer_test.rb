require "test_helper"

# Integration test for the full-refresh importer. It writes to the external
# cashline-platform sync schema, so it self-skips unless that DB is reachable
# (provision locally with a schema-only dump of the 6 customer/client tables
# into `cashline_sailfin_sync_test`; CI stays green until that DB is wired up).
#
# Each test runs against a throwaway operator (purge is operator-scoped) so the
# shared sync DB is safe under parallel workers.
class Sync::AccountImporterTest < ActiveSupport::TestCase
  # Fails after the purge has run (rebuild step) to prove the transaction rolls
  # the purge back. assert_raises in the test guards against this override
  # silently going stale if the rebuild hook is renamed.
  class FailingImporter < Sync::AccountImporter
    private

    def upsert_customer_accounts(_rows) = raise "rebuild blew up"
  end

  # Primary-DB records (run/sf_records/groupings) roll back via transactional
  # fixtures as usual. The sync DB is excluded from that machinery
  # (skip_transactional_tests_for_database in test_helper), so its writes commit
  # for real — hence the explicit per-operator teardown. A unique run + operator
  # per test keeps the shared sync DB safe under parallel workers.
  setup do
    @op_slug = "test-op-#{SecureRandom.hex(8)}"
    @scaffolding = Sync::ScaffoldingBuilder.new(operator_name: @op_slug, operator_slug: @op_slug)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sync_available = sync_available?
  end

  teardown { purge_sync_operator if @sync_available }

  test "re-importing after a grouping is confirmed collapses orgs and leaves no orphans" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    acme = [
      sf_account("ACC1", "ACME CORP"),
      sf_account("ACC2", "ACME CORP, INC"),
      sf_account("ACC3", "ACME CORP, INC."),
    ]
    sf_account("ACC9", "OTHER CO")
    grouping = build_grouping("ACME CORP", acme, state: "open")

    # Run 1 — grouping still open: the three name variants normalize apart and
    # each becomes its own customer org (this is the residue a re-sync must clean).
    import!
    assert_equal 3, acme_org_ids.size, "open grouping: each name variant is its own org"
    assert_equal 4, customer_orgs.count

    # Operator confirms the grouping — exactly what the /grouping button does.
    grouping.update!(state: "confirmed", user_modified: true)

    # Run 2 — full refresh re-applies under the confirmed parent.
    import!
    assert_equal 1, acme_org_ids.size, "confirmed grouping: all variants share one org"
    assert_equal "ACME CORP", CashlineSync::CustomerOrganization.find(acme_org_ids.first).canonical_name
    assert_equal 2, customer_orgs.count, "only ACME CORP + OTHER CO remain"
    assert_equal 0, orphan_org_count, "the two stale variant orgs from run 1 are purged"
    assert_equal 0, orphan_group_count, "their groups are purged too"
    # The three ACME variants now share one pairing (one org / Main / one client),
    # so they roll up into a single representative account; OTHER CO stays its own.
    assert_equal 1, account_count(%w[ACC1 ACC2 ACC3]), "the three variants collapse into one account"
    assert_equal 1, account_count(%w[ACC9]), "OTHER CO is untouched"
  end

  test "groupings rolled up under a customer become groups of one shared org" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    ngpl = sf_account("KM1", "KINDER MORGAN/NGPL")
    sng  = sf_account("KM2", "KINDER MORGAN/SNG")
    bare = sf_account("KM3", "KINDER MORGAN")
    g_ngpl = build_grouping("KINDER MORGAN / NGPL", [ngpl], state: "confirmed")
    g_sng  = build_grouping("KINDER MORGAN / SNG", [sng], state: "confirmed")
    g_bare = build_grouping("KINDER MORGAN", [bare], state: "confirmed")
    g_ngpl.update!(customer_name: "KINDER MORGAN", group_label: "NGPL")
    g_sng.update!(customer_name: "KINDER MORGAN", group_label: "SNG")
    g_bare.update!(customer_name: "KINDER MORGAN", group_label: nil) # bare -> Main

    import!

    org_ids = CashlineSync::CustomerAccount.where(sailfin_account_id: %w[KM1 KM2 KM3])
                                           .distinct.pluck(:customer_organization_id)
    assert_equal 1, org_ids.size, "all three roll up into one customer org"
    assert_equal "KINDER MORGAN", CashlineSync::CustomerOrganization.find(org_ids.first).canonical_name
    groups = CashlineSync::CustomerGroup.where(customer_organization_id: org_ids.first).pluck(:name).sort
    assert_equal %w[Main NGPL SNG], groups, "each grouping is its own group; the bare one falls back to Main"
  end

  test "accounts with no AR transactions are excluded from the sync" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("LIVE", "LIVE CO", active: true)
    sf_account("DORMANT", "DORMANT CO", active: false)

    import!

    assert_equal 1, account_count(%w[LIVE]), "the account with a transaction is imported"
    assert_equal 0, account_count(%w[DORMANT]), "the dormant account is filtered out"
    assert_nil CashlineSync::CustomerOrganization.find_by(operator_id: operator_id, canonical_name: "DORMANT CO"),
      "the dormant account's org is never created"
  end

  test "multiple active accounts in the same pairing collapse to one account" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    # Same name -> same customer org + Main group; same brand -> same client.
    # No grouping needed: they already land in one (customer x client) pairing.
    sf_account("DUP1", "VIKING SANITATION")
    sf_account("DUP2", "VIKING SANITATION")
    sf_account("DUP3", "VIKING SANITATION")

    import!

    assert_equal 1, account_count(%w[DUP1 DUP2 DUP3]),
      "three Sailfin accounts in one pairing become a single representative account"
    assert_equal "DUP1", CashlineSync::CustomerAccount
                          .where(sailfin_account_id: %w[DUP1 DUP2 DUP3]).pick(:sailfin_account_id),
      "the lexically-lowest sailfin id is the stable representative"
  end

  test "do-not-use customers are imported but soft-archived" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("DNU1", "(DO NOT USE) Dead Payer LLC")
    sf_account("DNU2", "ACME CORP - DO NOT USE")
    sf_account("DNU3", "DNU FLUOR FEDERAL")
    sf_account("LIVE", "REAL CUSTOMER INC")

    import!

    %w[DNU1 DNU2 DNU3].each do |id|
      org = org_for_account(id)
      assert org, "#{id} is still imported (archived, not dropped)"
      assert_not_nil org.archived_at, "#{id}'s customer org is soft-archived"
    end
    assert_nil org_for_account("LIVE").archived_at, "a normal customer is not archived"
  end

  test "emits an account crosswalk that points collapsed members at one customer_account" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("CW1", "VIKING SANITATION") # CW1 + CW2 collapse into one pairing
    sf_account("CW2", "VIKING SANITATION")
    sf_account("CW3", "LONE CO")
    import!

    xw = SyncAccountCrosswalk.where(extraction_run_id: @run.id).pluck(:sailfin_account_id, :customer_account_id).to_h
    assert_equal %w[CW1 CW2 CW3].to_set, xw.keys.to_set, "every active account is crosswalked"
    assert_equal xw["CW1"], xw["CW2"], "collapsed members resolve to the same customer_account"
    assert_includes %w[CW1 CW2], CashlineSync::CustomerAccount.find(xw["CW1"]).sailfin_account_id,
      "the shared id is the pairing's representative"
    assert_not_equal xw["CW1"], xw["CW3"], "a different customer is a different account"
  end

  test "a failure during rebuild rolls back the purge so the prior import survives" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("ACC1", "ACME CORP")
    sf_account("ACC9", "OTHER CO")
    import!
    assert_equal 2, account_count(%w[ACC1 ACC9]), "baseline import landed"

    assert_raises(RuntimeError) do
      FailingImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
    end

    assert_equal 2, account_count(%w[ACC1 ACC9]),
      "purge rolled back with the failed rebuild — the prior import is intact"
  end

  private

  def import!
    Sync::AccountImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
  end

  def org_for_account(sf_id)
    acct = CashlineSync::CustomerAccount.find_by(sailfin_account_id: sf_id)
    acct && CashlineSync::CustomerOrganization.find(acct.customer_organization_id)
  end

  # By default the account also gets one AR transaction so it survives the
  # importer's activity filter. Pass active: false to simulate a dormant account
  # (no open item ever) that the importer should exclude.
  def sf_account(sf_id, name, active: true)
    rec = SfRecord.create!(
      extraction_run: @run,
      object_api_name: "Account",
      sf_id: sf_id,
      exported_at: Time.current,
      payload: {
        "Id" => sf_id, "Name" => name,
        "Brand__c" => "BRD1", "Brand_Name__c" => "Acme Brand"
      }
    )
    sf_transaction(sf_id) if active
    rec
  end

  def sf_transaction(account_sf_id, sf_id: "TX-#{account_sf_id}")
    SfRecord.create!(
      extraction_run: @run,
      object_api_name: "sfsrm__Transaction__c",
      sf_id: sf_id,
      exported_at: Time.current,
      payload: { "Id" => sf_id, "sfsrm__Account__c" => account_sf_id }
    )
  end

  def build_grouping(parent, member_records, state:)
    g = CustomerGrouping.create!(
      extraction_run: @run, parent_name: parent,
      detection_method: "test", confidence: "high", state: state
    )
    member_records.each do |r|
      g.members.create!(
        sailfin_account_id: r.payload["Id"],
        account_name: r.payload["Name"],
        source_parent_name: parent
      )
    end
    g
  end

  def operator_id = @scaffolding.operator_id

  def customer_orgs = CashlineSync::CustomerOrganization.where(operator_id: operator_id)

  def acme_org_ids
    CashlineSync::CustomerAccount.where(sailfin_account_id: %w[ACC1 ACC2 ACC3])
                                .distinct.pluck(:customer_organization_id)
  end

  def account_count(ids) = CashlineSync::CustomerAccount.where(sailfin_account_id: ids).count

  def orphan_org_count
    customer_orgs.where.not(id: CashlineSync::CustomerAccount.select(:customer_organization_id)).count
  end

  def orphan_group_count
    CashlineSync::CustomerGroup
      .where(customer_organization_id: customer_orgs.select(:id))
      .where.not(id: CashlineSync::CustomerAccount.select(:customer_group_id)).count
  end

  def sync_available?
    CashlineSync::Operator.connection.select_value("SELECT 1 FROM operators LIMIT 1")
    true
  rescue StandardError
    false
  end

  # Drop just this test's operator subtree (child-first) so the shared sync DB
  # stays clean whether or not transactional fixtures cover that connection.
  def purge_sync_operator
    op = CashlineSync::Operator.find_by(slug: @op_slug)
    return unless op

    cust_orgs = CashlineSync::CustomerOrganization.where(operator_id: op.id)
    client_orgs = CashlineSync::ClientOrganization.where(operator_id: op.id)
    CashlineSync::CustomerAccount.where(customer_organization_id: cust_orgs.select(:id)).delete_all
    CashlineSync::CustomerGroup.where(customer_organization_id: cust_orgs.select(:id)).delete_all
    cust_orgs.delete_all
    CashlineSync::ClientGroup.where(client_organization_id: client_orgs.select(:id)).delete_all
    client_orgs.delete_all
    op.destroy
  end
end
