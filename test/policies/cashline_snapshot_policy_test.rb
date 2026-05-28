require "test_helper"

class CashlineSnapshotPolicyTest < ActiveSupport::TestCase
  setup do
    @reader = User.create!(email_address: "r@example.com", password: "secret-pass-1", role: :read_only)
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "abc", schema_json: { "classes" => [] })
  end

  test "any authenticated user can view a snapshot" do
    assert CashlineSnapshotPolicy.new(@reader, @snapshot).show?
    assert CashlineSnapshotPolicy.new(@reader, @snapshot).index?
  end

  test "unauthenticated users are denied" do
    refute CashlineSnapshotPolicy.new(nil, @snapshot).show?
    refute CashlineSnapshotPolicy.new(nil, @snapshot).index?
  end

  test "Scope returns all snapshots for an authenticated user" do
    scope = CashlineSnapshotPolicy::Scope.new(@reader, CashlineSnapshot.all).resolve
    assert_includes scope.pluck(:id), @snapshot.id
  end

  test "Scope returns nothing for unauthenticated users" do
    scope = CashlineSnapshotPolicy::Scope.new(nil, CashlineSnapshot.all).resolve
    assert_equal 0, scope.count
  end
end
