class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy

  enum :role, { read_only: 0, analyst: 1, admin: 2 }, default: :read_only

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true

  # Audit privilege changes (role, sensitive_data_access). This callback fires
  # regardless of whether the change came from a controller, rake task, or
  # rails console — privilege escalation is the single most-audited action.
  after_update_commit :audit_privilege_changes

  private

  def audit_privilege_changes
    return unless saved_change_to_role? || saved_change_to_sensitive_data_access?

    changes = {}
    changes[:role] = saved_change_to_role if saved_change_to_role?
    if saved_change_to_sensitive_data_access?
      changes[:sensitive_data_access] = saved_change_to_sensitive_data_access
    end

    AuditEvent.record!(
      user: Current.user,
      action: "user.privilege_changed",
      subject: self,
      params: { target_user_id: id, changes: changes }
    )
  end
end
