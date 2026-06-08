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
  #   - Rolled up under a customer (customer_name set) → org = that customer;
  #     group = the grouping's group_label (so 50 "KINDER MORGAN *" groupings
  #     become one "KINDER MORGAN" org with a group each: "NGPL", "SNG", …).
  #   - Not in a confirmed grouping → org = the account's own name; group = "Main".
  # Every account gets a customer_group_id (uniform structure; the cashline UI
  # hides the group axis when an org has only one group). See
  # docs/method/questions-for-dre-bryce.md Q6/Q7.
  #
  # Activity filter (require_activity:, default on): only Accounts that carry at
  # least one AR transaction (sfsrm__Transaction__c) in this run are imported.
  # ~72% of the Account object is dormant (no open item ever) and only clutters
  # the collections workspace, so it's excluded — and the dormant-only customer
  # orgs/groups never get created.
  #
  # Roll-up to the documented grain — ONE Customer::Account per
  # (customer org/group x client org/group) pairing (see sailfin-crosswalk-columns
  # "AR link (one per customer x client pairing)"). Sailfin keeps a separate
  # Account row per location/variant, so many Accounts collapse into one pairing.
  # The kept row is a deterministic representative; the merged-in members stay
  # recoverable for invoice attribution via CustomerGroupingMember.sailfin_account_id
  # (the future invoice importer resolves a transaction's account through the
  # grouping, not only the representative's id).
  #
  # Full refresh, per operator, in one transaction: each run first purges this
  # operator's customer_accounts + customer_groups + customer_organizations, then
  # rebuilds them from source + CONFIRMED groupings. So a fix -> confirm -> re-sync
  # loop always leaves the sync DB an exact mirror — no orphaned orgs/groups left
  # behind when an account moves into (or out of) a grouping between runs.
  #
  # Client::Organization / Client::Group are deliberately NOT purged: they're
  # keyed by Sailfin Brand (stable, never orphaned) and are found-or-created, so
  # their ids stay put across runs for any importer that references them later.
  class AccountImporter
    OBJECT = "Account".freeze
    ACTIVITY_OBJECT = "sfsrm__Transaction__c".freeze
    ACTIVITY_ACCOUNT_FIELD = "sfsrm__Account__c".freeze
    DELIMITER = " - ".freeze
    DEFAULT_GROUP = "Main".freeze

    def initialize(extraction_run_id:, limit: nil, sf_ids: nil, require_activity: true, scaffolding: ScaffoldingBuilder.new)
      @run_id = extraction_run_id
      @limit = limit
      @sf_ids = sf_ids
      @require_activity = require_activity
      @scaffolding = scaffolding
      @client_orgs = {}        # sailfin Brand__c id => client_organization_id
      @customer_orgs = {}      # normalized org name => customer_organization_id
      @customer_groups = {}    # "org_id::group name" => customer_group_id
      @stats = Hash.new(0)
    end

    def call
      # One sync-DB transaction wraps purge + rebuild: a mid-run failure rolls
      # back to the prior state, never a half-populated DB. (Reads of SfRecord /
      # CustomerGrouping below hit the primary DB on a separate connection.)
      CashlineSync::CustomerAccount.transaction do
        operator_id = @scaffolding.operator_id
        purge_customer_data(operator_id)

        # Collapse to one row per (customer org/group x client org/group) pairing.
        pairings = {}
        scope.find_each do |rec|
          p = rec.payload
          if @require_activity && !active_account_ids.include?(p["Id"])
            @stats[:accounts_dormant] += 1
            next
          end

          client_org_id = ensure_client_org(p, operator_id)
          client_group_id = @scaffolding.default_group_id_for(client_org_id)

          org_name = resolve_org_name(p)
          customer_org_id = ensure_customer_org(org_name, operator_id, p["Id"])
          customer_group_id = ensure_customer_group(customer_org_id, group_label_for(p))

          row = customer_account_row(p, customer_org_id, client_org_id, client_group_id, customer_group_id)
          key = [ customer_org_id, customer_group_id, client_org_id, client_group_id ]
          pairings[key] = merge_pairing(pairings[key], row)
          @stats[:accounts_seen] += 1
        end

        rows = apply_account_number_dedup(pairings.values)
        @stats[:accounts_rolled_up] = @stats[:accounts_seen] - rows.size
        upsert_customer_accounts(rows)
      end
      @stats[:client_orgs] = @client_orgs.size
      @stats[:customer_orgs] = @customer_orgs.size
      @stats[:customer_groups] = @customer_groups.size
      @stats
    end

    private

    # Full refresh: drop this operator's customer-side rows before rebuilding so
    # nothing from a prior run lingers. Child-first (accounts -> groups -> orgs)
    # to respect FKs; scoped via the operator's customer_organizations, which is
    # where every customer_account and customer_group ultimately hangs.
    def purge_customer_data(operator_id)
      org_scope = CashlineSync::CustomerOrganization.where(operator_id: operator_id)
      # `where(... : org_scope)` compiles to IN (subquery) — no ids pulled into Ruby.
      @stats[:purged_accounts] = CashlineSync::CustomerAccount.where(customer_organization_id: org_scope).delete_all
      @stats[:purged_groups]   = CashlineSync::CustomerGroup.where(customer_organization_id: org_scope).delete_all
      @stats[:purged_orgs]     = org_scope.delete_all
    end

    def scope
      s = SfRecord.where(extraction_run_id: @run_id, object_api_name: OBJECT)
      s = s.where("payload->>'Id' IN (?)", @sf_ids) if @sf_ids.present?
      @limit ? s.limit(@limit) : s
    end

    # Sailfin Account Ids with at least one AR transaction in this run — the
    # accounts worth syncing into a collections workspace. Resolved once and
    # cached. (ACTIVITY_ACCOUNT_FIELD is a fixed schema constant, safe to inline.)
    def active_account_ids
      @active_account_ids ||= SfRecord
        .where(extraction_run_id: @run_id, object_api_name: ACTIVITY_OBJECT)
        .distinct
        .pluck(Arel.sql("payload->>'#{ACTIVITY_ACCOUNT_FIELD}'"))
        .compact
        .to_set
    end

    # sailfin_account_id => {org:, group:} for every member of a CONFIRMED
    # grouping. org is the customer (the grouping's roll-up customer if it's been
    # nested under one, else its own parent name); group is the explicit roll-up
    # label when set, else nil (let the account name decide the group).
    def grouping_for_account
      @grouping_for_account ||= begin
        map = {}
        CustomerGrouping.for_run(@run_id).confirmed.includes(:members).find_each do |g|
          org = g.customer_org
          group = g.rolled_up? ? g.group_label.presence : nil
          g.members.each { |m| map[m.sailfin_account_id] = { org: org, group: group } }
        end
        map
      end
    end

    def resolve_org_name(payload)
      info = grouping_for_account[payload["Id"]]
      (info && info[:org]).presence || payload["Name"].presence || "Unknown"
    end

    # Group label, in priority order: an explicit roll-up label on the grouping
    # ("NGPL"), else the account name's location suffix after " - ", else the lone
    # "Main" group (hidden in the UI when an org has only one group).
    def group_label_for(payload)
      info = grouping_for_account[payload["Id"]]
      return DEFAULT_GROUP unless info
      return clean_label(info[:group]) if info[:group].present?

      name = payload["Name"].to_s
      name.include?(DELIMITER) ? clean_label(name.split(DELIMITER, 2).last) : DEFAULT_GROUP
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
        account_number: payload["AccountNumber"].presence,
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

    # Fold a Sailfin Account into its pairing's representative row. Status is the
    # most-active across members (enum order: active(0) < inactive(1) < archived(2))
    # so one live account keeps the whole pairing live.
    def merge_pairing(existing, candidate)
      return candidate if existing.nil?

      winner = representative(existing, candidate)
      winner[:status] = [ existing[:status], candidate[:status] ].min
      winner
    end

    # Deterministic representative for a pairing: prefer a member that carries an
    # account_number (more identifying), then the lexically-lowest
    # sailfin_account_id so the choice is stable across full-refresh runs.
    def representative(a, b)
      a_rank = [ a[:account_number].present? ? 0 : 1, a[:sailfin_account_id].to_s ]
      b_rank = [ b[:account_number].present? ? 0 : 1, b[:sailfin_account_id].to_s ]
      (a_rank <=> b_rank) <= 0 ? a : b
    end

    # cashline enforces account_number unique per client org, but Sailfin reuses
    # numbers within a brand. After roll-up two representatives under one client
    # can still collide; keep the first (stable order), null the rest — the row
    # stays fully identified by sailfin_account_id. (Postgres treats NULLs as
    # distinct, so multiple nulls are fine.)
    def apply_account_number_dedup(rows)
      seen = Set.new
      rows.sort_by { |r| [ r[:client_organization_id], r[:sailfin_account_id].to_s ] }.each do |r|
        number = r[:account_number]
        next if number.blank?

        key = "#{r[:client_organization_id]}::#{number}"
        if seen.include?(key)
          r[:account_number] = nil
          @stats[:account_number_collisions] += 1
        else
          seen << key
        end
      end
      rows
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
