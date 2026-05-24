class DiffsController < ApplicationController
  before_action :load_runs_for_form, only: [:new, :create]
  before_action :load_diff, only: [:show]
  after_action :verify_authorized

  def new
    authorize RunDiff
  end

  def create
    authorize RunDiff
    @run_a = ExtractionRun.find_by(id: params[:run_a_id])
    @run_b = ExtractionRun.find_by(id: params[:run_b_id])

    return render_form_error("Pick two runs.", :unprocessable_entity) if @run_a.nil? || @run_b.nil?
    return render_form_error("Pick two different runs.", :unprocessable_entity) if @run_a.id == @run_b.id

    unless ExtractionRunPolicy.new(Current.user, @run_a).show? &&
           ExtractionRunPolicy.new(Current.user, @run_b).show?
      return render_form_error("You do not have permission to view one of those runs.", :forbidden)
    end

    record = ComputeDiffJob.new.perform(@run_a.id, @run_b.id)
    redirect_to diff_path(record), notice: "Diff computed (#{record.total_changes} change#{'s' unless record.total_changes == 1})."
  end

  def show
    if @diff.nil?
      skip_authorization
      return head :not_found
    end
    authorize @diff
    respond_to do |format|
      format.html
      format.md { send_data Ontology::DiffMarkdown.render(@diff), filename: filename_for(@diff), type: "text/markdown" }
    end
  end

  private

  def load_runs_for_form
    @runs = policy_scope(ExtractionRun).order(created_at: :desc).limit(50)
  end

  def load_diff
    @diff = RunDiff.find_by(id: params[:id])
  end

  def render_form_error(message, status)
    flash.now[:alert] = message
    @run_a ||= nil
    @run_b ||= nil
    render :new, status: status
  end

  def filename_for(diff)
    "diff_#{diff.run_a.directory_token}_to_#{diff.run_b.directory_token}.md"
  end
end
