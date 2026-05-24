module Ontology
  # In-memory graph for a single extraction run. Used by ModularityClusterer
  # and the force-directed graph view. Edges deduplicate by (source, target):
  # multiple lookups from a single object to the same target collapse to one
  # undirected edge; polymorphic refs surface as separate edges only when the
  # target sobject differs.
  class RelationshipGraph
    Edge = Struct.new(:source_id, :target_id, :polymorphic, keyword_init: true)
    Result = Struct.new(:nodes, :edges, :adjacency, keyword_init: true) do
      def neighbors(node_id)
        adjacency[node_id] || []
      end
    end

    def self.build(extraction_run)
      sobjects = Sobject.where(extraction_run: extraction_run).to_a
      node_ids = sobjects.map(&:id).to_set

      rels = Srelationship
              .where(extraction_run: extraction_run)
              .where.not(target_sobject_id: nil)
              .pluck(:source_sobject_id, :target_sobject_id, :polymorphic)

      edges = []
      seen_pairs = Set.new
      rels.each do |src, tgt, poly|
        next if src == tgt
        next unless node_ids.include?(src) && node_ids.include?(tgt)
        key = [ src, tgt ].minmax
        next if seen_pairs.include?(key)
        seen_pairs << key
        edges << Edge.new(source_id: src, target_id: tgt, polymorphic: poly)
      end

      adjacency = Hash.new { |h, k| h[k] = [] }
      edges.each do |e|
        adjacency[e.source_id] << e.target_id
        adjacency[e.target_id] << e.source_id
      end

      Result.new(nodes: sobjects, edges: edges, adjacency: adjacency)
    end
  end
end
