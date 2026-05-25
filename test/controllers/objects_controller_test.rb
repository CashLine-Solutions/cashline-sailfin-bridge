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

  test "index responds to .csv with one row per field, header row included" do
    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path(format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    rows = response.body.lines
    assert rows.first.include?("sobject_api_name"), "first row should be CSV headers"
    assert rows.first.include?("field_api_name")
    assert rows.first.include?("null_rate")
    # Mapping columns are appended for designers to fill in.
    assert rows.first.include?("target_iri"), "CSV header must include target_iri"
    assert rows.first.include?("confidence"), "CSV header must include confidence"
    assert rows.first.include?("notes"), "CSV header must include notes"
    # Header width matches data row width — guards against silent column drift.
    require "csv"
    header_count = CSV.parse_line(rows.first).size
    assert_equal header_count, CSV.parse_line(rows[1]).size,
                 "data row column count must equal header column count"
    # @safe + @pii are the only sfields on @sobject → 2 data rows.
    field_rows = rows[1..]
    assert_equal 2, field_rows.size
    assert field_rows.any? { |r| r.include?("Account") && r.include?("Name") }
    assert field_rows.any? { |r| r.include?("Account") && r.include?("Email") }
  end

  test "show responds to .csv with only this object's fields" do
    other = Sobject.create!(extraction_run: @run, api_name: "Other", raw_describe: {})
    Sfield.create!(sobject: other, api_name: "OtherField", data_type: "string", sensitivity: "safe", raw_describe: {})

    sign_in(@analyst)
    get object_path(@sobject.api_name, run: @run.id, format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    rows = response.body.lines
    field_rows = rows[1..]
    # Only @safe + @pii belong to @sobject; "Other" sobject's field must NOT appear.
    assert_equal 2, field_rows.size
    refute field_rows.any? { |r| r.include?("OtherField") },
           "CSV for /objects/Account.csv must not leak fields from other objects"
  end

  test "index CSV respects active filters (custom + sensitivity)" do
    custom_with_pii = Sobject.create!(extraction_run: @run, api_name: "CustomPii__c", custom: true, raw_describe: {})
    Sfield.create!(sobject: custom_with_pii, api_name: "Email__c", data_type: "email", sensitivity: "pii", raw_describe: {})
    Sobject.create!(extraction_run: @run, api_name: "CustomSafe__c", custom: true, raw_describe: {}).tap do |s|
      Sfield.create!(sobject: s, api_name: "Plain__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    end

    sign_in(@analyst)
    post select_run_path(@run)
    get objects_path(custom: "1", sensitivity: "pii", format: :csv)

    rows = response.body.lines
    field_rows = rows[1..]
    assert field_rows.any? { |r| r.include?("CustomPii__c") }
    refute field_rows.any? { |r| r.include?("CustomSafe__c") }
    refute field_rows.any? { |r| r.include?("Account") },
           "Standard object Account must be excluded when custom=1"
  end

  test "field action returns just the frame for a Turbo Frame request" do
    sign_in(@analyst)
    get field_object_path(@sobject.api_name, field_name: @safe.api_name, run: @run.id),
        headers: { "Turbo-Frame" => "detail_sfield_#{@safe.id}" }
    assert_response :success
    assert_match(/turbo-frame[^>]+id="detail_sfield_#{@safe.id}"/, response.body)
    assert_match("Name", response.body)
    # Frame request means no app layout (no nav, no <html>).
    refute_match(/<html/, response.body, "Turbo Frame request must skip the app layout")
  end

  test "field action renders standalone page with breadcrumb on direct access" do
    sign_in(@analyst)
    get field_object_path(@sobject.api_name, field_name: @safe.api_name, run: @run.id)
    assert_response :success
    # Direct access → full page with app layout.
    assert_match(/<html/, response.body)
    # Breadcrumb shows the run + object path.
    assert_match(@run.directory_token, response.body)
    assert_match("Name", response.body)
  end

  test "field action exposes prev/next links to alphabetical neighbors" do
    # Add a third field so we get both prev and next for the middle one.
    middle = Sfield.create!(sobject: @sobject, api_name: "Middle", data_type: "string", sensitivity: "safe", raw_describe: {})
    sign_in(@analyst)
    get field_object_path(@sobject.api_name, field_name: middle.api_name, run: @run.id)
    assert_response :success
    # Alphabetical order on @sobject is: Email, Middle, Name. So prev=Email, next=Name.
    assert_match(/← Email/, response.body)
    assert_match(/Name →/, response.body)
    # Prev/next links must escape any containing frame (data-turbo-frame="_top").
    assert_match(/data-turbo-frame="_top"/, response.body)
  end

  test "field action disables prev link on first field, next link on last" do
    sign_in(@analyst)
    # @safe (Name) is alphabetically AFTER @pii (Email), so it's the last field.
    get field_object_path(@sobject.api_name, field_name: @safe.api_name, run: @run.id)
    assert_response :success
    # Last field: prev exists (Email), next is disabled.
    assert_match(/← Email/, response.body)
    assert_match(/cursor-not-allowed[^>]*>next →/, response.body)
  end

  test "field action disables prev link on the first field of an sobject" do
    sign_in(@analyst)
    # @pii (Email) is alphabetically BEFORE @safe (Name), so it's the first field.
    get field_object_path(@sobject.api_name, field_name: @pii.api_name, run: @run.id)
    assert_response :success
    assert_match(/cursor-not-allowed[^>]*>← prev/, response.body)
    assert_match(/Name →/, response.body)
  end

  test "field action disables both prev and next on a single-field sobject" do
    solo_sobject = Sobject.create!(extraction_run: @run, api_name: "Solo", raw_describe: {})
    solo_field = Sfield.create!(sobject: solo_sobject, api_name: "OnlyField", data_type: "string", sensitivity: "safe", raw_describe: {})

    sign_in(@analyst)
    get field_object_path(solo_sobject.api_name, field_name: solo_field.api_name, run: @run.id)
    assert_response :success
    assert_match(/cursor-not-allowed[^>]*>← prev/, response.body)
    assert_match(/cursor-not-allowed[^>]*>next →/, response.body)
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

  test "show renders type-filter chips when fields have >1 distinct data_type" do
    sign_in(@analyst)
    get object_path(@sobject.api_name, run: @run.id)
    assert_response :success
    # @sobject has @safe (string) and @pii (email) — 2 distinct types → chips render
    assert_match(/data-controller="type-filter"/, response.body)
    assert_match(/data-type-value="string"/, response.body)
    assert_match(/data-type-value="email"/, response.body)
    assert_match(/data-type-value="all"/, response.body)
  end

  test "show suppresses type-filter chips when there's only one data_type" do
    one_type_sobject = Sobject.create!(extraction_run: @run, api_name: "OneType", raw_describe: {})
    2.times { |i| Sfield.create!(sobject: one_type_sobject, api_name: "F#{i}", data_type: "string", sensitivity: "safe", raw_describe: {}) }

    sign_in(@analyst)
    get object_path(one_type_sobject.api_name, run: @run.id)
    assert_response :success
    # The type-filter controller wrapper still renders, but the chip row is omitted.
    refute_match(/data-type-value="all"/, response.body)
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
