require "test_helper"

class AuditEventTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "auditor@example.com", password: "secret-passphrase-1234")
  end

  test "record! inserts a row with all expected columns" do
    event = AuditEvent.record!(
      user: @user,
      action: "run.trigger",
      subject: @user,
      params: { foo: "bar" }
    )
    assert_equal "run.trigger", event.action
    assert_equal @user.id, event.user_id
    assert_equal "User", event.subject_type
    assert_equal @user.id, event.subject_id
    assert_equal "bar", event.params["foo"]
    assert_not_nil event.created_at
  end

  test "user_id may be nil for system-initiated events" do
    event = AuditEvent.record!(action: "system.boot", params: { ok: true })
    assert_nil event.user_id
    assert_equal "system.boot", event.action
  end

  test "update raises at model layer" do
    event = AuditEvent.record!(action: "x.test", user: @user)
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      event.update(action: "tampered")
    end
  end

  test "destroy raises at model layer" do
    event = AuditEvent.record!(action: "x.test", user: @user)
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      event.destroy
    end
  end

  test "DB trigger blocks raw UPDATE" do
    event = AuditEvent.record!(action: "x.raw_update", user: @user)
    assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.connection.execute(
        "UPDATE audit_events SET action = 'tampered' WHERE id = #{event.id}"
      )
    end
  end

  test "DB trigger blocks raw DELETE" do
    event = AuditEvent.record!(action: "x.raw_delete", user: @user)
    assert_raises(ActiveRecord::StatementInvalid) do
      AuditEvent.connection.execute(
        "DELETE FROM audit_events WHERE id = #{event.id}"
      )
    end
  end

  test "lives in the audit database, not primary" do
    assert_equal "primary", User.connection_db_config.name
    assert_equal "audit", AuditEvent.connection_db_config.name
  end
end
