module Ontology
  # Computes clusters for an extraction run and persists them.
  # Idempotent: re-running drops user_modified=false clusters and recomputes.
  # If any cluster is user_modified, refuses to recompute unless force: true.
  class ClusterPersister
    PALETTE = %w[
      #2563eb #16a34a #db2777 #ca8a04 #7c3aed #ea580c #0891b2 #be123c #4d7c0f #6b21a8
    ].freeze

    def self.compute_and_persist!(extraction_run, force: false)
      new(extraction_run).compute_and_persist!(force: force)
    end

    def initialize(extraction_run)
      @run = extraction_run
    end

    def compute_and_persist!(force:)
      if @run.clusters.where(user_modified: true).exists? && !force
        return @run.clusters.to_a
      end

      graph = RelationshipGraph.build(@run)
      groups = ModularityClusterer.cluster(graph)

      ActiveRecord::Base.transaction do
        ClusterAssignment.joins(:cluster).where(clusters: { extraction_run_id: @run.id }).delete_all
        Cluster.where(extraction_run_id: @run.id).delete_all

        # Pre-load existing names into a Set so ensure_unique_name does in-memory
        # uniqueness checks instead of one EXISTS query per collision.
        @existing_names = Set.new

        groups.each_with_index do |sobject_ids, idx|
          next if sobject_ids.empty?
          biggest = Sobject.where(id: sobject_ids).order(api_name: :asc).first
          name = biggest&.label.presence || biggest&.api_name.presence || "Cluster #{idx + 1}"
          cluster_name = ensure_unique_name(name, idx)
          @existing_names << cluster_name
          cluster = Cluster.create!(
            extraction_run: @run,
            name: cluster_name,
            color: PALETTE[idx % PALETTE.size]
          )
          ClusterAssignment.insert_all!(sobject_ids.map { |sid| { cluster_id: cluster.id, sobject_id: sid, created_at: Time.current, updated_at: Time.current } })
        end
      end

      @run.clusters.reload.to_a
    end

    private

    def ensure_unique_name(base, idx)
      candidate = base
      n = 1
      while @existing_names.include?(candidate)
        n += 1
        candidate = "#{base} (#{n})"
        break if n > 50
      end
      candidate
    end
  end
end
