module Sync
  # Synthesizes the cashline-only rows that NOT NULL foreign keys require but
  # Sailfin has no source for: a single owning Operator, and a default
  # Client::Group per Client::Organization. Idempotent — safe to re-run.
  class ScaffoldingBuilder
    OPERATOR_NAME = "CashLine".freeze
    OPERATOR_SLUG = "cashline".freeze
    DEFAULT_GROUP_NAME = "Default".freeze
    DEFAULT_GROUP_SLUG = "default".freeze
    SYSTEM_USER_EMAIL = "sailfin-sync@cashline.local".freeze

    # operator_* are injectable so tests can run against a throwaway operator
    # (purge is operator-scoped, so a unique operator keeps parallel test runs
    # from clobbering each other in the shared sync DB). Defaults reproduce prod.
    def initialize(operator_name: OPERATOR_NAME, operator_slug: OPERATOR_SLUG)
      @operator_name = operator_name
      @operator_slug = operator_slug
    end

    def operator_id
      @operator_id ||= begin
        op = CashlineSync::Operator.find_by(slug: @operator_slug) ||
             CashlineSync::Operator.create!(name: @operator_name, slug: @operator_slug)
        op.id
      end
    end

    # A system user to own imported rows that require a creator (invoices'
    # created_by_user_id is NOT NULL, and Sailfin has no cashline user to map).
    def system_user_id
      @system_user_id ||= begin
        u = CashlineSync::User.find_by(email: SYSTEM_USER_EMAIL) ||
            CashlineSync::User.create!(email: SYSTEM_USER_EMAIL, first_name: "Sailfin", last_name: "Sync")
        u.id
      end
    end

    # The default Client::Group for a client org — used wherever a NOT NULL
    # client_group_id is required but Sailfin carries no group concept.
    def default_group_id_for(client_organization_id)
      (@groups ||= {})[client_organization_id] ||= begin
        grp = CashlineSync::ClientGroup.find_by(
          client_organization_id: client_organization_id, slug: DEFAULT_GROUP_SLUG
        ) || CashlineSync::ClientGroup.create!(
          client_organization_id: client_organization_id,
          name: DEFAULT_GROUP_NAME, slug: DEFAULT_GROUP_SLUG
        )
        grp.id
      end
    end
  end
end
