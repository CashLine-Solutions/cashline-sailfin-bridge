class ObjectViewPolicy < ApplicationPolicy
  def index?
    user.present?
  end

  def show?
    return false if user.nil?
    run = record.respond_to?(:extraction_run) ? record.extraction_run : record
    return true unless run&.include_sensitive
    user.sensitive_data_access?
  end

  # Inline-expand fields panel uses the same access rule as show.
  alias_method :fields?, :show?
end
