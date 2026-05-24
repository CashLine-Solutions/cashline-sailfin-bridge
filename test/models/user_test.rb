require "test_helper"

class UserTest < ActiveSupport::TestCase
  setup do
    @password = "secret-passphrase-1234"
  end

  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "defaults to read_only role and no sensitive_data_access" do
    user = User.create!(email_address: "alice@example.com", password: @password)
    assert user.read_only?
    refute user.sensitive_data_access?
  end

  test "role enum accepts admin, analyst, read_only" do
    user = User.create!(email_address: "bob@example.com", password: @password, role: :analyst)
    assert user.analyst?

    user.update!(role: :admin)
    assert user.admin?
  end

  test "audits role change" do
    user = User.create!(email_address: "carol@example.com", password: @password)
    Current.session = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test")

    assert_difference -> { AuditEvent.where(action: "user.privilege_changed").count }, 1 do
      user.update!(role: :analyst)
    end

    event = AuditEvent.where(action: "user.privilege_changed").last
    assert_equal user.id, event.subject_id
    assert_equal "User", event.subject_type
    assert event.params["changes"].key?("role")
  end

  test "audits sensitive_data_access change" do
    user = User.create!(email_address: "dave@example.com", password: @password)
    Current.session = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test")

    assert_difference -> { AuditEvent.where(action: "user.privilege_changed").count }, 1 do
      user.update!(sensitive_data_access: true)
    end
  end

  test "does not audit when no privilege fields changed" do
    user = User.create!(email_address: "eve@example.com", password: @password)
    Current.session = user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test")

    assert_no_difference -> { AuditEvent.where(action: "user.privilege_changed").count } do
      user.update!(email_address: "eve2@example.com")
    end
  end
end
