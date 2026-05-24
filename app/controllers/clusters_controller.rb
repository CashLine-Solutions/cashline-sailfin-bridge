class ClustersController < ApplicationController
  before_action :load_run
  before_action :load_cluster, only: [ :rename, :assign, :reset ]
  after_action :verify_authorized

  def edit
    if @run.nil?
      authorize Cluster, :edit?
      @clusters = []
      return
    end
    authorize Cluster, :edit?
    @clusters = @run.clusters.includes(:sobjects).order(:name)
    @unassigned = @run.sobjects.where.not(id: ClusterAssignment.joins(:cluster).where(clusters: { extraction_run_id: @run.id }).select(:sobject_id))
  end

  def rename
    authorize @cluster
    if @cluster.update(name: params.require(:cluster).fetch(:name), user_modified: true)
      redirect_to edit_clusters_path(run: @run.id), notice: "Cluster renamed."
    else
      redirect_to edit_clusters_path(run: @run.id), alert: @cluster.errors.full_messages.to_sentence
    end
  end

  def assign
    authorize @cluster
    sobject_id = params.require(:sobject_id).to_i
    sobject = @run.sobjects.find_by(id: sobject_id)
    return head :not_found if sobject.nil?

    ActiveRecord::Base.transaction do
      ClusterAssignment.where(sobject_id: sobject.id).delete_all
      ClusterAssignment.create!(cluster: @cluster, sobject: sobject)
      @cluster.update!(user_modified: true)
    end
    redirect_to edit_clusters_path(run: @run.id), notice: "Object reassigned."
  end

  def reset
    authorize @cluster, :reset?
    Ontology::ClusterPersister.compute_and_persist!(@run, force: true)
    redirect_to edit_clusters_path(run: @run.id), notice: "Reset to auto-cluster."
  end

  private

  def load_run
    @run = current_run
  end

  def load_cluster
    @cluster = Cluster.find_by(id: params[:id])
    head :not_found if @cluster.nil? || @cluster.extraction_run_id != @run&.id
  end
end
