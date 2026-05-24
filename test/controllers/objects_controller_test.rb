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
    @safe_fp = FieldProfile.create!(object_profile: @profile, sfield: @safe, null_rate: 0.1, distinct_count: 80, top_values: [{ "v" => "Acme", "c" => 5 }], sample_values: ["Acme"])
    @pii_fp = FieldProfile.create!(object_profile: @profile, sfield: @pii, null_rate: 0.0, distinct_count: 90, top_values: [{ "v" => "x@y.com", "c" => 1 }], sample_values: ["x@y.com"])
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

  test "sensitive run + role reveals PII values" do
    sensitive_run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, user: @analyst_pii, seed_objects: %w[Account], status: "complete", completed_at: Time.current)
    so = Sobject.create!(extraction_run: sensitive_run, api_name: "Account", label: "Account", raw_describe: {})
    pii = Sfield.create!(sobject: so, api_name: "Email", data_type: "email", sensitivity: "pii", raw_describe: {})
    profile = ObjectProfile.create!(extraction_run: sensitive_run, sobject: so, status: "complete", profiled_at: Time.current)
    FieldProfile.create!(object_profile: profile, sfield: pii, null_rate: 0.0, distinct_count: 5, top_values: [{ "v" => "x@y.com", "c" => 1 }], sample_values: ["x@y.com"], sensitive_override_used: true)

    sign_in(@analyst_pii)
    get object_path(so.api_name, run: sensitive_run.id)
    assert_response :success
    assert_match("x@y.com", response.body)
  end
end
