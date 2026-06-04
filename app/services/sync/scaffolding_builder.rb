module Sync
  # Synthesizes the cashline-only rows that NOT NULL foreign keys require but
  # Sailfin has no source for: a single owning Operator, and a default
  # Client::Group per Client::Organization. Idempotent — safe to re-run.
  class ScaffoldingBuilder
    OPERATOR_NAME = "CashLine".freeze
    OPERATOR_SLUG = "cashline".freeze
    DEFAULT_GROUP_NAME = "Default".freeze
    DEFAULT_GROUP_SLUG = "default".freeze

    def operator_id
      @operator_id ||= begin
        op = CashlineSync::Operator.find_by(slug: OPERATOR_SLUG) ||
             CashlineSync::Operator.create!(name: OPERATOR_NAME, slug: OPERATOR_SLUG)
        op.id
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
