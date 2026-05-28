require "test_helper"

class VisualizationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "v@example.com", password: "secret-pass-1", role: :analyst)
    @run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], include_sensitive: false, status: "complete", completed_at: Time.current)
    @account = Sobject.create!(extraction_run: @run, api_name: "Account", raw_describe: {})
    @brand   = Sobject.create!(extraction_run: @run, api_name: "Brand__c", raw_describe: {}, custom: true)
    @brand_account_field = Sfield.create!(sobject: @brand, api_name: "Account__c", data_type: "reference")
    Sfield.create!(sobject: @account, api_name: "Id",   data_type: "id")
    Sfield.create!(sobject: @account, api_name: "Name", data_type: "string")
    Sfield.create!(sobject: @brand,   api_name: "Id",   data_type: "id")
    Srelationship.create!(extraction_run: @run, source_sobject: @brand, target_sobject: @account, source_field: @brand_account_field)
    @cluster = Cluster.create!(extraction_run: @run, name: "Parties", color: "#2563eb")
    ClusterAssignment.create!(cluster: @cluster, sobject: @account)
    ClusterAssignment.create!(cluster: @cluster, sobject: @brand)
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "secret-pass-1" }
  end

  test "index renders the visualizations canvas markup" do
    sign_in(@user)
    get visualizations_path(run: @run.id)
    assert_response :success
    assert_match 'data-controller="bubble-chart"', response.body
    assert_match 'data-controller="heatmap"', response.body
  end

  test "index handles no active run gracefully" do
    @run.update!(status: "extracting")  # current_run filters to complete/complete_with_warnings
    sign_in(@user)
    get visualizations_path
    assert_response :success
    assert_match "No active run selected", response.body
  end

  test "data endpoint returns nodes, clusters, edges, and heatmap JSON" do
    sign_in(@user)
    get visualizations_data_path(run: @run.id), headers: { "Accept" => "application/json" }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 2, body["nodes"].size
    assert_equal 1, body["clusters"].size
    assert_equal 1, body["edges"].size
    edge = body["edges"].first
    assert_equal @brand.id,   edge["source"]
    assert_equal @account.id, edge["target"]
    assert_equal "Account__c", edge["source_field"]
    assert_equal false, edge["system"]
    node_account = body["nodes"].find { |n| n["api_name"] == "Account" }
    assert_equal 1,    node_account["in_count"]
    assert_equal 2,    node_account["field_count"]
    assert_equal @cluster.id, node_account["cluster_id"]
    assert_equal "Parties", body["clusters"].first["name"]
  end

  test "data tags system-owner edges and platform nodes" do
    user_sobj = Sobject.create!(extraction_run: @run, api_name: "User", raw_describe: {})
    created_by_field = Sfield.create!(sobject: @account, api_name: "CreatedById", data_type: "reference")
    Srelationship.create!(extraction_run: @run, source_sobject: @account, target_sobject: user_sobj, source_field: created_by_field)

    sign_in(@user)
    get visualizations_data_path(run: @run.id), headers: { "Accept" => "application/json" }
    body = JSON.parse(response.body)

    user_node = body["nodes"].find { |n| n["api_name"] == "User" }
    assert user_node["platform"], "User should be flagged as a platform node"
    brand_node = body["nodes"].find { |n| n["api_name"] == "Brand__c" }
    assert_equal false, brand_node["platform"]

    sys_edge = body["edges"].find { |e| e["source_field"] == "CreatedById" }
    assert sys_edge && sys_edge["system"], "CreatedById edge should be flagged as system"
    domain_edge = body["edges"].find { |e| e["source_field"] == "Account__c" }
    assert_equal false, domain_edge["system"]
  end

  test "legacy /graph redirects to /visualizations" do
    sign_in(@user)
    get graph_path
    assert_redirected_to "/visualizations"
  end

  test "data blocks sensitive run for users without sensitive_data_access" do
    sensitive = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], include_sensitive: true, status: "complete", completed_at: Time.current)
    Sobject.create!(extraction_run: sensitive, api_name: "SensitiveObj", raw_describe: {})

    sign_in(@user)
    get visualizations_data_path(run: sensitive.id), headers: { "Accept" => "application/json" }

    body = JSON.parse(response.body)
    refute body["nodes"].any? { |n| n["api_name"] == "SensitiveObj" }, "sensitive sobjects must not leak"
  end

  test "data permits sensitive run for privileged user" do
    privileged = User.create!(email_address: "vp@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    sensitive  = ExtractionRun.create!(api_version: "62.0", user: privileged, seed_objects: %w[Account], include_sensitive: true, status: "complete", completed_at: Time.current)
    Sobject.create!(extraction_run: sensitive, api_name: "SensitiveObj", raw_describe: {})

    sign_in(privileged)
    get visualizations_data_path(run: sensitive.id), headers: { "Accept" => "application/json" }
    assert_response :success
    body = JSON.parse(response.body)
    assert body["nodes"].any? { |n| n["api_name"] == "SensitiveObj" }
  end

  test "data endpoint returns heatmap rows derived from field profile fill rates" do
    op = ObjectProfile.create!(extraction_run: @run, sobject: @account, status: "complete", profiled_at: Time.current)
    name_field = @account.sfields.find_by(api_name: "Name")
    id_field   = @account.sfields.find_by(api_name: "Id")
    FieldProfile.create!(object_profile: op, sfield: name_field, null_rate: 0.10)
    FieldProfile.create!(object_profile: op, sfield: id_field,   null_rate: 0.00)

    sign_in(@user)
    get visualizations_data_path(run: @run.id), headers: { "Accept" => "application/json" }
    body = JSON.parse(response.body)
    heatmap_row = body["heatmap"].find { |r| r["api_name"] == "Account" }
    assert heatmap_row, "Account should have a heatmap row when its FieldProfiles have null_rate"
    # Most-filled field sorts first. Id (1.0 fill) before Name (0.9 fill).
    assert_equal "Id",   heatmap_row["cells"].first["field"]
    assert_in_delta 1.0, heatmap_row["cells"].first["fill"], 0.001
  end

  test "data endpoint with no active run returns empty payload" do
    @run.update!(status: "extracting")
    sign_in(@user)
    get visualizations_data_path, headers: { "Accept" => "application/json" }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [], body["nodes"]
    assert_equal [], body["clusters"]
    assert_equal [], body["heatmap"]
  end
end
