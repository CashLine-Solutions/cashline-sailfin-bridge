require "test_helper"
require "tmpdir"
require "digest"

class CashlineLoadSnapshotTest < ActiveSupport::TestCase
  def fixture_json
    File.read(Rails.root.join("test/fixtures/files/cashline_snapshot.json"))
  end

  # Writes the snapshot JSON plus a sidecar into +dir+. Pass a bad sidecar to
  # simulate tampering.
  def write_snapshot(dir, sidecar: :valid)
    json = fixture_json
    json_path = File.join(dir, "snap.json")
    File.write(json_path, json)
    digest = sidecar == :valid ? Digest::SHA256.hexdigest(json) : "0" * 64
    File.write("#{json_path}.sha256", digest) unless sidecar == :missing
    json_path
  end

  test "loading a valid snapshot persists schema_json and round-trips" do
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir)
      snapshot = CashlineSnapshot.load_from_file!(path)

      assert snapshot.persisted?
      assert_equal 1, snapshot.schema_version
      assert_equal JSON.parse(fixture_json), snapshot.schema_json
    end
  end

  test "loading writes a cashline_snapshot.loaded audit event" do
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir)
      assert_difference -> { AuditEvent.where(action: "cashline_snapshot.loaded").count }, 1 do
        CashlineSnapshot.load_from_file!(path)
      end
      event = AuditEvent.where(action: "cashline_snapshot.loaded").order(:created_at).last
      assert_equal path, event.params["path"]
      assert_equal Digest::SHA256.hexdigest(fixture_json), event.params["sha256"]
    end
  end

  test "a tampered JSON (hash mismatch) raises and inserts nothing" do
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir, sidecar: :tampered)
      assert_no_difference -> { CashlineSnapshot.count } do
        assert_raises(CashlineSnapshot::IntegrityError) { CashlineSnapshot.load_from_file!(path) }
      end
    end
  end

  test "a missing sidecar raises a clear configuration error" do
    Dir.mktmpdir do |dir|
      path = write_snapshot(dir, sidecar: :missing)
      error = assert_raises(ArgumentError) { CashlineSnapshot.load_from_file!(path) }
      assert_match(/sidecar/, error.message)
    end
  end
end
