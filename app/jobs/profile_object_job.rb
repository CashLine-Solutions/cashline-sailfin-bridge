class ProfileObjectJob < ApplicationJob
  queue_as :default

  if respond_to?(:good_job_control_concurrency_with)
    good_job_control_concurrency_with(
      total_limit: 4,
      key: -> { "profile_object:#{arguments.first}" }
    )
  end

  # Per-object profiling. Re-checks the ProfilingPolicy at job time against
  # the run flags and the triggering user — the controller cannot grant a
  # privilege the job's policy hasn't re-verified.
  def perform(sobject_id)
    sobject = Sobject.find(sobject_id)
    run = sobject.extraction_run

    user = run.user
    policy = Ontology::ProfilingPolicy.new(extraction_run: run, user: user)

    runner = build_runner
    runner.profile!(extraction_run: run, sobject: sobject, policy: policy)

    audit_override_if_used!(run: run, user: user, sobject: sobject)
  rescue StandardError => e
    run.record_partial_failure!(object_api_name: sobject.api_name, reason: e.message) if run
    raise
  end

  private

  # Seam for tests — override to inject a fake runner.
  def build_runner
    Salesforce::ProfileRunner.new(
      rest_client: Salesforce::ClientFactory.rest,
      tooling_client: Salesforce::ClientFactory.tooling
    )
  end

  def audit_override_if_used!(run:, user:, sobject:)
    return unless run.include_sensitive && user && user.sensitive_data_access?

    # We logged the override usage at the profile_runner layer via
    # FieldProfile#sensitive_override_used; record the run-level event here
    # so the audit trail makes it discoverable without a join.
    AuditEvent.record!(
      user: user,
      action: "profile_object.sensitive_override",
      subject: sobject,
      params: { extraction_run_id: run.id, sobject_api_name: sobject.api_name }
    )
  end
end
