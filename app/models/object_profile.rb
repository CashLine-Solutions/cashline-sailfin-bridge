class ObjectProfile < ApplicationRecord
  STATUSES = %w[pending complete failed].freeze

  belongs_to :extraction_run
  belongs_to :sobject
  has_many :field_profiles, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }

  # Broadcast the parent run's panel when this profile's status changes so
  # the live progress strip refreshes. Intermediate updates (record_count,
  # sampled) don't fire — only the pending → complete/failed transitions.
  # Per-object that's 1 broadcast at create + 1 at completion.
  after_create_commit :broadcast_run_panel
  after_update_commit :broadcast_run_panel, if: :saved_change_to_status?

  private

  def broadcast_run_panel
    return unless extraction_run&.user_id
    extraction_run.broadcast_replace_to(
      [extraction_run, extraction_run.user],
      target: ActionView::RecordIdentifier.dom_id(extraction_run, :panel),
      partial: "runs/panel",
      locals: { run: extraction_run }
    )
  rescue StandardError => e
    Rails.logger.warn("[ObjectProfile] broadcast failed: #{e.class}: #{e.message}")
  end
end
