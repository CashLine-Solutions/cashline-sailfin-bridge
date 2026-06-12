require "test_helper"

# See Sync::AccountImporterTest for the sync-DB test setup rationale (self-skip
# when unreachable). Users are a GLOBAL platform table (no operator scope), so
# this test keys everything off a unique sailfin_user_id / email prefix and
# cleans up exactly the rows it created in teardown.
class Sync::UserImporterTest < ActiveSupport::TestCase
  setup do
    @tag = SecureRandom.hex(6)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false)
    @sync_available = sync_available?
  end

  teardown do
    next unless @sync_available
    CashlineSync::User.where("sailfin_user_id LIKE ?", "U#{@tag}%").delete_all
    CashlineSync::User.where("email LIKE ?", "%#{@tag}@example.com").delete_all
  end

  test "imports all Sailfin users blocked, including departed and system accounts" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_user("U#{@tag}1", email: "active#{@tag}@example.com", first: "Ann", last: "Active", active: true)
    sf_user("U#{@tag}2", email: "gone#{@tag}@example.com", first: "Gus", last: "Gone", active: false)
    sf_user("U#{@tag}3", email: "bot#{@tag}@example.com", first: nil, last: "Bot", type: "AutomatedProcess")

    stats = Sync::UserImporter.new(extraction_run_id: @run.id).call

    assert_equal 3, stats[:created]
    departed = CashlineSync::User.find_by(sailfin_user_id: "U#{@tag}2")
    assert departed, "departed user kept for history"
    assert departed.blocked, "every imported user is blocked (no login)"
    assert_equal "Gus", departed.first_name
    bot = CashlineSync::User.find_by(sailfin_user_id: "U#{@tag}3")
    assert bot, "system/automation account imported so Task owners never dangle"
    assert_equal "Bot", bot.last_name
  end

  test "re-sync is non-destructive: never re-blocks or re-passwords an invited user" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    sf_user("U#{@tag}1", email: "person#{@tag}@example.com", first: "Pat", last: "Person", active: true)
    Sync::UserImporter.new(extraction_run_id: @run.id).call

    # Simulate the platform later granting this person a real login.
    user = CashlineSync::User.find_by(sailfin_user_id: "U#{@tag}1")
    user.update_columns(blocked: false, encrypted_password: "REAL_BCRYPT_HASH", first_name: "Patricia")

    # A later Sailfin sync (name changed upstream too) must not clobber auth state.
    set_payload("U#{@tag}1", first: "Patrick")
    stats = Sync::UserImporter.new(extraction_run_id: @run.id).call

    user.reload
    assert_equal 1, stats[:updated]
    assert_equal 0, stats[:created]
    refute user.blocked, "invited user stays unblocked across re-sync"
    assert_equal "REAL_BCRYPT_HASH", user.encrypted_password, "real password is never overwritten"
    assert_equal "Patrick", user.first_name, "display fields still refresh from source"
  end

  test "matches an existing platform user by email and stamps its sailfin_user_id" do
    skip "cashline_sailfin_sync_test not provisioned" unless @sync_available

    # A platform user invited before any Sailfin link exists.
    existing = CashlineSync::User.create!(
      email: "shared#{@tag}@example.com", first_name: "Shared", last_name: "Soul",
      encrypted_password: "HASH", blocked: false, theme_preference: "system"
    )
    sf_user("U#{@tag}9", email: "Shared#{@tag}@example.com", first: "Shared", last: "Soul", active: true)

    stats = Sync::UserImporter.new(extraction_run_id: @run.id).call

    assert_equal 0, stats[:created], "no duplicate row — matched by email despite case"
    assert_equal 1, stats[:updated]
    existing.reload
    assert_equal "U#{@tag}9", existing.sailfin_user_id, "sailfin id stamped onto the existing row"
    refute existing.blocked, "matching by email never re-blocks the invited user"
  end

  private

  def sf_user(sf_id, email:, first:, last:, active: true, type: "Standard")
    SfRecord.create!(extraction_run: @run, object_api_name: "User", sf_id: sf_id, exported_at: Time.current,
      payload: { "Id" => sf_id, "Email" => email, "FirstName" => first, "LastName" => last,
                 "Name" => [ first, last ].compact.join(" "), "IsActive" => active, "UserType" => type })
  end

  def set_payload(sf_id, first:)
    rec = SfRecord.find_by(extraction_run_id: @run.id, object_api_name: "User", sf_id: sf_id)
    rec.update!(payload: rec.payload.merge("FirstName" => first))
  end

  def sync_available?
    CashlineSync::User.connection.select_value("SELECT 1 FROM users LIMIT 1")
    true
  rescue StandardError
    false
  end
end
