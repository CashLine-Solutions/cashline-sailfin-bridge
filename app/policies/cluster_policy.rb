class ClusterPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    return false unless user.present?
    return true if record.is_a?(Class)
    return true unless record.extraction_run&.include_sensitive
    user.sensitive_data_access?
  end

  def edit?
    return false unless user.present? && (user.analyst? || user.admin?)
    return true if record.is_a?(Class)
    return true unless record.extraction_run&.include_sensitive
    user.sensitive_data_access?
  end

  alias_method :rename?, :edit?
  alias_method :assign?, :edit?
  alias_method :reset?, :edit?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      return scope if user.sensitive_data_access?
      scope.joins(:extraction_run).where(extraction_runs: { include_sensitive: false })
    end
  end
end
