class GraphController < ApplicationController
  before_action :load_run

  def show
    if @run.nil?
      skip_authorization
    else
      authorize @run, :show?
    end
  end

  def data
    if @run.nil?
      skip_authorization
      return render(json: { nodes: [], edges: [] })
    end
    authorize @run, :show?

    sobjects = Sobject.where(extraction_run: @run).to_a
    cluster_by_sobject = ClusterAssignment.joins(:cluster).where(clusters: { extraction_run_id: @run.id }).pluck(:sobject_id, :cluster_id).to_h
    counts_by_id = ObjectProfile.where(extraction_run: @run).pluck(:sobject_id, :record_count).to_h

    nodes = sobjects.map do |so|
      {
        id: so.id,
        label: so.api_name,
        namespace: so.namespace_prefix.presence || "standard",
        cluster: cluster_by_sobject[so.id],
        record_count: counts_by_id[so.id],
        custom: so.custom
      }
    end

    edges = Srelationship
              .where(extraction_run: @run)
              .where.not(target_sobject_id: nil)
              .pluck(:source_sobject_id, :target_sobject_id, :polymorphic)
              .map { |src, tgt, poly| { source: src, target: tgt, polymorphic: poly } }

    render json: { nodes: nodes, edges: edges }
  end

  private

  def load_run
    @run = current_run
  end
end
