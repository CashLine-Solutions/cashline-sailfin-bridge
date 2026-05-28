require "test_helper"

class MappingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @analyst = User.create!(email_address: "analyst@example.com", password: "secret-pass-1", role: :analyst)
    @analyst_pii = User.create!(email_address: "pii@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    @reader = User.create!(email_address: "reader@example.com", password: "secret-pass-1", role: :read_only)
    @admin = User.create!(email_address: "admin@example.com", password: "secret-pass-1", role: :admin, sensitive_data_access: true)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: false, user: @analyst, status: "complete", completed_at: Time.current)
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Account", label: "Account", raw_describe: {})
    @field = Sfield.create!(sobject: @sobject, api_name: "Invoice_Number__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    @other_field = Sfield.create!(sobject: @sobject, api_name: "Ref_Num__c", data_type: "string", sensitivity: "safe", raw_describe: {})
    @pii_field = Sfield.create!(sobject: @sobject, api_name: "SSN__c", data_type: "string", sensitivity: "pii", raw_describe: {})
    @profile = ObjectProfile.create!(extraction_run: @run, sobject: @sobject, status: "complete", record_count: 100, profiled_at: Time.current)
    FieldProfile.create!(object_profile: @profile, sfield: @field, null_rate: 0.1, distinct_count: 80, top_values: [], sample_values: [])

    @schema = JSON.parse(File.read(Rails.root.join("test/fixtures/files/cashline_snapshot.json")))
    @snapshot = CashlineSnapshot.create!(loaded_at: Time.current, sha256: "s", schema_json: @schema)
  end

  # Set the session cookie directly rather than POSTing credentials — the
  # SessionsController rate-limits #create, which trips after ~10 sign-ins
  # across a run and produces order-dependent auth failures.
  def sign_in(user)
    sign_in_as(user)
  end

  test "index lists every Sailfin field for the active run" do
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path
    assert_response :success
    assert_match "Invoice_Number__c", response.body
    assert_match "Account", response.body
  end

  test "target picklist contains the snapshot's classes/fields" do
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path(snapshot: @snapshot.id)
    assert_response :success
    assert_match "Invoice#invoice_number", response.body
    assert_match "Ingestion::Connector#kind", response.body
  end

  test "with no snapshot loaded the grid renders source-only with a load affordance" do
    CashlineSnapshot.delete_all
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path
    assert_response :success
    assert_match "Invoice_Number__c", response.body
    assert_match(/load a snapshot|cashline:load_snapshot/i, response.body)
    # No editable target datalist when there's no snapshot.
    refute_match "cashline-targets", response.body
  end

  test "a net_new row renders in the (no source) group" do
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: nil,
      target_class: "Invoice", target_field: "amount_cents", mapping_type: "net_new")
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path(snapshot: @snapshot.id)
    assert_response :success
    assert_match "(no source)", response.body
    assert_match "Invoice#amount_cents", response.body
  end

  test "an existing mapping renders its target on the field's row" do
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct")
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path(snapshot: @snapshot.id)
    assert_response :success
    assert_match "Invoice#invoice_number", response.body
  end

  test "no active run renders the empty state" do
    # No completable run for this user → ActiveRun resolves current_run to nil.
    @run.update!(status: "queued", completed_at: nil)
    sign_in(@analyst)
    get mappings_path
    assert_response :success
    assert_match(/No active Sailfin run/i, response.body)
  end

  test "requires authentication" do
    get mappings_path
    assert_response :redirect
  end

  # --- Unit 7: edit actions --------------------------------------------------

  test "setting a target on a synthetic row creates a direct mapping" do
    sign_in(@analyst)
    assert_difference -> { MappingEntry.count }, 1 do
      post mappings_path, params: { snapshot: @snapshot.id,
        mapping_entry: { source_field_id: @field.id, target: "Invoice#invoice_number" } }
    end
    entry = MappingEntry.last
    assert_equal "direct", entry.mapping_type
    assert_equal @field.id, entry.source_field_id
    assert_equal "Invoice", entry.target_class
    assert_equal "invoice_number", entry.target_field
    assert_not entry.reviewed?
  end

  test "toggling reviewed with no target persists a reviewed/no-target row" do
    sign_in(@analyst)
    post mappings_path, params: { snapshot: @snapshot.id,
      mapping_entry: { source_field_id: @field.id, target: "", reviewed: "1" } }
    entry = MappingEntry.find_by(source_field_id: @field.id)
    assert entry.reviewed?
    assert_nil entry.target_class
    assert entry.reviewed_no_home?
  end

  test "clearing a target on a reviewed row keeps the row instead of deleting it" do
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct", reviewed: true)
    sign_in(@analyst)
    assert_no_difference -> { MappingEntry.count } do
      patch mapping_path(entry), params: { mapping_entry: { target: "", reviewed: "1" } }
    end
    entry.reload
    assert_nil entry.target_class
    assert entry.reviewed?
  end

  test "an analyst cannot destroy a row but an admin can" do
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct")

    sign_in(@analyst)
    assert_no_difference -> { MappingEntry.count } do
      delete mapping_path(entry)
    end

    sign_in(@admin)
    assert_difference -> { MappingEntry.count }, -1 do
      delete mapping_path(entry)
    end
  end

  test "a concurrent double first-write produces one row, not two" do
    sign_in(@analyst)
    params = { snapshot: @snapshot.id, mapping_entry: { source_field_id: @field.id, target: "Invoice#invoice_number" } }
    post mappings_path, params: params
    post mappings_path, params: params
    assert_equal 1, MappingEntry.where(source_field_id: @field.id, target_class: "Invoice", target_field: "invoice_number").count
  end

  test "setting mapping_type=dropped on a PII field writes a sensitivity_downgrade audit event" do
    sign_in(@analyst)
    assert_difference -> { AuditEvent.where(action: "mapping.sensitivity_downgrade").count }, 1 do
      post mappings_path, params: { snapshot: @snapshot.id,
        mapping_entry: { source_field_id: @pii_field.id, target: "", mapping_type: "dropped" } }
    end
    event = AuditEvent.where(action: "mapping.sensitivity_downgrade").last
    assert_equal @pii_field.id, event.params["sfield_id"]
    assert_equal "dropped", event.params["new_mapping_type"]
  end

  test "dropping a non-sensitive field writes no downgrade audit" do
    sign_in(@analyst)
    assert_no_difference -> { AuditEvent.where(action: "mapping.sensitivity_downgrade").count } do
      post mappings_path, params: { snapshot: @snapshot.id,
        mapping_entry: { source_field_id: @field.id, target: "", mapping_type: "dropped" } }
    end
  end

  test "pointing a second source at an existing target surfaces N:1 and does not error" do
    first = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct")
    sign_in(@analyst)
    assert_difference -> { MappingEntry.count }, 1 do
      post mappings_path, params: { snapshot: @snapshot.id,
        mapping_entry: { source_field_id: @other_field.id, target: "Invoice#invoice_number" } }
    end
    second = MappingEntry.find_by(source_field_id: @other_field.id)
    assert_equal 1, second.also_mapped_from_count
    assert_equal 1, first.reload.also_mapped_from_count
  end

  test "split promotes the edge and adds a targeted leg" do
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct")
    sign_in(@analyst)
    assert_difference -> { MappingEntry.count }, 1 do
      post split_mapping_path(entry), params: { mapping_entry: { target: "Invoice#amount_cents" } }
    end
    assert_equal "split", entry.reload.mapping_type
    leg = MappingEntry.find_by(source_field_id: @field.id, target_field: "amount_cents")
    assert_equal "split", leg.mapping_type
  end

  # --- Unit 11a: filters + gap discovery -------------------------------------

  test "reviewed=no returns only unreviewed rows" do
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct", reviewed: true)
    sign_in(@analyst)
    post select_run_path(@run)

    get mappings_path(snapshot: @snapshot.id, reviewed: "no")
    assert_response :success
    refute_match "Invoice_Number__c", response.body # the reviewed field is excluded
    assert_match "Ref_Num__c", response.body         # an unreviewed synthetic field remains

    get mappings_path(snapshot: @snapshot.id, reviewed: "yes")
    assert_match "Invoice_Number__c", response.body
    refute_match "Ref_Num__c", response.body
  end

  test "gap-discovery filter returns reviewed high-population no-home fields and excludes never-reviewed" do
    # @field has a profile with null_rate 0.1 (90% populated) → high population.
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: nil, target_field: nil, mapping_type: nil, reviewed: true)
    sign_in(@analyst)
    post select_run_path(@run)

    get mappings_path(snapshot: @snapshot.id, gap: "1")
    assert_response :success
    assert_match "Invoice_Number__c", response.body  # reviewed, high-pop, no home
    refute_match "Ref_Num__c", response.body          # never reviewed → excluded
  end

  test "has_suggestion renders cleanly (empty) before any proposals exist" do
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path(snapshot: @snapshot.id, has_suggestion: "1")
    assert_response :success
    refute_match "Invoice_Number__c", response.body
    assert_match(/No fields to map/i, response.body)
  end

  test "combining chips intersects (reviewed=yes and mapped=no)" do
    # reviewed, no target → matches reviewed=yes AND mapped=no
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: nil, target_field: nil, mapping_type: nil, reviewed: true)
    # reviewed + mapped → excluded by mapped=no
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @pii_field,
      target_class: "Invoice", target_field: "status", mapping_type: "direct", reviewed: true)
    sign_in(@analyst)
    post select_run_path(@run)

    get mappings_path(snapshot: @snapshot.id, reviewed: "yes", mapped: "no")
    assert_response :success
    assert_match "Invoice_Number__c", response.body
    refute_match "SSN__c", response.body
  end

  test "turbo_stream create replaces the synthetic row" do
    sign_in(@analyst)
    post mappings_path,
      params: { snapshot: @snapshot.id, mapping_entry: { source_field_id: @field.id, target: "Invoice#invoice_number" } },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }
    assert_response :success
    assert_match "turbo-stream", response.body
    assert_match "mapping_synthetic_#{@field.id}", response.body
  end

  # --- Unit 12: CSV export ---------------------------------------------------

  test "an analyst can download the field CSV and it is audited" do
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct")
    sign_in(@analyst)
    assert_difference -> { AuditEvent.where(action: "mapping.field_csv_exported").count }, 1 do
      get mappings_path(format: :csv, snapshot: @snapshot.id)
    end
    assert_response :success
    assert_match "cashline_class", response.body
    assert_match "Invoice_Number__c", response.body
  end

  test "a read_only user cannot trigger either export" do
    sign_in(@reader)
    get mappings_path(format: :csv, snapshot: @snapshot.id)
    assert_response :forbidden
    get export_values_mappings_path(snapshot: @snapshot.id)
    assert_response :forbidden
  end

  test "an analyst without sensitive_data_access cannot download the value CSV" do
    sign_in(@analyst)
    get export_values_mappings_path(snapshot: @snapshot.id)
    assert_response :forbidden
  end

  test "an analyst without sensitive_data_access gets the field CSV with free-text blanked" do
    MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "invoice_number", mapping_type: "direct",
      transformation_note: "SECRETVALUE", source_citation: "SECRETCITE")
    sign_in(@analyst)
    get mappings_path(format: :csv, snapshot: @snapshot.id)
    assert_response :success
    refute_match "SECRETVALUE", response.body
    refute_match "SECRETCITE", response.body
  end

  test "an analyst with sensitive_data_access gets free-text columns and can download the value CSV" do
    entry = MappingEntry.create!(cashline_snapshot: @snapshot, source_field: @field,
      target_class: "Invoice", target_field: "status", mapping_type: "value_collapse",
      transformation_note: "VISIBLE_NOTE")
    MappingValueEntry.create!(mapping_entry: entry, source_value: "Open", target_enum_value: "draft")

    sign_in(@analyst_pii)
    get mappings_path(format: :csv, snapshot: @snapshot.id)
    assert_match "VISIBLE_NOTE", response.body

    assert_difference -> { AuditEvent.where(action: "mapping.value_csv_exported").count }, 1 do
      get export_values_mappings_path(snapshot: @snapshot.id)
    end
    assert_response :success
    assert_match "Open", response.body
  end

  # --- Unit 9: suggestions (heuristic proposals) -----------------------------

  def open_proposal(field: @field, target_field: "invoice_number", score: 1.5)
    MappingProposal.create!(source_field: field, cashline_snapshot: @snapshot,
      target_class: "Invoice", target_field: target_field, score: score, state: "open")
  end

  test "the grid renders an Accept button for an open suggestion" do
    open_proposal
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path(snapshot: @snapshot.id)
    assert_match "Invoice#invoice_number", response.body
    assert_match "Accept", response.body
  end

  test "accepting a suggestion persists the edge immediately" do
    proposal = open_proposal
    sign_in(@analyst)
    assert_difference -> { MappingEntry.count }, 1 do
      post accept_mapping_proposal_path(proposal)
    end
    entry = MappingEntry.find_by(source_field_id: @field.id, target_class: "Invoice", target_field: "invoice_number")
    assert_equal "direct", entry.mapping_type
    assert_equal "accepted", proposal.reload.state
  end

  test "rejecting a suggestion suppresses it and restoring re-opens it" do
    proposal = open_proposal
    sign_in(@analyst)
    post reject_mapping_proposal_path(proposal)
    assert_equal "rejected", proposal.reload.state

    post unreject_mapping_proposal_path(proposal)
    assert_equal "open", proposal.reload.state
  end

  test "has_suggestion filter returns only fields with an open proposal" do
    open_proposal
    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path(snapshot: @snapshot.id, has_suggestion: "1")
    assert_response :success
    assert_match "Invoice_Number__c", response.body
    refute_match "Ref_Num__c", response.body
  end

  test "terminal state: after the proposals job runs the grid shows the suggestion" do
    # Asserts the whole pipeline end-to-end (job persists proposals AND the grid
    # renders them) rather than only the job's unit behaviour — per the
    # documented missing-terminal-step gotcha.
    ComputeMappingProposalsJob.perform_now(@run.id, @snapshot.id)
    assert MappingProposal.open.where(cashline_snapshot_id: @snapshot.id, source_field_id: @field.id).exists?

    sign_in(@analyst)
    post select_run_path(@run)
    get mappings_path(snapshot: @snapshot.id)
    assert_response :success
    assert_match "Invoice#invoice_number", response.body
    assert_match "Accept", response.body
  end

  test "compute_suggestions is gated to analyst/admin and redirects" do
    sign_in(@reader)
    post compute_suggestions_mappings_path
    assert_response :forbidden

    sign_in(@analyst)
    post select_run_path(@run)
    post compute_suggestions_mappings_path(snapshot: @snapshot.id)
    assert_redirected_to mappings_path
  end
end
