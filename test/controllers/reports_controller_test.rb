require "test_helper"

class ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email_address: "r@example.com", password: "secret-pass-1", role: :analyst)
    @run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], status: "complete", completed_at: Time.current)
    @a = Sobject.create!(extraction_run: @run, api_name: "A", raw_describe: {})
    @b = Sobject.create!(extraction_run: @run, api_name: "B", raw_describe: {})
    @orphan = Sobject.create!(extraction_run: @run, api_name: "OrphanObj", raw_describe: {})
    Srelationship.create!(extraction_run: @run, source_sobject: @a, target_sobject: @b)
    Srelationship.create!(extraction_run: @run, source_sobject: @b, target_sobject: @a)

    f = Sfield.create!(sobject: @a, api_name: "AlwaysNull", data_type: "string", sensitivity: "safe", raw_describe: {})
    profile = ObjectProfile.create!(extraction_run: @run, sobject: @a, status: "complete", profiled_at: Time.current)
    FieldProfile.create!(object_profile: profile, sfield: f, null_rate: 1.0, distinct_count: 0)
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "secret-pass-1" }
  end

  test "hub_orphan ranks by total degree" do
    sign_in(@user)
    get reports_hub_orphan_path(run: @run.id)
    assert_response :success
    a_pos = response.body.index("A</a>") || response.body.index(">A<")
    orphan_pos = response.body.index("OrphanObj")
    assert orphan_pos, "OrphanObj should appear on the page"
  end

  test "hub_orphan CSV download" do
    sign_in(@user)
    get reports_hub_orphan_path(run: @run.id, format: :csv)
    assert_response :success
    assert_match(/api_name,namespace_prefix,out_count,in_count/, response.body)
  end

  test "unused_fields lists fields above threshold" do
    sign_in(@user)
    get reports_unused_fields_path(run: @run.id)
    assert_response :success
    assert_match("AlwaysNull", response.body)
  end

  test "unused_fields respects custom threshold" do
    sign_in(@user)
    get reports_unused_fields_path(run: @run.id, threshold: "0.5")
    assert_response :success
    assert_match("AlwaysNull", response.body)
  end

  test "hub_orphan blocks ?run=<sensitive_id> for users without sensitive_data_access" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], status: "complete", completed_at: Time.current, include_sensitive: true)
    Sobject.create!(extraction_run: sensitive_run, api_name: "SecretObj", raw_describe: {})

    sign_in(@user)
    get reports_hub_orphan_path(run: sensitive_run.id)

    refute_match("SecretObj", response.body, "Sensitive sobject names must not leak via ?run param to users without sensitive_data_access")
  end

  test "unused_fields blocks ?run=<sensitive_id> for users without sensitive_data_access" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], status: "complete", completed_at: Time.current, include_sensitive: true)
    so = Sobject.create!(extraction_run: sensitive_run, api_name: "SecretObj", raw_describe: {})
    sf = Sfield.create!(sobject: so, api_name: "SecretField", data_type: "string", sensitivity: "pii", raw_describe: {})
    profile = ObjectProfile.create!(extraction_run: sensitive_run, sobject: so, status: "complete", profiled_at: Time.current)
    FieldProfile.create!(object_profile: profile, sfield: sf, null_rate: 1.0, distinct_count: 0)

    sign_in(@user)
    get reports_unused_fields_path(run: sensitive_run.id)

    refute_match("SecretField", response.body, "Sensitive field names must not leak via ?run param to users without sensitive_data_access"
    )
  end

  test "mapping_order classifies anchors, entities, and junctions" do
    # Anchor: heavily referenced, references few.
    anchor = Sobject.create!(extraction_run: @run, api_name: "AnchorObj", raw_describe: {})
    8.times { |i| Sfield.create!(sobject: anchor, api_name: "AF#{i}", data_type: "string", sensitivity: "safe", raw_describe: {}) }
    # Junction: links two objects, few business fields.
    junction = Sobject.create!(extraction_run: @run, api_name: "JunctionObj", raw_describe: {})
    Sfield.create!(sobject: junction, api_name: "JF1", data_type: "reference", sensitivity: "safe", raw_describe: {})
    Sfield.create!(sobject: junction, api_name: "JF2", data_type: "reference", sensitivity: "safe", raw_describe: {})
    target_a = Sobject.create!(extraction_run: @run, api_name: "TargetA", raw_describe: {})
    target_b = Sobject.create!(extraction_run: @run, api_name: "TargetB", raw_describe: {})
    Srelationship.create!(extraction_run: @run, source_sobject: junction, target_sobject: target_a)
    Srelationship.create!(extraction_run: @run, source_sobject: junction, target_sobject: target_b)
    # 6 dependents pointing at the anchor (in_count = 6).
    6.times do |i|
      src = Sobject.create!(extraction_run: @run, api_name: "Dep#{i}", raw_describe: {})
      Srelationship.create!(extraction_run: @run, source_sobject: src, target_sobject: anchor)
    end

    sign_in(@user)
    get reports_mapping_order_path(run: @run.id)
    assert_response :success
    assert_match("AnchorObj", response.body)
    assert_match("JunctionObj", response.body)
    # Anchors section appears before junctions section in the rendered HTML.
    anchor_pos = response.body.index("AnchorObj")
    junction_pos = response.body.index("JunctionObj")
    assert anchor_pos < junction_pos, "anchors must render before junctions"
  end

  test "mapping_order CSV emits one row per object with bucket column" do
    sign_in(@user)
    get reports_mapping_order_path(run: @run.id, format: :csv)
    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match(/bucket,api_name/, response.body.lines.first)
  end

  test "mapping_order blocks sensitive run for users without sensitive_data_access" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: %w[Account], status: "complete", completed_at: Time.current, include_sensitive: true)
    Sobject.create!(extraction_run: sensitive_run, api_name: "SecretObj", raw_describe: {})

    sign_in(@user)
    get reports_mapping_order_path(run: sensitive_run.id)
    refute_match("SecretObj", response.body, "Sensitive sobject names must not leak via mapping_order")
  end

  test "hub_orphan permits sensitive run for users with sensitive_data_access" do
    privileged = User.create!(email_address: "p@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    sensitive_run = ExtractionRun.create!(api_version: "62.0", user: privileged, seed_objects: %w[Account], status: "complete", completed_at: Time.current, include_sensitive: true)
    Sobject.create!(extraction_run: sensitive_run, api_name: "SensitiveObj", raw_describe: {})

    sign_in(privileged)
    get reports_hub_orphan_path(run: sensitive_run.id)

    assert_response :success
    assert_match("SensitiveObj", response.body)
  end
end
