require "test_helper"

class ProfileObjectJobTest < ActiveJob::TestCase
  class FakeRunner
    def initialize(should_raise: false)
      @should_raise = should_raise
      @calls = []
    end
    attr_reader :calls

    def profile!(extraction_run:, sobject:, policy:)
      raise StandardError, "runner failure" if @should_raise
      @calls << { sobject: sobject.api_name, policy: policy }
      ObjectProfile.find_or_create_by!(extraction_run: extraction_run, sobject: sobject) do |op|
        op.status = "complete"
        op.profiled_at = Time.current
      end
    end
  end

  setup do
    @user = User.create!(email_address: "ops@example.com", password: "secret-pass-1", role: :analyst, sensitive_data_access: true)
    @run = ExtractionRun.create!(api_version: "62.0", include_sensitive: true, user: @user, seed_objects: %w[Account])
    @sobject = Sobject.create!(extraction_run: @run, api_name: "Contact", raw_describe: {})
    Sfield.create!(sobject: @sobject, api_name: "Email", data_type: "email", sensitivity: "pii", raw_describe: {})

    @runner = FakeRunner.new
  end

  test "profiles the sobject with a policy built from the run + user" do
    job = ProfileObjectJob.new
    job.define_singleton_method(:build_runner) { @stub }
    job.instance_variable_set(:@stub, @runner)

    job.perform(@sobject.id)

    assert_equal 1, @runner.calls.size
    policy = @runner.calls.first[:policy]
    assert_kind_of Ontology::ProfilingPolicy, policy
    assert policy.allow_sensitive_values?(@sobject.sfields.first).allowed?
  end

  test "records a partial failure when the runner raises" do
    job = ProfileObjectJob.new
    job.define_singleton_method(:build_runner) { @stub }
    job.instance_variable_set(:@stub, FakeRunner.new(should_raise: true))

    assert_raises(StandardError) { job.perform(@sobject.id) }
    @run.reload
    assert_equal 1, @run.partial_failures.size
  end

  test "writes an audit event when override is active and user has the role" do
    job = ProfileObjectJob.new
    job.define_singleton_method(:build_runner) { @stub }
    job.instance_variable_set(:@stub, @runner)

    assert_difference -> { AuditEvent.count }, 1 do
      job.perform(@sobject.id)
    end

    event = AuditEvent.order(:id).last
    assert_equal "profile_object.sensitive_override", event.action
    assert_equal @user.id, event.user_id
  end

  test "does not write an audit event for a non-sensitive run" do
    @run.update!(include_sensitive: false)
    job = ProfileObjectJob.new
    job.define_singleton_method(:build_runner) { @stub }
    job.instance_variable_set(:@stub, @runner)

    assert_no_difference -> { AuditEvent.count } do
      job.perform(@sobject.id)
    end
  end
end
