module Sync
  # Vertical slice of the Sailfin -> cashline importer: turns Sailfin `Account`
  # rows (in sf_records) into cashline rows on the sync DB.
  #
  # Fan-out per Account:
  #   - Client::Organization  (deduped by Brand, via sailfin_brand_id = Account.Brand__c)
  #       + a default Client::Group   (scaffolding)
  #   - Customer::Organization (canonical customer identity)
  #   - Customer::Group        (always set — see grouping below)
  #   - Customer::Account      (the customer x client pairing; the row you browse)
  #
  # Customer org/group resolution honors operator-CONFIRMED groupings
  # (CustomerGrouping, state=confirmed — including auto-confirmed exact dups):
  #   - In a confirmed grouping → org = the grouping's parent label (so all
  #     "AEP - *" accounts share one "AEP" org); group = the account's location
  #     suffix (text after " - "), e.g. "Kentucky Power Co", else "Main".
  #   - Not in a confirmed grouping → org = the account's own name; group = "Main".
  # Every account gets a customer_group_id (uniform structure; the cashline UI
  # hides the group axis when an org has only one group). See
  # docs/method/questions-for-dre-bryce.md Q6/Q7.
  #
  # Idempotent: dedup entities are found-or-created by natural key; customer
  # accounts upsert on (sailfin_account_id, client_organization_id).
  class AccountImporter
    OBJECT = "Account".freeze
    DELIMITER = " - ".freeze
    DEFAULT_GROUP = "Main".freeze

    def initialize(extraction_run_id:, limit: nil, sf_ids: nil, scaffolding: ScaffoldingBuilder.new)
      @run_id = extraction_run_id
      @limit = limit
      @sf_ids = sf_ids
      @scaffolding = scaffolding
      @client_orgs = {}        # sailfin Brand__c id => client_organization_id
      @customer_orgs = {}      # normalized org name => customer_organization_id
      @customer_groups = {}    # "org_id::group name" => customer_group_id
      @seen_account_numbers = Set.new  # "client_org_id::account_number" already used
      @stats = Hash.new(0)
    end

    def call
      operator_id = @scaffolding.operator_id
      rows = []
      scope.find_each do |rec|
        p = rec.payload
        client_org_id = ensure_client_org(p, operator_id)
        client_group_id = @scaffolding.default_group_id_for(client_org_id)

        org_name = resolve_org_name(p)
        customer_org_id = ensure_customer_org(org_name, operator_id, p["Id"])
        customer_group_id = ensure_customer_group(customer_org_id, group_label_for(p))

        rows << customer_account_row(p, customer_org_id, client_org_id, client_group_id, customer_group_id)
        @stats[:accounts_seen] += 1
      end
      upsert_customer_accounts(rows)
      @stats[:client_orgs] = @client_orgs.size
      @stats[:customer_orgs] = @customer_orgs.size
      @stats[:customer_groups] = @customer_groups.size
      @stats
    end

    private

    def scope
      s = SfRecord.where(extraction_run_id: @run_id, object_api_name: OBJECT)
      s = s.where("payload->>'Id' IN (?)", @sf_ids) if @sf_ids.present?
      @limit ? s.limit(@limit) : s
    end

    # sailfin_account_id => parent label, for every member of a CONFIRMED grouping.
    def grouping_org_for
      @grouping_org_for ||= begin
        map = {}
        CustomerGrouping.for_run(@run_id).confirmed.includes(:members).find_each do |g|
          g.members.each { |m| map[m.sailfin_account_id] = g.parent_name }
        end
        map
      end
    end

    def resolve_org_name(payload)
      grouping_org_for[payload["Id"]].presence || payload["Name"].presence || "Unknown"
    end

    # Group = the location suffix, but only for accounts the operator confirmed
    # into a roll-up; otherwise the lone "Main" group (hidden in the UI).
    def group_label_for(payload)
      name = payload["Name"].to_s
      if grouping_org_for.key?(payload["Id"]) && name.include?(DELIMITER)
        clean_label(name.split(DELIMITER, 2).last)
      else
        DEFAULT_GROUP
      end
    end

    def ensure_client_org(payload, operator_id)
      brand_id = payload["Brand__c"].presence
      key = brand_id || "no-brand:#{slugify(payload['Brand_Name__c'] || payload['Brand_Code__c'] || 'unknown')}"
      @client_orgs[key] ||= begin
        existing = brand_id && CashlineSync::ClientOrganization.find_by(sailfin_brand_id: brand_id)
        (existing || create_client_org(payload, operator_id, brand_id)).id
      end
    end

    def create_client_org(payload, operator_id, brand_id)
      name = payload["Brand_Name__c"].presence || payload["Brand_Code__c"].presence || "Unknown Brand"
      slug_seed = payload["Brand_Code__c"].presence || name
      CashlineSync::ClientOrganization.create!(
        name: name,
        slug: unique_client_slug(operator_id, slugify(slug_seed)),
        group_label: "Group",
        operator_id: operator_id,
        sailfin_brand_id: brand_id
      )
    end

    def ensure_customer_org(org_name, operator_id, representative_sf_id)
      normalized = normalize(org_name)
      @customer_orgs[normalized] ||= begin
        existing = CashlineSync::CustomerOrganization.find_by(operator_id: operator_id, normalized_name: normalized)
        (existing || CashlineSync::CustomerOrganization.create!(
          canonical_name: org_name,
          normalized_name: normalized,
          operator_id: operator_id,
          sailfin_account_id: representative_sf_id
        )).id
      end
    end

    def ensure_customer_group(customer_org_id, label)
      @customer_groups["#{customer_org_id}::#{label}"] ||= begin
        existing = CashlineSync::CustomerGroup.find_by(customer_organization_id: customer_org_id, name: label)
        (existing || CashlineSync::CustomerGroup.create!(
          customer_organization_id: customer_org_id,
          name: label
        )).id
      end
    end

    def customer_account_row(payload, customer_org_id, client_org_id, client_group_id, customer_group_id)
      now = Time.current
      {
        customer_organization_id: customer_org_id,
        customer_group_id: customer_group_id,
        client_organization_id: client_org_id,
        client_group_id: client_group_id,
        display_name: payload["Name"].presence || "(unnamed)",
        account_number: dedupe_account_number(client_org_id, payload["AccountNumber"]),
        status: account_status(payload),
        submission_channel: 0, # unknown — derived from Ecommerce_System__c in a later pass
        portal_name: payload["Ecommerce_System__c"],
        payment_terms_notes: payload["Payment_Terms_Description__c"],
        notes: payload["sfsrm__Sticky_Note__c"],
        sailfin_account_id: payload["Id"],
        sailfin_brand_id: payload["Brand__c"],
        created_at: now,
        updated_at: now
      }
    end

    # cashline enforces account_number unique per client org, but Sailfin reuses
    # numbers within a brand (~832 accounts / 416 pairs). Keep the first, null the
    # rest — the account stays fully identified by display_name + sailfin_account_id.
    # (Postgres treats NULLs as distinct, so multiple nulls are fine.)
    def dedupe_account_number(client_org_id, raw)
      number = raw.presence
      return nil if number.nil?

      key = "#{client_org_id}::#{number}"
      if @seen_account_numbers.include?(key)
        @stats[:account_number_collisions] += 1
        nil
      else
        @seen_account_numbers << key
        number
      end
    end

    # customer_accounts.status enum: active(0) inactive(1) archived(2).
    # Slice approximation of the committed value_collapse on Account.Status__c.
    def account_status(payload)
      case payload["Status__c"].to_s.downcase
      when "inactive" then 1
      when "archived", "closed" then 2
      else 0
      end
    end

    UPSERT_BATCH = 2_000

    def upsert_customer_accounts(rows)
      return if rows.empty?
      # Batch — a single upsert_all of 100k+ rows is one enormous statement.
      rows.each_slice(UPSERT_BATCH) do |slice|
        CashlineSync::CustomerAccount.upsert_all(
          slice, unique_by: %i[sailfin_account_id client_organization_id]
        )
      end
      @stats[:customer_accounts] = rows.size
    end

    def unique_client_slug(operator_id, base)
      base = "brand" if base.blank?
      candidate = base
      i = 1
      while CashlineSync::ClientOrganization.where(operator_id: operator_id, slug: candidate).exists?
        i += 1
        candidate = "#{base}-#{i}"
      end
      candidate
    end

    def normalize(str)
      str.to_s.downcase.gsub(/\s+/, " ").strip
    end

    # Group/label tidy-up (decision #4): drop trailing punctuation + squish.
    # Casing is left as-is for now — see Q5 (name casing) which applies here too.
    def clean_label(str)
      str.to_s.sub(/[.,;:\s]+\z/, "").squish.presence || DEFAULT_GROUP
    end

    def slugify(str)
      s = str.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      s.presence || "x"
    end
  end
end
