class CashlineSnapshotPolicy < ApplicationPolicy
  # A snapshot holds only cashline-platform's *schema* metadata (class/column
  # names, enum maps) — never Sailfin data — so visibility is plain
  # authentication. Sensitivity gating lives on the mapping rows (Unit 5).
  def index?
    user.present?
  end

  def show?
    user.present?
  end

  def select_active?
    show?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none if user.nil?
      scope.all
    end
  end
end
