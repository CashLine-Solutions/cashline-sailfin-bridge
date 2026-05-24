require "test_helper"

class ExtractionRunTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "ops@example.com", password: "secret-pass-1", role: :analyst)
  end

  test "creating a run assigns a directory_token" do
    run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account])
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z-[0-9a-f]{4}\z/, run.directory_token)
  end

  test "two runs created in the same second get distinct directory tokens" do
    travel_to Time.utc(2026, 5, 23, 14, 0, 0) do
      r1 = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
      r2 = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
      refute_equal r1.directory_token, r2.directory_token
    end
  end

  test "include_sensitive=true assigns a default retained_until 30 days out" do
    travel_to Time.utc(2026, 5, 23, 14, 0, 0) do
      run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, seed_objects: %w[Account])
      assert run.retained_until.present?
      assert_in_delta 30.days.from_now.to_i, run.retained_until.to_i, 5
    end
  end

  test "non-sensitive runs have no retained_until" do
    run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
    assert_nil run.retained_until
  end

  test "mark_started! sets extracting status + started_at + limits snapshot" do
    run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
    run.mark_started!(limits_snapshot: { "DailyApiRequests" => { "Max" => 15_000, "Remaining" => 14_000 } })
    assert_equal "extracting", run.status
    assert run.started_at.present?
    assert_equal 14_000, run.limits_at_start["DailyApiRequests"]["Remaining"]
  end

  test "mark_complete! sets complete when no partial failures" do
    run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
    run.mark_complete!(content_hash: "abc")
    assert_equal "complete", run.status
    assert_equal "abc", run.content_hash
  end

  test "mark_complete! sets complete_with_warnings when partial failures recorded" do
    run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
    run.record_partial_failure!(object_api_name: "Invoice__c", reason: "describe timeout")
    run.mark_complete!
    assert_equal "complete_with_warnings", run.status
    assert_equal 1, run.partial_failures.size
  end

  test "mark_failed! captures error message" do
    run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
    run.mark_failed!("token exchange failed")
    assert_equal "failed", run.status
    assert_equal "token exchange failed", run.error_message
  end

  test "destroying a run cascades through profiles, fields, picklist values, and relationships" do
    run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: [])
    other = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: [])
    acc = Sobject.create!(extraction_run: run, api_name: "Account", raw_describe: {})
    contact = Sobject.create!(extraction_run: run, api_name: "Contact", raw_describe: {})
    sf = Sfield.create!(sobject: acc, api_name: "Status", data_type: "picklist", raw_describe: {})
    SpicklistValue.create!(sfield: sf, value: "Open", active: true)
    Srelationship.create!(extraction_run: run, source_sobject: contact, target_sobject: acc)
    profile = ObjectProfile.create!(extraction_run: run, sobject: acc, status: "complete", profiled_at: Time.current)
    FieldProfile.create!(object_profile: profile, sfield: sf, null_rate: 0.1)
    RunDiff.create!(run_a: run, run_b: other, computed_at: Time.current, diff: {})

    assert_nothing_raised { run.destroy! }

    assert_equal 0, Sobject.where(extraction_run_id: run.id).count
    assert_equal 0, Sfield.where(sobject_id: acc.id).count
    assert_equal 0, SpicklistValue.where(sfield_id: sf.id).count
    assert_equal 0, ObjectProfile.where(extraction_run_id: run.id).count
    assert_equal 0, FieldProfile.where(object_profile_id: profile.id).count
    assert_equal 0, Srelationship.where(extraction_run_id: run.id).count
    assert_equal 0, RunDiff.where(run_a_id: run.id).count
  end

  test "purgeable scope finds sensitive runs past retained_until" do
    expired = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, seed_objects: [], retained_until: 1.day.ago)
    fresh = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, seed_objects: [], retained_until: 1.day.from_now)
    non_sensitive = ExtractionRun.create!(api_version: "62.0", include_sensitive: false, seed_objects: [])

    purgeable = ExtractionRun.purgeable.pluck(:id)
    assert_includes purgeable, expired.id
    refute_includes purgeable, fresh.id
    refute_includes purgeable, non_sensitive.id
  end
end
