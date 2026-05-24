class ErdsController < ApplicationController
  before_action :load_run
  after_action :verify_authorized, only: [ :show ]
  after_action :verify_policy_scoped, only: [ :index ]

  def index
    if @run.nil?
      @clusters = policy_scope(Cluster.none)
      return
    end
    ensure_clusters!
    @clusters = policy_scope(Cluster.where(extraction_run: @run).includes(:sobjects)).order(:name)
  end

  def show
    if @run.nil?
      skip_authorization
      return head :not_found
    end
    ensure_clusters!
    @cluster = Cluster.where(extraction_run: @run).find { |c| c.slug == params[:slug] } ||
               Cluster.where(extraction_run: @run).find_by(id: params[:slug])
    if @cluster.nil?
      skip_authorization
      return head :not_found
    end
    authorize @cluster, :show?
    @mermaid_source = Ontology::MermaidRenderer.for_cluster(@cluster)
    respond_to do |format|
      format.html
      format.mmd { send_data @mermaid_source, filename: "#{@cluster.slug}.mmd", type: "text/plain" }
    end
  end

  private

  def load_run
    @run = current_run
  end

  def ensure_clusters!
    return unless @run
    return if @run.clusters.exists?
    Ontology::ClusterPersister.compute_and_persist!(@run) if @run.sobjects.exists?
  end
end
