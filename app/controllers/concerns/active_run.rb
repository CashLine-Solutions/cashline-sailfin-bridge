module ActiveRun
  extend ActiveSupport::Concern

  included do
    helper_method :current_run, :active_run_id, :current_run_url_param
    before_action :set_active_run_from_param
  end

  private

  def set_active_run_from_param
    return if params[:run].blank?
    run = ExtractionRun.find_by(id: params[:run])
    return unless run
    # Gate run binding through ExtractionRunPolicy so a ?run=<sensitive_id>
    # query param cannot bypass the sensitivity check that controllers
    # downstream rely on. If the user can't see this run, fall through to
    # the session/default lookup as if no param was provided.
    return unless ExtractionRunPolicy.new(Current.user, run).show?
    @active_run_override = run
  end

  def current_run
    return @active_run_override if defined?(@active_run_override) && @active_run_override
    @current_run ||= load_current_run
  end

  def load_current_run
    candidate = if session[:active_run_id].present?
                  ExtractionRun.find_by(id: session[:active_run_id])
    end
    candidate ||= viewable_runs.where(status: %w[complete complete_with_warnings]).order(completed_at: :desc).first
    return nil if candidate.nil?
    return candidate if ExtractionRunPolicy.new(Current.user, candidate).show?
    nil
  end

  def viewable_runs
    ExtractionRunPolicy::Scope.new(Current.user, ExtractionRun.all).resolve
  end

  def active_run_id
    current_run&.id
  end

  def current_run_url_param
    current_run ? { run: current_run.id } : {}
  end

  def select_active_run!(run)
    session[:active_run_id] = run.id
  end
end
