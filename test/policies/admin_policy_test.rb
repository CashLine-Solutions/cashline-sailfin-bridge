require "test_helper"

class AdminPolicyTest < ActiveSupport::TestCase
  setup do
    pw = "secret-passphrase-1234"
    @admin = User.create!(email_address: "admin@example.com", password: pw, role: :admin)
    @analyst = User.create!(email_address: "analyst@example.com", password: pw, role: :analyst)
    @read_only = User.create!(email_address: "ro@example.com", password: pw, role: :read_only)
  end

  test "admin can access" do
    assert AdminPolicy.new(@admin, nil).access?
  end

  test "analyst cannot access" do
    refute AdminPolicy.new(@analyst, nil).access?
  end

  test "read_only cannot access" do
    refute AdminPolicy.new(@read_only, nil).access?
  end

  test "anonymous (nil user) cannot access" do
    refute AdminPolicy.new(nil, nil).access?
  end
end
