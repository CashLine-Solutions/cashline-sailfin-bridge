# Mirrors ClusterPolicy: viewing requires a signed-in user; editing (confirm /
# reject / detect) requires analyst or admin. Groupings expose Sailfin customer
# names, so sensitive runs are gated behind sensitive_data_access? the same way
# clusters are.
class CustomerGroupingPolicy < ApplicationPolicy
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

  alias_method :confirm?, :edit?
  alias_method :reject?, :edit?
  alias_method :unreject?, :edit?
  alias_method :detect?, :edit?
  alias_method :merge?, :edit?
  alias_method :unmerge?, :edit?
  alias_method :roll_up?, :edit?
  alias_method :unroll?, :edit?
  alias_method :group_label?, :edit?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      return scope if user.sensitive_data_access?
      scope.joins(:extraction_run).where(extraction_runs: { include_sensitive: false })
    end
  end
end
