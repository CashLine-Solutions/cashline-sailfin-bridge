module Ontology
  # Decides whether a profile job is allowed to collect the unsafe statistics
  # (top-N values, sample values) for a given Sfield. Re-checked at job time
  # — never trust the controller. See Unit 14 in the plan.
  #
  # The constructor takes the runtime context: the ExtractionRun (whose
  # `include_sensitive` flag must be true for any override) and the User who
  # triggered the run (whose `sensitive_data_access` flag must be true).
  # Either missing → deny.
  class ProfilingPolicy
    Decision = Struct.new(:allowed, :reason) do
      def allowed?
        allowed
      end
    end

    ALLOW_SAFE = Decision.new(true, "safe").freeze
    DENY_SENSITIVE_NO_OVERRIDE = Decision.new(false, "sensitive_field_without_override").freeze
    DENY_OVERRIDE_NO_RUN_FLAG = Decision.new(false, "sensitive_run_flag_missing").freeze
    DENY_OVERRIDE_NO_ROLE = Decision.new(false, "user_lacks_sensitive_data_access").freeze
    DENY_UNKNOWN_SENSITIVITY = Decision.new(false, "unknown_sensitivity").freeze

    def self.deny_all
      new(extraction_run: nil, user: nil)
    end

    def initialize(extraction_run:, user:)
      @run = extraction_run
      @user = user
    end

    def allow_sensitive_values?(sfield)
      case sfield.sensitivity
      when "safe"
        ALLOW_SAFE
      when "unknown_sensitivity"
        DENY_UNKNOWN_SENSITIVITY
      else
        sensitive_decision
      end
    end

    private

    def sensitive_decision
      return DENY_OVERRIDE_NO_RUN_FLAG unless @run && @run.include_sensitive
      return DENY_OVERRIDE_NO_ROLE unless @user && @user.respond_to?(:sensitive_data_access?) && @user.sensitive_data_access?

      Decision.new(true, "override_active")
    end
  end
end
