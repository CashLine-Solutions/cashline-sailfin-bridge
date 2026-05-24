require "test_helper"

class ObjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @analyst = User.create!(email_address: "analyst@example.com", password: "secret-pass-1", role: :analyst)
    @analyst_pii = User.create!(email_address: "pii@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false, user: @analyst, seed_objects: %w[Account], status: "complete", completed_at: Time.current)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account", label: "Account", raw_describe: {})
    @safe = Sfield.create!(sobject: @sobject, api_name: "Name", data_type: "string", sensitivity: "safe", raw_describe: {})
    @pii = Sfield.create!(sobject: @sobject, api_name: "Email", data_type: "email", sensitivity: "pii", raw_describe: {})
    @profile = ObjectProfile.create!(extraction_run: @run, sobject: @sobject, status: "complete", record_count: 100, profiled_at: Time.current)
    @safe_fp = FieldProfile.create!(object_profile: @profile, sfield: @safe, null_rate: 0.1, distinct_count: 80, top_values: [ { "v" => "Acme", "c" => 5 } ], sample_values: [ "Acme" ])
    @pii_fp = FieldProfile.create!(object_profile: @profile, sfield: @pii, null_rate: 0.0, distinct_count: 90, top_values: [ { "v" => "x@y.com", "c" => 1 } ], sample_values: [ "x@y.com" ])
  end

  def sign_in(user)
    post session_path, params: { email_address: user.email_address, password: "secret-pass-1" }
  end

  test "index renders 200 with the active run's objects" do
    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path
    assert_response :success
    assert_match("Account", response.body)
  end

  test "index filters by custom=1 (excludes standard objects)" do
    standard = Sobject.create!(extraction_run: @run, api_name: "StandardThing", custom: false, raw_describe: {})
    Sobject.create!(extraction_run: @run, api_name: "CustomThing__c", custom: true, raw_describe: {})

    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path(custom: "1")
    assert_response :success
    assert_match("CustomThing__c", response.body)
    refute_match("StandardThing", response.body)
  end

  test "index filters by sensitivity=pii (only sobjects with at least one pii field)" do
    so_with_pii = Sobject.create!(extraction_run: @run, api_name: "HasPii", raw_describe: {})
    Sfield.create!(sobject: so_with_pii, api_name: "PiiField", data_type: "email", sensitivity: "pii", raw_describe: {})
    Sobject.create!(extraction_run: @run, api_name: "AllSafe", raw_describe: {}).tap do |s|
      Sfield.create!(sobject: s, api_name: "Plain", data_type: "string", sensitivity: "safe", raw_describe: {})
    end

    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path(sensitivity: "pii")
    assert_response :success
    assert_match("HasPii", response.body)
    refute_match("AllSafe", response.body)
  end

  test "index filters by min_fields threshold" do
    big = Sobject.create!(extraction_run: @run, api_name: "Big", raw_describe: {})
    3.times { |i| Sfield.create!(sobject: big, api_name: "F#{i}", data_type: "string", sensitivity: "safe", raw_describe: {}) }
    small = Sobject.create!(extraction_run: @run, api_name: "Small", raw_describe: {})
    Sfield.create!(sobject: small, api_name: "Only", data_type: "string", sensitivity: "safe", raw_describe: {})

    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path(min_fields: "3")
    assert_response :success
    assert_match("Big", response.body)
    refute_match(">Small<", response.body)
  end

  test "index filters compose (custom + sensitivity)" do
    Sobject.create!(extraction_run: @run, api_name: "StandardPii", custom: false, raw_describe: {}).tap do |s|
      Sfield.create!(sobject: s, api_name: "P", data_type: "email", sensitivity: "pii", raw_describe: {})
    end
    Sobject.create!(extraction_run: @run, api_name: "CustomPii__c", custom: true, raw_describe: {}).tap do |s|
      Sfield.create!(sobject: s, api_name: "P", data_type: "email", sensitivity: "pii", raw_describe: {})
    end
    Sobject.create!(extraction_run: @run, api_name: "CustomSafe__c", custom: true, raw_describe: {}).tap do |s|
      Sfield.create!(sobject: s, api_name: "P", data_type: "string", sensitivity: "safe", raw_describe: {})
    end

    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path(custom: "1", sensitivity: "pii")
    assert_response :success
    assert_match("CustomPii__c", response.body)
    refute_match("StandardPii", response.body)
    refute_match("CustomSafe__c", response.body)
  end

  test "index renders namespace facet chips with counts" do
    Sobject.create!(extraction_run: @run, api_name: "sfsrm__Foo", namespace_prefix: "sfsrm", raw_describe: {})
    Sobject.create!(extraction_run: @run, api_name: "sfsrm__Bar", namespace_prefix: "sfsrm", raw_describe: {})
    Sobject.create!(extraction_run: @run, api_name: "Standard", namespace_prefix: nil, raw_describe: {})

    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path
    assert_response :success
    assert_match(/sfsrm \(2\)/, response.body)
    assert_match(/standard \(\d+\)/, response.body)
  end

  test "show renders fields and relationships for the object" do
    sign_in(@analyst)
    get object_path(@sobject.api_name, run: @run.id)
    assert_response :success
    assert_match("Email", response.body)
    assert_match("PII", response.body)
  end

  test "PII top-N/samples are redacted for non-sensitive run" do
    sign_in(@analyst_pii)
    get object_path(@sobject.api_name, run: @run.id)
    assert_response :success
    refute_match("x@y.com", response.body)
    assert_match("Acme", response.body, "safe field's value still rendered")
  end

  test "fields returns just the inline panel (no layout, includes turbo-frame tag)" do
    sign_in(@analyst)
    get fields_object_path(@sobject.api_name, run: @run.id)
    assert_response :success
    # turbo_frame_tag wraps the panel; the frame id is dom_id(@sobject, :fields)
    assert_match(/turbo-frame[^>]+id="fields_sobject_#{@sobject.id}"/, response.body)
    # Field table content from the shared partial
    assert_match("Name", response.body)
    assert_match("Email", response.body)
    # Layout-less render means no nav bar
    refute_match("Cashline", response.body[0..2000], "fields action must render without the application layout")
  end

  test "fields applies sensitivity redaction the same as show" do
    sign_in(@analyst_pii)
    get fields_object_path(@sobject.api_name, run: @run.id)
    assert_response :success
    refute_match("x@y.com", response.body, "PII top values must not leak via the inline panel")
    assert_match("Acme", response.body)
  end

  test "fields 404s for an api_name that doesn't exist on the active run" do
    sign_in(@analyst)
    post select_run_path(@run)
    get fields_object_path("ObjectThatDoesNotExist", run: @run.id)
    # ActionDispatch turns ActiveRecord::RecordNotFound into a 404 response
    # in integration tests, so we assert on the response rather than rescuing.
    assert_response :not_found
  end

  test "field action returns the extended-detail panel as a Turbo Frame" do
    sign_in(@analyst)
    get field_object_path(@sobject.api_name, field_name: @safe.api_name, run: @run.id)
    assert_response :success
    assert_match(/turbo-frame[^>]+id="detail_sfield_#{@safe.id}"/, response.body)
    assert_match("Name", response.body)
    # Layout-less response means no nav bar.
    refute_match("Cashline", response.body[0..1500], "field action must render without the app layout")
  end

  test "field 404s for an unknown field_name on a known object" do
    sign_in(@analyst)
    get field_object_path(@sobject.api_name, field_name: "DoesNotExist__c", run: @run.id)
    assert_response :not_found
  end

  test "field action redacts PII top-values when user lacks role" do
    sign_in(@analyst_pii) # has role, BUT @run is non-sensitive — should still show
    get field_object_path(@sobject.api_name, field_name: @pii.api_name, run: @run.id)
    # The run isn't sensitive so PII values are redacted in the panel
    # (matches the show-page semantics): see _field_detail_panel.html.erb's
    # may_view_values branching.
    assert_response :success
    refute_match("x@y.com", response.body, "PII top values must not leak via the field detail panel on a non-sensitive run")
  end

  test "sensitive run + role reveals PII values" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, user: @analyst_pii, seed_objects: %w[Account], status: "complete", completed_at: Time.current)
    so = Sobject.create!(extraction_run: sensitive_run, api_name: "Account", label: "Account", raw_describe: {})
    pii = Sfield.create!(sobject: so, api_name: "Email", data_type: "email", sensitivity: "pii", raw_describe: {})
    profile = ObjectProfile.create!(extraction_run: sensitive_run, sobject: so, status: "complete", profiled_at: Time.current)
    FieldProfile.create!(object_profile: profile, sfield: pii, null_rate: 0.0, distinct_count: 5, top_values: [ { "v" => "x@y.com", "c" => 1 } ], sample_values: [ "x@y.com" ], sensitive_override_used: true)

    sign_in(@analyst_pii)
    get object_path(so.api_name, run: sensitive_run.id)
    assert_response :success
    assert_match("x@y.com", response.body)
  end
end
