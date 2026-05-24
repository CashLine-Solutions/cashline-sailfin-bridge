class RunDiffPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    user.present? && run_a_viewable? && run_b_viewable?
  end

  def new?
    create?
  end

  def create?
    return false if user.nil?
    user.analyst? || user.admin?
  end

  private

  def run_a_viewable?
    run = record.respond_to?(:run_a) ? record.run_a : nil
    return true if run.nil?
    ExtractionRunPolicy.new(user, run).show?
  end

  def run_b_viewable?
    run = record.respond_to?(:run_b) ? record.run_b : nil
    return true if run.nil?
    ExtractionRunPolicy.new(user, run).show?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      scope
    end
  end
end
