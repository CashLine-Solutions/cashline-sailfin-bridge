require "test_helper"

class ResolutionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @analyst = User.create!(email_address: "analyst@example.com", password: "secret-pass-1", role: :analyst)
    @run = ExtractionRun.create!(
      api_version: "62.0", include_sensitive: false,
      user: @analyst, status: "complete", completed_at: Time.current
    )
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account", label: "Account", raw_describe: {})
    @sfield  = Sfield.create!(sobject: @sobject, api_name: "AccountNumber", data_type: "string", sensitivity: "safe", raw_describe: {})

    @schema = {
      "classes" => [
        { "class_name" => "Customer::Account",
          "columns" => [
            { "name" => "account_number", "type" => "string" },
            { "name" => "status",         "type" => "string" }
          ],
          "associations" => [] }
      ]
    }
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: @schema)
  end

  def sign_in(user)
    sign_in_as(user)
  end

  test "by_target renders the coverage grid with cashline columns" do
    sign_in(@analyst)
    post select_run_path(@run)
    get resolutions_by_target_path
    assert_response :success
    assert_match "Customer::Account", response.body
    assert_match "account_number",    response.body
    assert_match "status",            response.body
  end

  test "by_source renders the Sailfin-fate grid for every field in the run" do
    sign_in(@analyst)
    post select_run_path(@run)
    get resolutions_by_source_path
    assert_response :success
    assert_match "Account",         response.body
    assert_match "AccountNumber",   response.body
  end

  test "by_target filters by status" do
    sign_in(@analyst)
    post select_run_path(@run)
    # Commit one entry so Customer::Account.account_number is FILLED, the rest UNTOUCHED.
    MappingEntry.create!(
      cashline_snapshot: @snapshot, source_field: @sfield,
      target_class: "Customer::Account", target_field: "account_number",
      mapping_type: "direct", reviewed: true
    )
    get resolutions_by_target_path(status: "untouched")
    assert_response :success
    assert_match "status",       response.body
    refute_match "account_number\</td>", response.body
  end

  test "by_source surfaces the committed target as a chip" do
    sign_in(@analyst)
    post select_run_path(@run)
    MappingEntry.create!(
      cashline_snapshot: @snapshot, source_field: @sfield,
      target_class: "Customer::Account", target_field: "account_number",
      mapping_type: "direct", reviewed: true
    )
    get resolutions_by_source_path
    assert_response :success
    assert_match "Customer::Account.account_number", response.body
  end

  test "accept_candidate commits the top LLM proposal as a MappingEntry" do
    sign_in(@analyst)
    post select_run_path(@run)
    MappingProposal.create!(
      cashline_snapshot: @snapshot, source_field: @sfield,
      target_class: "Customer::Account", target_field: "account_number",
      score: 2.5, state: "open",
      signals: { "llm" => 0.95, "lexical" => 0.8 }
    )
    assert_difference -> { MappingEntry.count } => 1 do
      post resolutions_accept_candidate_path,
        params: { snapshot: @snapshot.id, target_class: "Customer::Account", target_field: "account_number" }
    end
    entry = MappingEntry.order(:id).last
    assert_equal "direct", entry.mapping_type
    assert_equal "high",   entry.confidence
    assert entry.reviewed?
    assert_includes entry.transformation_note.to_s, "Accepted top LLM candidate"
  end

  test "accept_candidate alerts when no candidate exists" do
    sign_in(@analyst)
    post select_run_path(@run)
    assert_no_difference -> { MappingEntry.count } do
      post resolutions_accept_candidate_path,
        params: { snapshot: @snapshot.id, target_class: "Customer::Account", target_field: "account_number" }
    end
    follow_redirect!
    assert_match "No candidate available", response.body
  end

  test "accept_candidate ignores suppressed candidates" do
    sign_in(@analyst)
    post select_run_path(@run)
    MappingProposal.create!(
      cashline_snapshot: @snapshot, source_field: @sfield,
      target_class: "Customer::Account", target_field: "account_number",
      score: 2.5, state: "open",
      signals: { "llm" => 0.95, "disambig_suppressed" => true }
    )
    assert_no_difference -> { MappingEntry.count } do
      post resolutions_accept_candidate_path,
        params: { snapshot: @snapshot.id, target_class: "Customer::Account", target_field: "account_number" }
    end
  end

  test "by_target row links include the target_class/target_field filter" do
    sign_in(@analyst)
    post select_run_path(@run)
    get resolutions_by_target_path
    assert_response :success
    assert_match "target_class=Customer", response.body
    assert_match "target_field=account_number", response.body
  end

  test "mappings#index honors the target_class/target_field filter" do
    sign_in(@analyst)
    post select_run_path(@run)
    other = Sfield.create!(sobject: @sobject, api_name: "OtherField__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    MappingProposal.create!(
      cashline_snapshot: @snapshot, source_field: @sfield,
      target_class: "Customer::Account", target_field: "account_number",
      score: 2.0, state: "open", signals: { "llm" => 0.9 }
    )
    get mappings_path(snapshot: @snapshot.id, target_class: "Customer::Account", target_field: "account_number")
    assert_response :success
    assert_match "AccountNumber",  response.body
    refute_match "OtherField__c",  response.body
  end
end
