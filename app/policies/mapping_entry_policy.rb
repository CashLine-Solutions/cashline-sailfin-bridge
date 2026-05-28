class MappingEntryPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    user.present?
  end

  # analyst (and admin) may create/update mappings; read_only may only view.
  def create?
    analyst_or_admin?
  end
  alias_method :update?, :create?

  # True row deletion is admin-only (clearing a target is an update, not destroy).
  def destroy?
    user&.admin? || false
  end

  # Both CSV exports require analyst/admin (read_only may view but not export).
  def export?
    analyst_or_admin?
  end

  # The value-companion CSV and free-text columns can carry real values, so they
  # additionally require sensitive_data_access.
  def export_sensitive?
    analyst_or_admin? && user.sensitive_data_access?
  end

  private

  def analyst_or_admin?
    return false if user.nil?
    user.analyst? || user.admin?
  end

  # Gates grid/row VISIBILITY via the run-level `include_sensitive` dimension —
  # NOT the per-field `sfields.sensitivity` (that governs transmission/value
  # display in Units 10/8). See the plan's Key Technical Decisions.
  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      return scope if user.sensitive_data_access?

      # source_field_id is nullable (net_new), so this must be a null-safe
      # filter, NOT SobjectPolicy::Scope's inner join (whose FK is NOT NULL) —
      # an inner join would silently drop every net_new row. net_new rows
      # (null source) stay visible.
      scope.where(
        "mapping_entries.source_field_id IS NULL OR mapping_entries.source_field_id NOT IN (?)",
        MappingEntryPolicy.sensitive_source_field_ids
      )
    end
  end

  def self.sensitive_source_field_ids
    Sfield.joins(sobject: :extraction_run)
      .where(extraction_runs: { include_sensitive: true })
      .select(:id)
  end
end
