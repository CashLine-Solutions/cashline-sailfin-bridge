require "test_helper"

# See Sync::AccountImporterTest for the sync-DB test setup rationale (self-skip
# when unreachable, throwaway operator, explicit teardown). Contacts depend on the
# account crosswalk, so each test runs the Account importer first.
class Sync::ContactImporterTest < ActiveSupport::TestCase
  setup do
    @op_slug = "test-op-#{SecureRandom.hex(8)}"
    @scaffolding = Sync::ScaffoldingBuilder.new(operator_name: @op_slug, operator_slug: @op_slug)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sync_available = sync_available?
  end

  teardown { purge_sync_operator if @sync_available }

  test "routes contacts to the rolled-up customer account and skips the unresolvable" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    # A1 + A2 collapse into one VIKING pairing.
    sf_account("A1", "VIKING SANITATION")
    sf_account("A2", "VIKING SANITATION")
    import_accounts!

    sf_contact("C1", account_id: "A1", first: "Ann", last: "Payer", email: "ann@x.com")
    sf_contact("C2", account_id: "A2", first: "Bob", last: "Biller")
    sf_contact("C3", account_id: "GHOST", first: "No", last: "Account") # account not imported
    sf_contact("C4", account_id: "", first: "Orphan", last: "Contact")  # no AccountId

    stats = Sync::ContactImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    assert_equal 2, stats[:customer_contacts], "only the two resolvable contacts import"
    assert_equal 2, stats[:skipped_unresolved], "ghost-account + no-account contacts are skipped"

    c1 = CashlineSync::CustomerContact.find_by(sailfin_contact_id: "C1")
    c2 = CashlineSync::CustomerContact.find_by(sailfin_contact_id: "C2")
    assert c1 && c2, "both resolvable contacts landed"
    assert_equal c1.customer_account_id, c2.customer_account_id,
      "contacts on collapsed accounts share the one VIKING customer_account"
    assert_equal "ann@x.com", c1.email
    assert_equal c1.customer_organization_id, CashlineSync::CustomerAccount.find(c1.customer_account_id).customer_organization_id,
      "denormalized org matches the account's org"
    assert_nil CashlineSync::CustomerContact.find_by(sailfin_contact_id: "C3")
    assert_nil CashlineSync::CustomerContact.find_by(sailfin_contact_id: "C4")
  end

  test "re-importing accounts purges dependent contacts (no FK violation)" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_contact("C1", account_id: "A1", first: "Ann", last: "Payer")
    Sync::ContactImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
    assert_equal 1, CashlineSync::CustomerContact.where(sailfin_contact_id: "C1").count

    # A full account refresh re-keys accounts; it must clear the FK-dependent
    # contacts instead of choking on the constraint.
    assert_nothing_raised { import_accounts! }
    assert_equal 0, CashlineSync::CustomerContact.where(sailfin_contact_id: "C1").count,
      "contacts are purged with the accounts they pointed at; re-import contacts to rebuild"
  end

  test "re-running is a clean full refresh — no duplicate contacts" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_contact("C1", account_id: "A1", first: "Ann", last: "Payer")

    2.times { Sync::ContactImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call }

    assert_equal 1, CashlineSync::CustomerContact.where(sailfin_contact_id: "C1").count
  end

  private

  def import_accounts!
    Sync::AccountImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
  end

  def sf_account(sf_id, name)
    rec = SfRecord.create!(extraction_run: @run, object_api_name: "Account", sf_id: sf_id, exported_at: Time.current,
      payload: { "Id" => sf_id, "Name" => name, "Brand__c" => "BRD1", "Brand_Name__c" => "Acme Brand" })
    SfRecord.create!(extraction_run: @run, object_api_name: "sfsrm__Transaction__c", sf_id: "TX-#{sf_id}",
      exported_at: Time.current, payload: { "Id" => "TX-#{sf_id}", "sfsrm__Account__c" => sf_id })
    rec
  end

  def sf_contact(sf_id, account_id:, first: nil, last: nil, email: nil)
    SfRecord.create!(extraction_run: @run, object_api_name: "Contact", sf_id: sf_id, exported_at: Time.current,
      payload: { "Id" => sf_id, "AccountId" => account_id, "FirstName" => first, "LastName" => last, "Email" => email })
  end

  def sync_available?
    CashlineSync::Operator.connection.select_value("SELECT 1 FROM customer_contacts LIMIT 1")
    true
  rescue StandardError
    false
  end

  def purge_sync_operator
    op = CashlineSync::Operator.find_by(slug: @op_slug)
    return unless op
    cust_orgs = CashlineSync::CustomerOrganization.where(operator_id: op.id)
    client_orgs = CashlineSync::ClientOrganization.where(operator_id: op.id)
    acct_scope = CashlineSync::CustomerAccount.where(customer_organization_id: cust_orgs.select(:id))
    CashlineSync::CustomerContact.where(customer_account_id: acct_scope).delete_all
    acct_scope.delete_all
    CashlineSync::CustomerGroup.where(customer_organization_id: cust_orgs.select(:id)).delete_all
    cust_orgs.delete_all
    CashlineSync::ClientGroup.where(client_organization_id: client_orgs.select(:id)).delete_all
    client_orgs.delete_all
    op.destroy
  end
end
