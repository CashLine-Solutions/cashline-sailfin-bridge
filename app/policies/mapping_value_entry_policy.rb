class MappingValueEntryPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    user.present?
  end

  def create?
    analyst_or_admin?
  end
  alias_method :update?, :create?

  def destroy?
    analyst_or_admin?
  end

  private

  def analyst_or_admin?
    return false if user.nil?
    user.analyst? || user.admin?
  end

  # Child rows inherit the parent's visibility: a value row is hidden whenever
  # its parent MappingEntry's source field belongs to a sensitive run (for
  # users without sensitive_data_access). Children of net_new parents (null
  # source) stay visible via the same null-safe filter.
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      return scope if user.sensitive_data_access?

      scope.joins(:mapping_entry).where(
        "mapping_entries.source_field_id IS NULL OR mapping_entries.source_field_id NOT IN (?)",
        MappingEntryPolicy.sensitive_source_field_ids
      )
    end
  end
end
