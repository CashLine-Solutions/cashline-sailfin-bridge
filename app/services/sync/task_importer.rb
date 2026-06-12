module Sync
  # Imports Sailfin `Task` rows (collections activities) into the platform, forking
  # each to one of two destinations. The platform models these as distinct things:
  # a `communication_event` is an immutable log that a contact HAPPENED (no status/
  # lifecycle), while an `operational_task` is a work item WITH a lifecycle
  # (status/priority/resolved_at). So the fork keys on BOTH channel and completion:
  #
  #   - `communication_events` — a logged communication that has already happened:
  #     an email (TaskSubtype Email/ListEmail, or Type Email) or call (Type
  #     Call/Phone) that is Completed/closed. Records "we contacted the customer",
  #     channel email/phone. No completion lifecycle (it's a point-in-time record).
  #   - `operational_tasks` — everything else, INCLUDING a still-open email/call:
  #     an open "call the customer" is work to track, not a contact that happened,
  #     so it routes here as an open task, not a lifecycle-less comm event.
  #
  # The fork is either/or (a Task lands in exactly one table) to avoid double
  # counting; both platform tables carry a UNIQUE `sailfin_task_id` and we upsert
  # on it. We don't synthesize linked task<->event pairs for historical data — each
  # Sailfin Task is one record and maps to one row by its nature. ~99% of Tasks are
  # Completed, so this is mostly comm events plus a long tail of resolved tasks.
  #
  # Routing: a Task's `AccountId` resolves through the account crosswalk
  # (SyncAccountCrosswalk) that Sync::AccountImporter emits — a Task often hangs on
  # a member account that was collapsed into another's pairing, so we route through
  # the crosswalk, not customer_accounts.sailfin_account_id alone. Owner/creator
  # resolve through the platform users table (Sync::UserImporter), keyed on
  # sailfin_user_id; an unmapped creator falls back to the scaffolding system user
  # (created_by is NOT NULL), and an unmapped assignee is simply left null.
  #
  # Skipped (not synced): Tasks with no AccountId, or whose account wasn't imported
  # (dormant — filtered by the Account importer's activity gate). Run the Account
  # AND User importers FIRST (import_all enforces the order).
  #
  # IMPORTANT: upsert_all bypasses the platform's OperationalTask/CommunicationEvent
  # `before_validation` context-resolution + `*_matches_context` validators, so this
  # importer sets every context column itself (operator/client_org/client_group/
  # customer_account/customer_org, resolved_at, occurred_at, the enum integers).
  #
  # Full refresh, per operator, in one transaction. operational_tasks is purged by
  # operator_id; communication_events has no operator_id, so we purge only this
  # operator's Task-origin rows (client_group in scope AND sailfin_task_id present),
  # never EmailMessage/Event-origin comms a future importer will own.
  class TaskImporter
    OBJECT = "Task".freeze
    UPSERT_BATCH = 2_000

    # Sailfin Task.Status -> OperationalTask.status enum int
    STATUS = { "Completed" => 3, "Not Started" => 0, "In Progress" => 1, "Waiting on someone else" => 2 }.freeze
    STATUS_OPEN = 0
    STATUS_RESOLVED = 3
    # Sailfin Task.Priority -> OperationalTask.priority enum int
    PRIORITY = { "Low" => 0, "Normal" => 1, "High" => 2, "Urgent" => 3 }.freeze
    PRIORITY_NORMAL = 1
    # Sailfin sfsrm__Contact_Method__c -> OperationalTask.category enum int
    CATEGORY = { "Contact Customer" => 0, "Promise To Pay" => 7, "Dispute" => 9, "Send Statement" => 10 }.freeze
    CATEGORY_GENERAL = 0
    VISIBILITY_INTERNAL = 0

    # CommunicationEvent enums
    CE_CHANNEL_EMAIL = 0
    CE_CHANNEL_PHONE = 1
    CE_DIRECTION_OUTBOUND = 1   # collections outreach: the collector contacts the customer
    CE_VISIBILITY_INTERNAL = 0

    EMAIL_SUBTYPES = %w[Email ListEmail].freeze
    CALL_TYPES = %w[Call Phone].freeze
    NO_SUBJECT = "(no subject)".freeze

    def initialize(extraction_run_id:, limit: nil, scaffolding: ScaffoldingBuilder.new)
      @run_id = extraction_run_id
      @limit = limit
      @scaffolding = scaffolding
      @stats = Hash.new(0)
    end

    def call
      CashlineSync::OperationalTask.transaction do
        operator_id = @scaffolding.operator_id
        purge(operator_id)
        fallback_user = @scaffolding.system_user_id

        op_batch = []
        ce_batch = []
        scope.find_each do |rec|
          p = rec.payload
          target = crosswalk[p["AccountId"]]
          if target.nil? || client_org_for(target).nil?
            @stats[:skipped_unresolved] += 1
            next
          end

          channel = communication_channel(p)
          if channel && completed?(p)
            ce_batch << communication_row(p, target, channel, fallback_user)
            flush_ces(ce_batch) and ce_batch = [] if ce_batch.size >= UPSERT_BATCH
          else
            op_batch << operational_task_row(p, target, operator_id, fallback_user)
            flush_ops(op_batch) and op_batch = [] if op_batch.size >= UPSERT_BATCH
          end
        end
        flush_ops(op_batch)
        flush_ces(ce_batch)
      end
      @stats
    end

    private

    def scope
      s = SfRecord.where(extraction_run_id: @run_id, object_api_name: OBJECT)
      @limit ? s.limit(@limit) : s
    end

    # CE_CHANNEL_* when the Task is a logged communication; nil => operational task.
    def communication_channel(p)
      return CE_CHANNEL_EMAIL if EMAIL_SUBTYPES.include?(p["TaskSubtype"]) || p["Type"] == "Email"
      return CE_CHANNEL_PHONE if CALL_TYPES.include?(p["Type"])
      nil
    end

    # A communication only belongs in communication_events once it has actually
    # happened. An OPEN email/call is still work to track, so it routes to
    # operational_tasks instead (the platform's task-vs-event split).
    def completed?(p)
      p["Status"] == "Completed" || truthy(p["IsClosed"])
    end

    def truthy(value)
      value == true || value.to_s.casecmp("true").zero?
    end

    def operational_task_row(p, target, operator_id, fallback_user)
      now = Time.current
      status = STATUS.fetch(p["Status"], STATUS_OPEN)
      {
        operator_id: operator_id,
        client_organization_id: client_org_for(target),
        client_group_id: target[:client_group],
        customer_account_id: target[:account],
        customer_organization_id: target[:org],
        assigned_to_user_id: user_id_for(p["OwnerId"]),
        created_by_user_id: user_id_for(p["CreatedById"]) || fallback_user,
        title: subject(p),
        description: body(p),
        status: status,
        priority: PRIORITY.fetch(p["Priority"], PRIORITY_NORMAL),
        category: CATEGORY.fetch(p["sfsrm__Contact_Method__c"], CATEGORY_GENERAL),
        visibility: VISIBILITY_INTERNAL,
        due_at: datetime(p["ActivityDate"]),
        resolved_at: (status == STATUS_RESOLVED ? completed_at(p) || now : nil),
        sailfin_task_id: p["Id"],
        sailfin_account_id: p["AccountId"],
        sailfin_owner_user_id: p["OwnerId"].presence,
        created_at: now,
        updated_at: now
      }
    end

    def communication_row(p, target, channel, fallback_user)
      now = Time.current
      {
        client_group_id: target[:client_group],
        customer_account_id: target[:account],
        created_by_user_id: user_id_for(p["CreatedById"]) || fallback_user,
        channel: channel,
        direction: CE_DIRECTION_OUTBOUND,
        visibility: CE_VISIBILITY_INTERNAL,
        summary: subject(p),
        body: body(p),
        occurred_at: completed_at(p) || datetime(p["ActivityDate"]) || time(p["CreatedDate"]) || now,
        sailfin_task_id: p["Id"],
        sailfin_account_id: p["AccountId"],
        created_at: now,
        updated_at: now
      }
    end

    # sailfin_account_id => {account:, group:, org:, client_group:} (same crosswalk
    # the contact/invoice importers route through).
    def crosswalk
      @crosswalk ||= SyncAccountCrosswalk
        .where(extraction_run_id: @run_id)
        .pluck(:sailfin_account_id, :customer_account_id, :customer_group_id,
               :customer_organization_id, :client_group_id)
        .each_with_object({}) do |(sid, account, group, org, client_group), h|
          h[sid] = { account: account, group: group, org: org, client_group: client_group }
        end
    end

    # operational_tasks.client_organization_id is NOT NULL; the crosswalk carries
    # client_group_id, so derive the org from the group.
    def client_org_for(target)
      client_org_by_group[target[:client_group]]
    end

    def client_org_by_group
      @client_org_by_group ||= CashlineSync::ClientGroup.pluck(:id, :client_organization_id).to_h
    end

    # sailfin_user_id => platform users.id (from Sync::UserImporter).
    def user_id_for(sailfin_user_id)
      return nil if sailfin_user_id.blank?
      user_map[sailfin_user_id]
    end

    def user_map
      @user_map ||= CashlineSync::User.where.not(sailfin_user_id: nil).pluck(:sailfin_user_id, :id).to_h
    end

    def purge(operator_id)
      @stats[:purged_operational_tasks] =
        CashlineSync::OperationalTask.where(operator_id: operator_id).delete_all

      client_org_ids = CashlineSync::ClientOrganization.where(operator_id: operator_id).select(:id)
      client_group_ids = CashlineSync::ClientGroup.where(client_organization_id: client_org_ids).select(:id)
      @stats[:purged_communication_events] = CashlineSync::CommunicationEvent
        .where(client_group_id: client_group_ids).where.not(sailfin_task_id: nil).delete_all
    end

    def flush_ops(rows)
      return false if rows.empty?
      CashlineSync::OperationalTask.upsert_all(rows, unique_by: :sailfin_task_id)
      @stats[:operational_tasks] += rows.size
      true
    end

    def flush_ces(rows)
      return false if rows.empty?
      CashlineSync::CommunicationEvent.upsert_all(rows, unique_by: :sailfin_task_id)
      @stats[:communication_events] += rows.size
      true
    end

    def subject(p)
      p["Subject"].presence || NO_SUBJECT
    end

    # Description (~28%) + collections Notes (~18%) — both useful, joined.
    def body(p)
      [ p["Description"], p["sfsrm__Notes__c"] ].filter_map { |v| v.to_s.strip.presence }.join("\n\n").presence
    end

    def completed_at(p)
      time(p["CompletedDateTime"]) || time(p["sfsrm__Closed_Date__c"])
    end

    def datetime(str)
      Time.zone.parse(str.to_s) if str.present?
    rescue ArgumentError
      nil
    end
    alias_method :time, :datetime
  end
end
