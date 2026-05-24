class ExtractionRun < ApplicationRecord
  STATUSES = %w[queued extracting profiling complete complete_with_warnings failed].freeze
  SENSITIVE_RETENTION_DAYS = 30

  belongs_to :user, optional: true
  has_many :sobjects, dependent: :destroy
  has_many :srelationships, dependent: :destroy
  has_many :clusters, dependent: :destroy
  # Destroy profiles before sobjects so field_profiles → sfields foreign keys
  # are released first. Without this, run.destroy! fails when profiles exist.
  has_many :object_profiles, dependent: :destroy
  has_many :run_diffs_as_a, class_name: "RunDiff", foreign_key: :run_a_id, dependent: :destroy
  has_many :run_diffs_as_b, class_name: "RunDiff", foreign_key: :run_b_id, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :api_version, presence: true
  validates :directory_token, presence: true, uniqueness: true

  before_validation :assign_directory_token, on: :create
  before_validation :assign_default_retained_until, on: :create

  after_update_commit :broadcast_panel_update

  scope :sensitive, -> { where(include_sensitive: true) }
  scope :purgeable, -> { sensitive.where("retained_until IS NOT NULL AND retained_until < ?", Time.current) }

  STATUSES.each do |s|
    define_method("#{s}?") { status == s }
  end

  def mark_started!(limits_snapshot: nil)
    update!(status: "extracting", started_at: Time.current, limits_at_start: limits_snapshot)
  end

  def mark_complete!(limits_snapshot: nil, content_hash: nil)
    final_status = partial_failures.any? ? "complete_with_warnings" : "complete"
    update!(
      status: final_status,
      completed_at: Time.current,
      limits_at_end: limits_snapshot,
      content_hash: content_hash
    )
  end

  def mark_failed!(error)
    update!(status: "failed", completed_at: Time.current, error_message: error.to_s)
  end

  def record_partial_failure!(object_api_name:, reason:)
    self.partial_failures = partial_failures + [{ "object_api_name" => object_api_name, "reason" => reason }]
    save!
  end

  private

  def broadcast_panel_update
    return unless user_id
    return unless defined?(ActionCable) # Turbo Streams require ActionCable; test env may not load it
    broadcast_replace_to(
      [self, user],
      target: ActionView::RecordIdentifier.dom_id(self, :panel),
      partial: "runs/panel",
      locals: { run: self }
    )
  rescue StandardError => e
    Rails.logger.warn("[ExtractionRun] broadcast failed: #{e.class}: #{e.message}")
  end

  def assign_directory_token
    return if directory_token.present?
    # Format: 2026-05-24T13-38-22Z plus 4 hex chars to break ties when two runs
    # start in the same second (R20 — distinct directories per run).
    stamp = (started_at || Time.current).utc.strftime("%Y-%m-%dT%H-%M-%SZ")
    self.directory_token = "#{stamp}-#{SecureRandom.hex(2)}"
  end

  def assign_default_retained_until
    return unless include_sensitive
    return if retained_until.present?
    self.retained_until = SENSITIVE_RETENTION_DAYS.days.from_now
  end
end
