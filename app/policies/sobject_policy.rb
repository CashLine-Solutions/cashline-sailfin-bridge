class SobjectPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    return false if user.nil?
    return true unless record.extraction_run&.include_sensitive
    user.sensitive_data_access?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      return scope if user.sensitive_data_access?
      # Defense-in-depth: even though ActiveRun gates `current_run` through
      # ExtractionRunPolicy, scope filtering ensures a manual Sobject query
      # in a future controller path can't leak rows belonging to sensitive runs.
      scope.joins(:extraction_run).where(extraction_runs: { include_sensitive: false })
    end
  end
end
