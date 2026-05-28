class VisualizationsController < ApplicationController
  before_action :load_run

  # Source fields whose edges are platform scaffolding rather than domain
  # relationships. Every Salesforce object has CreatedById / LastModifiedById /
  # OwnerId / RecordTypeId pointing at User / Group / RecordType, which
  # produces a hairball in the force-directed graph that hides the actual
  # data model. The graph view filters these out by default.
  SYSTEM_OWNER_FIELDS = %w[CreatedById LastModifiedById OwnerId RecordTypeId].freeze

  # Standard Salesforce platform objects that exist for identity, sharing,
  # approvals, content, and analytics — not for the Cashline domain. They're
  # tagged so the graph can hide them as a group; nothing prevents a user
  # from re-enabling them via the toggle.
  PLATFORM_API_NAMES = %w[
    User UserRole UserLicense Profile Group CollaborationGroup
    Organization Network Site Topic
    ApprovalSubmission ApprovalSubmissionDetail ApprovalWorkItem
    RecordType BusinessProcess ExternalDataSource
    Dashboard DashboardComponent Report
    ContentDocument ContentVersion ContentAsset ContentFolder
    ContentBody ContentWorkspace EnhancedLetterhead Image
    EmailTemplate EmailMessage OutgoingEmail ListEmail
    CallCenter ProfileSkill ProfileSkillUser ProfileSkillEndorsement
    WorkBadgeDefinition
  ].freeze

  def index
    if @run.nil?
      skip_authorization
      return
    end
    authorize @run, :show?
  end

  def data
    if @run.nil?
      skip_authorization
      return render(json: { nodes: [], clusters: [], edges: [], heatmap: [] })
    end
    authorize @run, :show?

    render json: { nodes: node_rows, clusters: cluster_rows, edges: edge_rows, heatmap: heatmap_rows }
  end

  private

  # One entry per sobject: the data point for the bubble chart.
  # `volume` is a record-count proxy — actual record_count when available,
  # otherwise the highest distinct_count seen across any field on the
  # object (typically the Id field, which gives an exact lower bound on
  # rows sampled). Falls back to 0 when no profile data exists.
  def node_rows
    sobjects = Sobject.where(extraction_run: @run).to_a
    cluster_by_sobject = ClusterAssignment
                          .joins(:cluster)
                          .where(clusters: { extraction_run_id: @run.id })
                          .pluck(:sobject_id, :cluster_id).to_h
    field_counts = Sfield.where(sobject_id: sobjects.map(&:id)).group(:sobject_id).count
    in_counts  = Srelationship.where(extraction_run: @run).where.not(target_sobject_id: nil).group(:target_sobject_id).count
    out_counts = Srelationship.where(extraction_run: @run).group(:source_sobject_id).count
    record_counts = ObjectProfile.where(extraction_run: @run).pluck(:sobject_id, :record_count).to_h
    distinct_proxy = FieldProfile
                       .joins(object_profile: :sobject)
                       .where(sobjects: { extraction_run_id: @run.id })
                       .group("sobjects.id")
                       .maximum(:distinct_count)

    sobjects.map do |so|
      volume = record_counts[so.id] || distinct_proxy[so.id] || 0
      {
        id: so.id,
        api_name: so.api_name,
        label: so.label,
        namespace: so.namespace_prefix.presence || "standard",
        custom: so.custom,
        platform: PLATFORM_API_NAMES.include?(so.api_name),
        cluster_id: cluster_by_sobject[so.id],
        field_count: field_counts[so.id] || 0,
        in_count: in_counts[so.id] || 0,
        out_count: out_counts[so.id] || 0,
        volume: volume.to_i,
        path: object_path(so.api_name, run: @run.id)
      }
    end
  end

  def edge_rows
    # We need the source field's api_name to classify each edge as system
    # scaffolding or domain. One join, plucked into tuples to keep memory low.
    Srelationship
      .where(extraction_run: @run)
      .where.not(target_sobject_id: nil)
      .joins("LEFT JOIN sfields ON sfields.id = srelationships.source_field_id")
      .pluck(:source_sobject_id, :target_sobject_id, :polymorphic, "sfields.api_name")
      .map do |src, tgt, poly, field_name|
        { source: src, target: tgt, polymorphic: poly,
          source_field: field_name,
          system: SYSTEM_OWNER_FIELDS.include?(field_name) }
      end
  end

  def cluster_rows
    @run.clusters.order(:name).map do |c|
      { id: c.id, name: c.name, color: c.color, size: c.cluster_assignments.size }
    end
  end

  # Field-fill density per sobject. For each sobject, return its top N fields
  # by fill rate (1 - null_rate). The Stimulus heatmap renders one row per
  # sobject; cell width is constant, cell colour comes from `fill` (0..1).
  # Sorted by total fill across all fields so the densest objects rise to
  # the top.
  HEATMAP_TOP_FIELDS = 60
  def heatmap_rows
    op_by_sobject = ObjectProfile.where(extraction_run: @run).index_by(&:sobject_id)
    sobjects = Sobject.where(extraction_run: @run).order(:api_name).to_a

    rows = sobjects.map do |so|
      op = op_by_sobject[so.id]
      next nil unless op
      fills = FieldProfile.joins(:sfield)
                          .where(object_profile_id: op.id)
                          .where.not(null_rate: nil)
                          .pluck(Arel.sql("sfields.api_name"), :null_rate)
                          .map { |name, nr| [ name, 1.0 - nr.to_f ] }
                          .sort_by { |_n, fill| -fill }
                          .first(HEATMAP_TOP_FIELDS)
      next nil if fills.empty?
      total = fills.sum { |_n, f| f }
      {
        api_name: so.api_name,
        cluster_id: ClusterAssignment.where(sobject_id: so.id)
                                     .joins(:cluster)
                                     .where(clusters: { extraction_run_id: @run.id })
                                     .pick(:cluster_id),
        cells: fills.map { |name, fill| { field: name, fill: fill.round(3) } },
        total_fill: total.round(2)
      }
    end.compact.sort_by { |r| -r[:total_fill] }
    rows
  end

  def load_run
    @run = current_run
  end
end
