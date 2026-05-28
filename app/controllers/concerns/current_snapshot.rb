# Lean v1 of cashline-snapshot selection: resolve an active snapshot from
# `?snapshot=` (policy-gated) else the most recent one, nil-safe. There is
# exactly one snapshot until the cashline schema first changes, so the full
# ActiveRun-style session storage + selection UI + nav badge is deferred to
# Unit 3b (gated on a second snapshot existing). Mirror ActiveRun when building
# that out.
module CurrentSnapshot
  extend ActiveSupport::Concern

  included do
    helper_method :current_snapshot, :current_snapshot_id, :current_snapshot_url_param
    before_action :set_active_snapshot_from_param
  end

  private

  def set_active_snapshot_from_param
    return if params[:snapshot].blank?
    snapshot = CashlineSnapshot.find_by(id: params[:snapshot])
    return unless snapshot
    # Gate the param the same way ActiveRun gates ?run= — a query param can't
    # bypass the policy. Fall through to the default if not viewable.
    return unless CashlineSnapshotPolicy.new(Current.user, snapshot).show?
    @active_snapshot_override = snapshot
  end

  def current_snapshot
    return @active_snapshot_override if defined?(@active_snapshot_override) && @active_snapshot_override
    @current_snapshot ||= load_current_snapshot
  end

  def load_current_snapshot
    candidate = CashlineSnapshot.current
    return nil if candidate.nil?
    return candidate if CashlineSnapshotPolicy.new(Current.user, candidate).show?
    nil
  end

  def current_snapshot_id
    current_snapshot&.id
  end

  def current_snapshot_url_param
    current_snapshot ? { snapshot: current_snapshot.id } : {}
  end
end
