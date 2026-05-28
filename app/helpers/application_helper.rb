module ApplicationHelper
  STATUS_BADGE_CLASSES = {
    "queued" => "badge-neutral",
    "extracting" => "badge-info",
    "profiling" => "badge-info",
    "complete" => "badge-success",
    "complete_with_warnings" => "badge-warning",
    "failed" => "badge-danger"
  }.freeze

  SENSITIVITY_LABELS = {
    "safe" => "Safe",
    "pii" => "PII",
    "financial" => "Financial",
    "pii_and_financial" => "PII + Financial",
    "unknown_sensitivity" => "Unknown — pending classification"
  }.freeze

  def status_badge(status)
    classes = STATUS_BADGE_CLASSES.fetch(status, "badge-neutral")
    content_tag(:span, status.tr("_", " "), class: classes)
  end

  def sensitivity_label(sensitivity)
    SENSITIVITY_LABELS.fetch(sensitivity.to_s, sensitivity.to_s)
  end

  def sensitive_field?(sfield)
    sfield.sensitivity.to_s != "safe"
  end

  def can_view_sensitive_values?(run, user)
    return false if user.nil?
    return true unless run
    run.include_sensitive && user.sensitive_data_access?
  end

  def redacted_cell(sfield)
    content_tag(:span,
                class: "inline-flex items-center gap-1 text-slate-500",
                title: "Redacted for #{sensitivity_label(sfield.sensitivity)}. Requires sensitive_data_access role and a sensitive run.") do
      concat content_tag(:span, "lock", class: "text-xs")
      concat content_tag(:span, sensitivity_label(sfield.sensitivity), class: "text-xs italic")
    end
  end

  def time_ago_or_dash(time)
    return "—" if time.nil?
    "#{time_ago_in_words(time)} ago"
  end
end
