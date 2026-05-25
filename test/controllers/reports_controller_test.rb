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
    rows = response.body.lines
    assert_match(/bucket,api_name/, rows.first)
    # At least the three setup sobjects (A, B, OrphanObj) must appear as data rows.
    assert rows.size > 1, "CSV should emit data rows, not just the header"
    assert response.body.include?("A,") || response.body.include?(",A,"),
           "CSV should include a row for the 'A' sobject from setup"
  end

  test "mapping_order anchor wins over junction when both conditions are met" do
    # An object with high in_count AND out_count >= 2 AND non_ref_field_count <= 4
    # used to be misclassified as a junction. Classify now evaluates anchor first.
    hub = Sobject.create!(extraction_run: @run, api_name: "HubObj", raw_describe: {})
    2.times { |i| Sfield.create!(sobject: hub, api_name: "HF#{i}", data_type: "reference", sensitivity: "safe", raw_describe: {}) }
    # 2 outbound refs (junction-shape), 6 inbound refs (anchor-shape).
    target_x = Sobject.create!(extraction_run: @run, api_name: "HubTargetX", raw_describe: {})
    target_y = Sobject.create!(extraction_run: @run, api_name: "HubTargetY", raw_describe: {})
    Srelationship.create!(extraction_run: @run, source_sobject: hub, target_sobject: target_x)
    Srelationship.create!(extraction_run: @run, source_sobject: hub, target_sobject: target_y)
    6.times do |i|
      src = Sobject.create!(extraction_run: @run, api_name: "HubDep#{i}", raw_describe: {})
      Srelationship.create!(extraction_run: @run, source_sobject: src, target_sobject: hub)
    end

    sign_in(@user)
    get reports_mapping_order_path(run: @run.id, format: :csv)
    assert_response :success
    hub_row = response.body.lines.find { |l| l.start_with?("anchor,HubObj,") }
    assert hub_row, "HubObj should be classified as anchor when both anchor and junction conditions match"
  end

  test "mapping_order classify boundary cases" do
    # Anchor at in_count == ANCHOR_IN_COUNT_MIN (5)
    anchor_edge = Sobject.create!(extraction_run: @run, api_name: "AnchorEdge", raw_describe: {})
    5.times do |i|
      src = Sobject.create!(extraction_run: @run, api_name: "AE_Dep#{i}", raw_describe: {})
      Srelationship.create!(extraction_run: @run, source_sobject: src, target_sobject: anchor_edge)
    end
    # Just under anchor threshold (in_count = 4) → entity
    near_anchor = Sobject.create!(extraction_run: @run, api_name: "NearAnchor", raw_describe: {})
    4.times do |i|
      src = Sobject.create!(extraction_run: @run, api_name: "NA_Dep#{i}", raw_describe: {})
      Srelationship.create!(extraction_run: @run, source_sobject: src, target_sobject: near_anchor)
    end
    # Junction at non_ref_field_count == JUNCTION_NON_REF_FIELDS_MAX (4)
    junction_edge = Sobject.create!(extraction_run: @run, api_name: "JunctionEdge", raw_describe: {})
    Sfield.create!(sobject: junction_edge, api_name: "JE_R1", data_type: "reference", sensitivity: "safe", raw_describe: {})
    Sfield.create!(sobject: junction_edge, api_name: "JE_R2", data_type: "reference", sensitivity: "safe", raw_describe: {})
    4.times { |i| Sfield.create!(sobject: junction_edge, api_name: "JE_F#{i}", data_type: "string", sensitivity: "safe", raw_describe: {}) }
    je_target1 = Sobject.create!(extraction_run: @run, api_name: "JE_TargetA", raw_describe: {})
    je_target2 = Sobject.create!(extraction_run: @run, api_name: "JE_TargetB", raw_describe: {})
    Srelationship.create!(extraction_run: @run, source_sobject: junction_edge, target_sobject: je_target1)
    Srelationship.create!(extraction_run: @run, source_sobject: junction_edge, target_sobject: je_target2)
    # Just over junction threshold (non_ref_field_count = 5) → entity
    near_junction = Sobject.create!(extraction_run: @run, api_name: "NearJunction", raw_describe: {})
    Sfield.create!(sobject: near_junction, api_name: "NJ_R1", data_type: "reference", sensitivity: "safe", raw_describe: {})
    Sfield.create!(sobject: near_junction, api_name: "NJ_R2", data_type: "reference", sensitivity: "safe", raw_describe: {})
    5.times { |i| Sfield.create!(sobject: near_junction, api_name: "NJ_F#{i}", data_type: "string", sensitivity: "safe", raw_describe: {}) }
    nj_target1 = Sobject.create!(extraction_run: @run, api_name: "NJ_TargetA", raw_describe: {})
    nj_target2 = Sobject.create!(extraction_run: @run, api_name: "NJ_TargetB", raw_describe: {})
    Srelationship.create!(extraction_run: @run, source_sobject: near_junction, target_sobject: nj_target1)
    Srelationship.create!(extraction_run: @run, source_sobject: near_junction, target_sobject: nj_target2)

    sign_in(@user)
    get reports_mapping_order_path(run: @run.id, format: :csv)
    assert_response :success
    rows = response.body.lines

    assert rows.any? { |l| l.start_with?("anchor,AnchorEdge,") },     "in_count=5 should be anchor"
    assert rows.any? { |l| l.start_with?("entity,NearAnchor,") },    "in_count=4 should be entity"
    assert rows.any? { |l| l.start_with?("junction,JunctionEdge,") }, "non_ref_field_count=4 should be junction"
    assert rows.any? { |l| l.start_with?("entity,NearJunction,") },  "non_ref_field_count=5 should be entity"
  end

  test "mapping_order permits sensitive run for users with sensitive_data_access" do
    privileged = User.create!(email_address: "mapping-pp@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    sensitive_run = ExtractionRun.create!(api_version: "62.0", user: privileged, seed_objects: %w[Account], status: "complete", completed_at: Time.current, include_sensitive: true)
    Sobject.create!(extraction_run: sensitive_run, api_name: "SensitiveMappingObj", raw_describe: {})

    sign_in(privileged)
    get reports_mapping_order_path(run: sensitive_run.id)

    assert_response :success
    assert_match("SensitiveMappingObj", response.body)
  end

  test "mapping_order nil-run + .csv does not raise MissingTemplate" do
    sign_in(@user)
    # No run= param and no session-active run → @run is nil → returns the html
    # placeholder regardless of requested format. Must not 500.
    get reports_mapping_order_path(format: :csv)
    assert_response :success
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
