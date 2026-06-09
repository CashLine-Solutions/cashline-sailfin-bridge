module Sync
  # Imports Sailfin `sfsrm__Transaction__c` rows into the sync DB's invoices,
  # routing each to the correct rolled-up/merged customer via the account
  # crosswalk (SyncAccountCrosswalk) that the Account importer emits. Run the
  # Account importer FIRST (import_all enforces the order).
  #
  # Grain: ONE invoice per (client_group, invoice_number). Sailfin holds multiple
  # transaction rows per invoice (re-sync duplicates — same amount/number), and
  # the platform enforces invoice_number unique per client_group, so we dedupe to
  # one representative per number rather than summing (which would multi-count).
  #
  # Mapping is intentionally partial + iterative: fields with a typed column are
  # mapped directly; the rest of the useful AR data is staged in invoices.metadata
  # (jsonb) so we can see it in the platform and promote winners to real columns
  # without a platform migration per field. Drain metadata as columns land.
  #
  # Skipped: transactions with a blank Invoice__c, or whose account isn't in the
  # crosswalk (dormant/never-invoiced account — not synced).
  #
  # Full refresh, per operator, in one transaction; upsert on
  # (client_group_id, invoice_number) keeps re-runs idempotent.
  class InvoiceImporter
    OBJECT = "sfsrm__Transaction__c".freeze
    ACCOUNT_FIELD = "sfsrm__Account__c".freeze
    UPSERT_BATCH = 2_000
    # The platform's *_cents columns are bigint; this guard just isolates a single
    # absurd/corrupt amount instead of aborting the whole 2M-row run.
    INT8_RANGE = (-9_223_372_036_854_775_808..9_223_372_036_854_775_807)
    CENTS_COLUMNS = %i[original_amount_cents total_cents tax_cents subtotal_cents balance_due_cents].freeze

    def initialize(extraction_run_id:, limit: nil, scaffolding: ScaffoldingBuilder.new)
      @run_id = extraction_run_id
      @limit = limit
      @scaffolding = scaffolding
      @stats = Hash.new(0)
    end

    def call
      CashlineSync::Invoice.transaction do
        purge_invoices(@scaffolding.operator_id)
        user_id = @scaffolding.system_user_id

        seen = Set.new   # "client_group::invoice_number" already emitted (dedupe)
        batch = []
        scope.find_each do |rec|
          p = rec.payload
          target = crosswalk[p[ACCOUNT_FIELD]]
          number = p["Invoice__c"].presence
          if target.nil? || number.nil?
            @stats[:skipped_unresolved] += 1
            next
          end
          key = "#{target[:client_group]}::#{number}"
          if seen.include?(key)
            @stats[:duplicate_transactions] += 1
            next
          end

          row = invoice_row(p, target, number, user_id)
          # Defensive: skip + count a single absurd/corrupt amount rather than let
          # it abort the whole run. Real data fits the platform's bigint cents.
          if amount_overflow?(row)
            @stats[:skipped_amount_overflow] += 1
            next
          end

          seen << key
          batch << row
          if batch.size >= UPSERT_BATCH
            upsert(batch)
            batch = []
          end
        end
        upsert(batch) unless batch.empty?
      end
      @stats
    end

    private

    def scope
      s = SfRecord.where(extraction_run_id: @run_id, object_api_name: OBJECT)
                  .where("coalesce(payload->>'Invoice__c','') <> ''")
      @limit ? s.limit(@limit) : s
    end

    # sailfin_account_id => {account:, group:, org:, client_group:}.
    def crosswalk
      @crosswalk ||= SyncAccountCrosswalk
        .where(extraction_run_id: @run_id)
        .pluck(:sailfin_account_id, :customer_account_id, :customer_group_id,
               :customer_organization_id, :client_group_id)
        .each_with_object({}) do |(sid, account, group, org, client_group), h|
          h[sid] = { account: account, group: group, org: org, client_group: client_group }
        end
    end

    def purge_invoices(operator_id)
      org_scope = CashlineSync::CustomerOrganization.where(operator_id: operator_id)
      acct_scope = CashlineSync::CustomerAccount.where(customer_organization_id: org_scope)
      @stats[:purged_invoices] = CashlineSync::Invoice.where(customer_account_id: acct_scope).delete_all
    end

    def invoice_row(p, target, number, user_id)
      now = Time.current
      original = cents(p["Original_Amount__c"])
      tax = cents(p["Tax_Amount__c"])
      balance = cents(p["sfsrm__Balance__c"])
      {
        client_group_id: target[:client_group],
        customer_account_id: target[:account],
        customer_group_id: target[:group],
        created_by_user_id: user_id,
        invoice_number: number,
        currency: p["CurrencyIsoCode"].presence || "USD",
        original_amount_cents: original,
        total_cents: cents(p["sfsrm__Amount__c"]).nonzero? || original,
        tax_cents: tax,
        subtotal_cents: original - tax,
        balance_due_cents: balance,
        issue_date: date(p["Invoice_Created_Date__c"]),
        due_date: date(p["sfsrm__Due_Date__c"]),
        paid_at: (balance.zero? ? time(p["sfsrm__Close_Date__c"]) : nil),
        payment_terms_description: p["Axis_Payment_Terms__c"].presence,
        job_number: p["Job_Number_Job_Name__c"].presence,
        description: p["Type_Description__c"].presence,
        source_system: p["sfsrm__Source_System__c"].presence || "sailfin",
        source_document_type: p["Type__c"].presence,
        source_transaction_id: p["Id"],
        source_external_id: p["Id"],
        sailfin_transaction_id: p["Id"],
        sailfin_account_id: p[ACCOUNT_FIELD],
        last_synced_at: now,
        metadata: staged_metadata(p),
        created_at: now, updated_at: now
      }
    end

    # AR fields with no typed column yet — staged for iteration, not durability
    # (the source is always re-importable). Promote winners to real columns.
    def staged_metadata(p)
      {
        days_past_due: p["sfsrm__Days_Past_Due__c"].presence,
        aging_group: p["sfsrm__Aging_Group__c"].presence,
        amount_due_over_90: p["Amount_Due_Over_90__c"].presence,
        disputed_flag: p["sfsrm__DisputedFlag__c"].presence,
        disputed_amount: p["sfsrm__Disputed_Amount__c"].presence,
        expected_payment_date: p["Expected_Payment_Date__c"].presence,
        close_date: p["sfsrm__Close_Date__c"].presence,
        biller_email: p["Viking_Biller_Email__c"].presence,
        dispatch_email: p["Viking_Dispatch_Email__c"].presence,
        branch_manager_email: p["Viking_Branch_Manager_Email__c"].presence,
        brand_code: p["Brand_Code_Invoice__c"].presence,
        # uncertain mappings — promote to typed columns once confirmed:
        region_key: p["Viking_Region_Key__c"].presence,
        fluid_mgmt_division: p["Fluid_Management_Construction_Division__c"].presence
      }.compact
    end

    def amount_overflow?(row)
      CENTS_COLUMNS.any? { |c| !INT8_RANGE.cover?(row[c].to_i) }
    end

    def upsert(rows)
      return if rows.empty?
      CashlineSync::Invoice.upsert_all(rows, unique_by: %i[client_group_id invoice_number])
      @stats[:invoices] += rows.size
    end

    # "118.91" -> 11891 cents; blanks/garbage -> 0.
    def cents(str)
      return 0 if str.to_s.strip.empty?
      (BigDecimal(str.to_s) * 100).round
    rescue ArgumentError
      0
    end

    def date(str)
      Date.parse(str.to_s) if str.present?
    rescue ArgumentError
      nil
    end

    def time(str)
      Time.zone.parse(str.to_s) if str.present?
    rescue ArgumentError
      nil
    end
  end
end
