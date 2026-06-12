require "test_helper"

# See Sync::AccountImporterTest for the sync-DB test setup rationale (self-skip
# when unreachable, throwaway operator, explicit teardown). Tasks fork to
# operational_tasks vs communication_events and depend on the account crosswalk,
# so each test runs the Account importer first.
class Sync::TaskImporterTest < ActiveSupport::TestCase
  setup do
    @op_slug = "test-op-#{SecureRandom.hex(8)}"
    @scaffolding = Sync::ScaffoldingBuilder.new(operator_name: @op_slug, operator_slug: @op_slug)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sync_available = sync_available?
  end

  teardown { purge_sync_operator if @sync_available }

  test "forks email/call tasks to communication_events and work items to operational_tasks" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!

    # A work item (TaskSubtype=Task, no call/email signal) -> operational_tasks.
    sf_task("T-WORK", account_id: "A1", subject: "Follow up on past due",
            subtype: "Task", type: "Other", status: "Not Started", priority: "High",
            contact_method: "Promise To Pay", activity_date: "2025-05-01")
    # An email log -> communication_events.
    sf_task("T-EMAIL", account_id: "A1", subject: "Sent statement",
            subtype: "Email", type: "Email", status: "Completed",
            completed: "2025-05-02T10:00:00Z")
    # A call log -> communication_events.
    sf_task("T-CALL", account_id: "A1", subject: "Called AP",
            subtype: "Task", type: "Call", status: "Completed",
            completed: "2025-05-03T10:00:00Z")
    sf_task("T-GHOST", account_id: "NOPE", subject: "orphan") # account not imported

    stats = Sync::TaskImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    assert_equal 1, stats[:operational_tasks]
    assert_equal 2, stats[:communication_events]
    assert_equal 1, stats[:skipped_unresolved]

    work = CashlineSync::OperationalTask.find_by(sailfin_task_id: "T-WORK")
    assert work, "work item landed in operational_tasks"
    assert_equal 0, work.status, "Not Started -> open(0)"
    assert_equal 2, work.priority, "High -> high(2)"
    assert_equal 7, work.category, "Promise To Pay -> payment_follow_up(7)"
    assert_equal 0, work.visibility
    assert work.client_organization_id, "client_organization_id derived (NOT NULL)"
    assert work.created_by_user_id, "creator backfilled to the system user when unmapped"
    assert_nil work.resolved_at, "open task has no resolved_at"

    email = CashlineSync::CommunicationEvent.find_by(sailfin_task_id: "T-EMAIL")
    call = CashlineSync::CommunicationEvent.find_by(sailfin_task_id: "T-CALL")
    assert_equal 0, email.channel, "email channel(0)"
    assert_equal 1, call.channel, "phone channel(1)"
    assert_equal 1, email.direction, "outbound(1)"
    assert email.occurred_at, "occurred_at set from CompletedDateTime"
    assert_nil CashlineSync::OperationalTask.find_by(sailfin_task_id: "T-EMAIL"),
      "an email task is NOT also written as an operational task (either/or fork)"
  end

  test "an OPEN email/call task is work to track — routes to operational_tasks, not comm events" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!

    # A call that hasn't happened yet: open work, not a logged contact.
    sf_task("T-OPENCALL", account_id: "A1", subject: "Call customer tomorrow",
            subtype: "Task", type: "Call", status: "Not Started")

    stats = Sync::TaskImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    assert_equal 1, stats[:operational_tasks]
    assert_equal 0, stats[:communication_events]
    t = CashlineSync::OperationalTask.find_by(sailfin_task_id: "T-OPENCALL")
    assert t, "the open call is tracked as an operational task"
    assert_equal 0, t.status, "Not Started -> open(0)"
    assert_nil CashlineSync::CommunicationEvent.find_by(sailfin_task_id: "T-OPENCALL"),
      "an unhappened call is NOT logged as a communication event"
  end

  test "resolves owner/creator through the platform users table" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_user("0051", email: "owner#{@run.id}@example.com", first: "Olive", last: "Owner")
    Sync::UserImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
    owner = CashlineSync::User.find_by(sailfin_user_id: "0051")

    sf_task("T1", account_id: "A1", subject: "Assigned task", subtype: "Task", type: "Other",
            owner_id: "0051", created_by: "0051", status: "Completed", completed: "2025-05-01T09:00:00Z")
    Sync::TaskImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call

    t = CashlineSync::OperationalTask.find_by(sailfin_task_id: "T1")
    assert_equal owner.id, t.assigned_to_user_id, "OwnerId mapped via sailfin_user_id"
    assert_equal owner.id, t.created_by_user_id, "CreatedById mapped via sailfin_user_id"
    assert_equal 3, t.status, "Completed -> resolved(3)"
    assert t.resolved_at, "resolved task carries resolved_at"
  end

  test "re-running is a clean full refresh — no duplicates" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_account("A1", "VIKING SANITATION")
    import_accounts!
    sf_task("T1", account_id: "A1", subject: "Work", subtype: "Task", type: "Other")
    sf_task("T2", account_id: "A1", subject: "Email", subtype: "Email", type: "Email")

    2.times { Sync::TaskImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call }

    assert_equal 1, CashlineSync::OperationalTask.where(sailfin_task_id: "T1").count
    assert_equal 1, CashlineSync::CommunicationEvent.where(sailfin_task_id: "T2").count
  end

  private

  def import_accounts!
    Sync::AccountImporter.new(extraction_run_id: @run.id, scaffolding: @scaffolding).call
  end

  def sf_account(sf_id, name)
    SfRecord.create!(extraction_run: @run, object_api_name: "Account", sf_id: sf_id, exported_at: Time.current,
      payload: { "Id" => sf_id, "Name" => name, "Brand__c" => "BRD1", "Brand_Name__c" => "Acme Brand" })
    SfRecord.create!(extraction_run: @run, object_api_name: "sfsrm__Transaction__c", sf_id: "TX-#{sf_id}",
      exported_at: Time.current, payload: { "Id" => "TX-#{sf_id}", "sfsrm__Account__c" => sf_id })
  end

  def sf_task(sf_id, account_id:, subject: nil, subtype: "Task", type: nil, status: "Completed",
              priority: "Normal", contact_method: nil, owner_id: "005SYS", created_by: "005SYS",
              activity_date: nil, completed: nil)
    SfRecord.create!(extraction_run: @run, object_api_name: "Task", sf_id: sf_id, exported_at: Time.current,
      payload: { "Id" => sf_id, "AccountId" => account_id, "Subject" => subject, "TaskSubtype" => subtype,
                 "Type" => type, "Status" => status, "Priority" => priority,
                 "sfsrm__Contact_Method__c" => contact_method, "OwnerId" => owner_id,
                 "CreatedById" => created_by, "ActivityDate" => activity_date, "CompletedDateTime" => completed })
  end

  def sf_user(sf_id, email:, first:, last:)
    SfRecord.create!(extraction_run: @run, object_api_name: "User", sf_id: sf_id, exported_at: Time.current,
      payload: { "Id" => sf_id, "Email" => email, "FirstName" => first, "LastName" => last,
                 "Name" => "#{first} #{last}", "IsActive" => true, "UserType" => "Standard" })
  end

  def sync_available?
    CashlineSync::Operator.connection.select_value("SELECT 1 FROM operational_tasks LIMIT 1")
    true
  rescue StandardError
    false
  end

  def purge_sync_operator
    op = CashlineSync::Operator.find_by(slug: @op_slug)
    return unless op
    cust_orgs = CashlineSync::CustomerOrganization.where(operator_id: op.id)
    client_orgs = CashlineSync::ClientOrganization.where(operator_id: op.id)
    client_groups = CashlineSync::ClientGroup.where(client_organization_id: client_orgs.select(:id))
    acct_scope = CashlineSync::CustomerAccount.where(customer_organization_id: cust_orgs.select(:id))
    CashlineSync::CommunicationEvent.where(client_group_id: client_groups.select(:id)).delete_all
    CashlineSync::OperationalTask.where(operator_id: op.id).delete_all
    CashlineSync::CustomerContact.where(customer_account_id: acct_scope).delete_all
    acct_scope.delete_all
    CashlineSync::CustomerGroup.where(customer_organization_id: cust_orgs.select(:id)).delete_all
    cust_orgs.delete_all
    client_groups.delete_all
    client_orgs.delete_all
    CashlineSync::User.where("email LIKE ?", "%#{@run.id}@example.com").delete_all
    op.destroy
  end
end
