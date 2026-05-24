class ObjectProfile < ApplicationRecord
  STATUSES = %w[pending complete failed].freeze

  belongs_to :extraction_run
  belongs_to :sobject
  has_many :field_profiles, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  # Broadcast the parent run's panel when this profile's status changes so
  # the live progress strip refreshes. Throttled to at most one broadcast
  # per run per ~2 seconds (BROADCAST_THROTTLE_SECONDS) so a 100-object
  # extraction doesn't fire 100+ panel re-renders concurrently — each
  # broadcast triggers SQL queries (run.profile_progress) and consumes a
  # connection-pool slot, which during heavy profile fan-out saturates
  # the pool and breaks unrelated page loads with "Failed to fetch".
  BROADCAST_THROTTLE_SECONDS = 2.0

  after_create_commit :broadcast_run_panel_throttled
  after_update_commit :broadcast_run_panel_throttled, if: :saved_change_to_status?

  private

  def broadcast_run_panel_throttled
    return unless extraction_run&.user_id
    return unless throttle_ok?
    broadcast_run_panel
  end

  def throttle_ok?
    key = "object_profile_broadcast:run:#{extraction_run_id}"
    last_at = Rails.cache.read(key)
    if last_at && (Time.current - last_at) < BROADCAST_THROTTLE_SECONDS
      false
    else
      Rails.cache.write(key, Time.current, expires_in: 1.minute)
      true
    end
  rescue StandardError
    # If the cache is unavailable for some reason, fall through and broadcast —
    # better an extra render than a stuck progress bar.
    true
  end

  def broadcast_run_panel
    extraction_run.broadcast_replace_to(
      [ extraction_run, extraction_run.user ],
      target: ActionView::RecordIdentifier.dom_id(extraction_run, :panel),
      partial: "runs/panel",
      locals: { run: extraction_run }
    )
  rescue StandardError => e
    Rails.logger.warn("[ObjectProfile] broadcast failed: #{e.class}: #{e.message}")
  end
end
