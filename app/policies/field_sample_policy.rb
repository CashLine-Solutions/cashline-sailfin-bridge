class FieldSamplePolicy < ApplicationPolicy
  # `record` is expected to be a Hash: { run:, sfield: }, mirroring the
  # call-site context. Pundit also accepts an Sfield directly and we
  # fall back to the field's run via association.
  def show_sample_values?
    return false if user.nil?

    run, sfield = extract_run_and_field
    return true if sfield.sensitivity.to_s == "safe"
    return false unless run&.include_sensitive
    user.sensitive_data_access?
  end

  private

  def extract_run_and_field
    if record.is_a?(Hash)
      [ record[:run], record[:sfield] ]
    else
      sfield = record
      run = sfield.sobject&.extraction_run
      [ run, sfield ]
    end
  end
end
