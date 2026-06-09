require "test_helper"

# See Sync::AccountImporterTest for the sync-DB test setup rationale. Invoices
# depend on the account crosswalk, so each test runs the Account importer first.
class Sync::InvoiceImporterTest < ActiveSupport::TestCase
  setup do
    @op_slug = "test-op-#{SecureRandom.hex(8)}"
    @scaffolding = Sync::ScaffoldingBuilder.new(operator_name: @op_slug, operator_slug: @op_slug)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sync_available = sync_available?
  end

  teardown { purge_sync_operator if @sync_available }

  test "imports invoices routed to the right customer account with mapped fields" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_invoice("INV-1", account: "A1", number: "1001", amount: "118.91", balance: "0.0",
               issue: "2025-04-26", due: "2025-05-26", close: "2026-04-01")

    stats = Sync::InvoiceImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    assert_equal 1, stats[:invoices]
    inv = CashlineSync::Invoice.find_by(sailfin_transaction_id: "INV-1")
    assert inv, "invoice imported"
    assert_equal "1001", inv.invoice_number
    assert_equal 11891, inv.original_amount_cents, "dollars -> cents"
    assert_equal 0, inv.balance_due_cents
    assert_equal Date.new(2025, 4, 26), inv.issue_date
    assert_not_nil inv.paid_at, "balance 0 -> paid_at from close date"

    acct = CashlineSync::CustomerAccount.find_by(sailfin_account_id: "A1")
    assert_equal acct.id, inv.customer_account_id, "routed to the right customer account"
    assert_equal acct.client_group_id, inv.client_group_id, "client_group from the crosswalk"
    assert_not_nil inv.created_by_user_id, "attributed to the system user"
  end

  test "dedupes multiple transactions for one invoice number into a single invoice" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_invoice("INV-2a", account: "A1", number: "2002", amount: "50.00")
    sf_invoice("INV-2b", account: "A1", number: "2002", amount: "50.00") # re-sync duplicate

    stats = Sync::InvoiceImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    assert_equal 1, stats[:invoices], "one invoice per (client_group, invoice_number)"
    assert_equal 1, stats[:duplicate_transactions]
    assert_equal 1, CashlineSync::Invoice.where(invoice_number: "2002").count
  end

  test "skips blank invoice number and unresolvable account" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_invoice("INV-blank", account: "A1", number: "")        # no invoice number — excluded by scope
    sf_invoice("INV-ghost", account: "GHOST", number: "3003") # account not in crosswalk — skipped in loop

    stats = Sync::InvoiceImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    assert_equal 0, stats[:invoices], "neither becomes an invoice"
    assert_equal 1, stats[:skipped_unresolved], "ghost-account skipped in the loop (blank number is filtered by scope)"
    assert_nil CashlineSync::Invoice.find_by(sailfin_transaction_id: "INV-ghost")
  end

  test "large invoices fit (bigint cents); only an absurd/corrupt amount is skipped" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_invoice("INV-big", account: "A1", number: "8888", amount: "54086593.68")        # $54M — fits bigint
    sf_invoice("INV-absurd", account: "A1", number: "9999", amount: "999999999999999999999") # overflows bigint

    stats = Sync::InvoiceImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    assert_equal 1, stats[:invoices], "the $54M invoice imports now"
    assert_equal 1, stats[:skipped_amount_overflow], "only the absurd value is skipped"
    assert_equal 5_408_659_368, CashlineSync::Invoice.find_by(invoice_number: "8888").original_amount_cents
    assert_nil CashlineSync::Invoice.find_by(invoice_number: "9999")
  end

  test "re-running is idempotent" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_invoice("INV-4", account: "A1", number: "4004", amount: "10.00")

    2.times { Sync::InvoiceImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call }

    assert_equal 1, CashlineSync::Invoice.where(invoice_number: "4004").count
  end

  private

  def import_accounts!
    Sync::AccountImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
  end

  def sf_account(sf_id, name)
    rec = SfRecord.create!(extraction_run: @run, object_api_name: "Account", sf_id: sf_id, exported_at: Time.current,
      payload: { "Id" => sf_id, "Name" => name, "Brand__c" => "BRD1", "Brand_Name__c" => "Acme Brand" })
    # activity marker (no Invoice__c, so the invoice importer ignores it)
    SfRecord.create!(extraction_run: @run, object_api_name: "sfsrm__Transaction__c", sf_id: "ACT-#{sf_id}",
      exported_at: Time.current, payload: { "Id" => "ACT-#{sf_id}", "sfsrm__Account__c" => sf_id })
    rec
  end

  def sf_invoice(sf_id, account:, number:, amount: "100.00", tax: "0.00", balance: "0.0",
                 issue: "2025-01-01", due: "2025-02-01", close: "2025-02-15")
    SfRecord.create!(extraction_run: @run, object_api_name: "sfsrm__Transaction__c", sf_id: sf_id,
      exported_at: Time.current, payload: {
        "Id" => sf_id, "sfsrm__Account__c" => account, "Invoice__c" => number, "Type__c" => "Invoice",
        "Original_Amount__c" => amount, "sfsrm__Amount__c" => amount, "Tax_Amount__c" => tax,
        "sfsrm__Balance__c" => balance, "Invoice_Created_Date__c" => issue, "sfsrm__Due_Date__c" => due,
        "sfsrm__Close_Date__c" => close, "sfsrm__Source_System__c" => "VikingSanitation"
      })
  end

  def sync_available?
    CashlineSync::Operator.connection.select_value("SELECT 1 FROM invoices LIMIT 1")
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
    CashlineSync::Invoice.where(customer_account_id: acct_scope).delete_all
    CashlineSync::CustomerContact.where(customer_account_id: acct_scope).delete_all
    acct_scope.delete_all
    CashlineSync::CustomerGroup.where(customer_organization_id: cust_orgs.select(:id)).delete_all
    cust_orgs.delete_all
    CashlineSync::ClientGroup.where(client_organization_id: client_orgs.select(:id)).delete_all
    client_orgs.delete_all
    op.destroy
  end
end
