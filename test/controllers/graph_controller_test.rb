require "test_helper"

class GraphControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "g@example.com", password: "secret-pass-1", role: :analyst)
    @run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], include_sensitive: false, status: "complete", completed_at: Time.current)
    @a = Sobject.create!(extraction_run: @run, api_name: "A", raw_describe: {})
    @b = Sobject.create!(extraction_run: @run, api_name: "B", raw_describe: {})
    Srelationship.create!(extraction_run: @run, source_sobject: @a, target_sobject: @b)
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "secret-pass-1" }
  end

  test "show renders graph canvas markup" do
    sign_in(@user)
    get graph_path(run: @run.id)
    assert_response :success
    assert_match("data-controller=\"graph\"", response.body)
  end

  test "data endpoint returns nodes and edges JSON" do
    sign_in(@user)
    get data_graph_path(run: @run.id), headers: { "Accept" => "application/json" }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["nodes"].size
    assert_equal 1, body["edges"].size
    assert_equal @a.id, body["edges"].first["source"]
  end

  test "data blocks ?run=<sensitive_id> for users without sensitive_data_access" do
    sensitive = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], include_sensitive: true, status: "complete", completed_at: Time.current)
    Sobject.create!(extraction_run: sensitive, api_name: "SensitiveObj", raw_describe: {})

    sign_in(@user)
    get data_graph_path(run: sensitive.id), headers: { "Accept" => "application/json" }

    body = JSON.parse(response.body)
    refute body["nodes"].any? { |n| n["label"] == "SensitiveObj" },
           "Sensitive sobject names must not leak through /graph/data?run= for users without sensitive_data_access"
  end

  test "data permits sensitive run for users with sensitive_data_access" do
    privileged = User.create!(email_address: "gp@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    sensitive = ExtractionRun.create!(api_version: "62.0", user: privileged, seed_objects: %w[Account], include_sensitive: true, status: "complete", completed_at: Time.current)
    Sobject.create!(extraction_run: sensitive, api_name: "SensitiveObj", raw_describe: {})

    sign_in(privileged)
    get data_graph_path(run: sensitive.id), headers: { "Accept" => "application/json" }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["nodes"].any? { |n| n["label"] == "SensitiveObj" }
  end
end
