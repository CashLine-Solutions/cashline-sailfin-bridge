require "test_helper"

class ComputeDiffJobTest < ActiveJob::TestCase
  setup do
    @user = User.create!(email_address: "j@example.com", password: "secret-pass-1", role: :analyst)
    @run_a = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: [], include_sensitive: false)
    @run_b = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: [], include_sensitive: false)
    Sobject.create!(extraction_run: @run_a, api_name: "Old", raw_describe: {})
    Sobject.create!(extraction_run: @run_b, api_name: "New", raw_describe: {})
  end

  test "persists a RunDiff with the computed diff" do
    record = ComputeDiffJob.new.perform(@run_a.id, @run_b.id)

    assert_predicate record, :persisted?
    assert_equal [ "New" ], record.diff["object_added"]
    assert_equal [ "Old" ], record.diff["object_removed"]
    assert_not_nil record.computed_at
  end

  test "recomputing the same pair updates the existing row" do
    first = ComputeDiffJob.new.perform(@run_a.id, @run_b.id)
    second = ComputeDiffJob.new.perform(@run_a.id, @run_b.id)

    assert_equal first.id, second.id
    assert_equal 1, RunDiff.where(run_a_id: @run_a.id, run_b_id: @run_b.id).count
  end

  test "is enqueueable through perform_later" do
    assert_enqueued_with(job: ComputeDiffJob, args: [ @run_a.id, @run_b.id ]) do
      ComputeDiffJob.perform_later(@run_a.id, @run_b.id)
    end
  end
end
