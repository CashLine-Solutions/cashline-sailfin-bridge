class ExtractionRunPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    return false if user.nil?
    return true unless record.include_sensitive
    user.sensitive_data_access?
  end

  def new?
    create?
  end

  def create?
    return false if user.nil?
    user.analyst? || user.admin?
  end

  def trigger_with_pii?
    create? && user.sensitive_data_access?
  end

  def select_active?
    show?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      return scope.all if user.sensitive_data_access?
      scope.where(include_sensitive: false)
    end
  end
end
