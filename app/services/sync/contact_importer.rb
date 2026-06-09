module Sync
  # Imports Sailfin `Contact` rows into the sync DB's customer_contacts, routing
  # each to the correct rolled-up / merged customer via the account crosswalk that
  # Sync::AccountImporter emits (SyncAccountCrosswalk). A contact's AccountId is
  # often a member account that was collapsed into another's pairing, so we resolve
  # through the crosswalk rather than customer_accounts.sailfin_account_id alone.
  #
  # Skipped (not synced): contacts with no AccountId, and contacts whose account
  # wasn't imported (dormant — filtered by the Account importer's activity gate).
  # They have no customer_account to hang on. Run the Account importer FIRST so the
  # crosswalk is fresh.
  #
  # Only customer contacts: client_contacts carries no Sailfin crosswalk columns
  # (it's brand-side users), so the Sailfin Contact object has no client target.
  #
  # Full refresh, per operator, in one transaction — same shape as the Account
  # importer; upsert on sailfin_contact_id keeps re-runs idempotent.
  class ContactImporter
    OBJECT = "Contact".freeze
    UPSERT_BATCH = 2_000

    def initialize(extraction_run_id:, limit: nil, scaffolding: ScaffoldingBuilder.new)
      @run_id = extraction_run_id
      @limit = limit
      @scaffolding = scaffolding
      @stats = Hash.new(0)
    end

    def call
      CashlineSync::CustomerContact.transaction do
        operator_id = @scaffolding.operator_id
        purge_customer_contacts(operator_id)

        rows = []
        scope.find_each do |rec|
          p = rec.payload
          target = crosswalk[p["AccountId"]]
          unless target
            @stats[:skipped_unresolved] += 1
            next
          end
          rows << contact_row(p, target)
          @stats[:contacts_seen] += 1
        end
        upsert_contacts(rows)
      end
      @stats
    end

    private

    def scope
      s = SfRecord.where(extraction_run_id: @run_id, object_api_name: OBJECT)
      @limit ? s.limit(@limit) : s
    end

    # sailfin_account_id => {account:, group:, org:} from the Account importer's run.
    def crosswalk
      @crosswalk ||= SyncAccountCrosswalk
        .where(extraction_run_id: @run_id)
        .pluck(:sailfin_account_id, :customer_account_id, :customer_group_id, :customer_organization_id)
        .each_with_object({}) do |(sid, account, group, org), h|
          h[sid] = { account: account, group: group, org: org }
        end
    end

    # Operator-scoped purge via the operator's customer_accounts (the one NOT NULL
    # parent every customer_contact hangs on).
    def purge_customer_contacts(operator_id)
      org_scope = CashlineSync::CustomerOrganization.where(operator_id: operator_id)
      acct_scope = CashlineSync::CustomerAccount.where(customer_organization_id: org_scope)
      @stats[:purged_contacts] = CashlineSync::CustomerContact.where(customer_account_id: acct_scope).delete_all
    end

    def contact_row(payload, target)
      now = Time.current
      {
        customer_account_id: target[:account],
        customer_group_id: target[:group],
        customer_organization_id: target[:org],
        first_name: payload["FirstName"].presence,
        last_name: payload["LastName"].presence,
        email: payload["Email"].presence,
        phone: payload["Phone"].presence || payload["MobilePhone"].presence,
        title: payload["Title"].presence,
        role_label: payload["TitleType"].presence,
        notes: payload["Description"].presence,
        sailfin_account_id: payload["AccountId"],
        sailfin_contact_id: payload["Id"],
        created_at: now,
        updated_at: now
      }
    end

    def upsert_contacts(rows)
      return if rows.empty?
      rows.each_slice(UPSERT_BATCH) do |slice|
        CashlineSync::CustomerContact.upsert_all(slice, unique_by: :sailfin_contact_id)
      end
      @stats[:customer_contacts] = rows.size
    end
  end
end
