# frozen_string_literal: true

# Gates admin-only surfaces (GoodJob dashboard, Mission Control Jobs,
# operator runbook actions). Future surfaces should compose with this rather
# than re-checking the role inline.
class AdminPolicy < ApplicationPolicy
  def access?
    user&.admin?
  end
end
