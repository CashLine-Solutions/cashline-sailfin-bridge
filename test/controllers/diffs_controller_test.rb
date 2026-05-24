require "test_helper"

class DiffsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear
    @analyst = User.create!(email_address: "diff-analyst@example.com", password: "secret-pass-1", role: :analyst)
    @reader = User.create!(email_address: "diff-reader@example.com", password: "secret-pass-1", role: :read_only)
    @analyst_pii = User.create!(email_address: "diff-pii@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)

    @run_a = ExtractionRun.create!(api_version: "62.0", user: @analyst, seed_objects: [], status: "complete", completed_at: 1.hour.ago)
    @run_b = ExtractionRun.create!(api_version: "62.0", user: @analyst, seed_objects: [], status: "complete", completed_at: Time.current)

    @old = Sobject.create!(extraction_run: @run_a, api_name: "Old", raw_describe: {})
    @new = Sobject.create!(extraction_run: @run_b, api_name: "New", raw_describe: {})
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "secret-pass-1" }
  end

  test "read_only user cannot reach diff form" do
    sign_in(@reader)
    get new_diff_path
    assert_redirected_to root_path
  end

  test "analyst sees diff form" do
    sign_in(@analyst)
    get new_diff_path
    assert_response :success
    assert_match(@run_a.directory_token, response.body)
    assert_match(@run_b.directory_token, response.body)
  end

  test "creating a diff persists a RunDiff and redirects to show" do
    sign_in(@analyst)
    assert_difference "RunDiff.count", +1 do
      post diffs_path, params: { run_a_id: @run_a.id, run_b_id: @run_b.id }
    end
    diff = RunDiff.order(:id).last
    assert_redirected_to diff_path(diff)
    assert_equal ["New"], diff.diff["object_added"]
    assert_equal ["Old"], diff.diff["object_removed"]
  end

  test "creating a diff with the same run twice fails" do
    sign_in(@analyst)
    assert_no_difference "RunDiff.count" do
      post diffs_path, params: { run_a_id: @run_a.id, run_b_id: @run_a.id }
    end
    assert_response :unprocessable_entity
    assert_match(/different/, response.body)
  end

  test "creating a diff missing one run fails" do
    sign_in(@analyst)
    assert_no_difference "RunDiff.count" do
      post diffs_path, params: { run_a_id: @run_a.id, run_b_id: "" }
    end
    assert_response :unprocessable_entity
  end

  test "show renders categorized sections" do
    sign_in(@analyst)
    post diffs_path, params: { run_a_id: @run_a.id, run_b_id: @run_b.id }
    diff = RunDiff.order(:id).last

    get diff_path(diff)
    assert_response :success
    assert_match("Objects added", response.body)
    assert_match("Objects removed", response.body)
    assert_match("New", response.body)
    assert_match("Old", response.body)
  end

  test "markdown download returns text/markdown body" do
    sign_in(@analyst)
    post diffs_path, params: { run_a_id: @run_a.id, run_b_id: @run_b.id }
    diff = RunDiff.order(:id).last

    get diff_path(diff, format: :md)
    assert_response :success
    assert_match(%r{text/markdown}, response.headers["Content-Type"])
    assert_match(/# Schema diff/, response.body)
    assert_match(/Objects added/, response.body)
  end

  test "show returns 404 for nonexistent diff" do
    sign_in(@analyst)
    get diff_path(id: 0)
    assert_response :not_found
  end

  test "diff involving a sensitive run is hidden from users without the role" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", user: @analyst_pii, seed_objects: [], include_sensitive: true, status: "complete", completed_at: Time.current)
    Sobject.create!(extraction_run: sensitive_run, api_name: "Secret", raw_describe: {})

    sign_in(@analyst_pii)
    post diffs_path, params: { run_a_id: @run_a.id, run_b_id: sensitive_run.id }
    diff = RunDiff.order(:id).last
    delete session_path

    sign_in(@analyst)
    get diff_path(diff)
    assert_redirected_to root_path
  end

  test "diff form rejects sensitive runs when user lacks role" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", user: @analyst_pii, seed_objects: [], include_sensitive: true, status: "complete", completed_at: Time.current)
    sign_in(@analyst)
    assert_no_difference "RunDiff.count" do
      post diffs_path, params: { run_a_id: @run_a.id, run_b_id: sensitive_run.id }
    end
    assert_response :forbidden
  end
end
