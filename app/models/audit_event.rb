# Append-only audit log for sensitive actions.
#
# Tamper resistance is provided by two layers:
#   1. Model layer: update/destroy raise; only the .record! method writes
#   2. DB layer: in production, the `cashline_audit_writer` Postgres role has
#      INSERT/SELECT only on this table, and a BEFORE UPDATE OR DELETE trigger
#      raises an exception. See lib/tasks/audit.rake and db/audit_migrate/.
#
# Schema: id, user_id, action, subject_type, subject_id, params (jsonb),
#         ip, user_agent, created_at. Indexed (user_id, created_at) and
#         (action, created_at).
class AuditEvent < AuditRecord
  self.table_name = "audit_events"

  # Block update / destroy at the model layer. The DB trigger provides
  # belt-and-braces enforcement when this model is bypassed (raw SQL,
  # rails console, etc).
  before_update { raise ActiveRecord::ReadOnlyRecord, "audit_events is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "audit_events is append-only" }

  def readonly?
    persisted?
  end

  # The single sanctioned way to write an audit event.
  #
  # @param user [User, nil] who initiated the action (nil for system events)
  # @param action [String] short event name (e.g., "run.trigger", "user.privilege_changed")
  # @param subject [ApplicationRecord, nil] the record acted on
  # @param params [Hash] arbitrary contextual data (will be stored as jsonb)
  # @param request [ActionDispatch::Request, nil] for ip/user_agent capture
  def self.record!(user: nil, action:, subject: nil, params: {}, request: nil)
    create!(
      user_id: user&.id,
      action: action,
      subject_type: subject&.class&.name,
      subject_id: subject&.id,
      params: params,
      ip: request&.remote_ip,
      user_agent: request&.user_agent&.first(500)
    )
  end
end
