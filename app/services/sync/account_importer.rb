module Sync
  # Vertical slice of the Sailfin -> cashline importer: turns Sailfin `Account`
  # rows (in sf_records) into cashline rows on the sync DB.
  #
  # Fan-out per Account:
  #   - Client::Organization  (deduped by Brand, via sailfin_brand_id = Account.Brand__c)
  #       + a default Client::Group   (scaffolding)
  #   - Customer::Organization (canonical customer identity, deduped by normalized name)
  #   - Customer::Account      (the customer x client pairing; the row you browse)
  #
  # Field choices follow the committed snapshot-#1 mappings + the field map.
  # Idempotent: dedup entities are found-or-created by natural key; customer
  # accounts upsert on (sailfin_account_id, client_organization_id).
  class AccountImporter
    OBJECT = "Account".freeze

    def initialize(extraction_run_id:, limit: nil, scaffolding: ScaffoldingBuilder.new)
      @run_id = extraction_run_id
      @limit = limit
      @scaffolding = scaffolding
      @client_orgs = {}      # sailfin Brand__c id => client_organization_id
      @customer_orgs = {}    # normalized customer name => customer_organization_id
      @stats = Hash.new(0)
    end

    def call
      operator_id = @scaffolding.operator_id
      rows = []
      scope.find_each do |rec|
        p = rec.payload
        client_org_id = ensure_client_org(p, operator_id)
        group_id = @scaffolding.default_group_id_for(client_org_id)
        customer_org_id = ensure_customer_org(p, operator_id)
        rows << customer_account_row(p, customer_org_id, client_org_id, group_id)
        @stats[:accounts_seen] += 1
      end
      upsert_customer_accounts(rows)
      @stats[:client_orgs] = @client_orgs.size
      @stats[:customer_orgs] = @customer_orgs.size
      @stats
    end

    private

    def scope
      s = SfRecord.where(extraction_run_id: @run_id, object_api_name: OBJECT)
      @limit ? s.limit(@limit) : s
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

    def ensure_customer_org(payload, operator_id)
      name = payload["Name"].presence || "Unknown"
      normalized = normalize(name)
      @customer_orgs[normalized] ||= begin
        existing = CashlineSync::CustomerOrganization.find_by(operator_id: operator_id, normalized_name: normalized)
        (existing || CashlineSync::CustomerOrganization.create!(
          canonical_name: name,
          normalized_name: normalized,
          operator_id: operator_id,
          sailfin_account_id: payload["Id"]
        )).id
      end
    end

    def customer_account_row(payload, customer_org_id, client_org_id, group_id)
      now = Time.current
      {
        customer_organization_id: customer_org_id,
        client_organization_id: client_org_id,
        client_group_id: group_id,
        display_name: payload["Name"].presence || "(unnamed)",
        account_number: payload["AccountNumber"],
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

    # customer_accounts.status enum: active(0) inactive(1) archived(2).
    # Slice approximation of the committed value_collapse on Account.Status__c.
    def account_status(payload)
      case payload["Status__c"].to_s.downcase
      when "inactive" then 1
      when "archived", "closed" then 2
      else 0
      end
    end

    def upsert_customer_accounts(rows)
      return if rows.empty?
      CashlineSync::CustomerAccount.upsert_all(
        rows, unique_by: %i[sailfin_account_id client_organization_id]
      )
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

    def slugify(str)
      s = str.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      s.presence || "x"
    end
  end
end
