module Ontology
  # Greedy modularity-maximizing community detection.
  #
  # Starts with each node in its own cluster and iteratively merges the pair
  # of clusters with the largest modularity gain until no positive-gain merge
  # exists. O(n^2) per iteration; n is bounded by typical Sailfin org sizes
  # (~300 objects max), so the cost is acceptable.
  #
  # Disconnected nodes end up in singleton clusters.
  class ModularityClusterer
    def self.cluster(graph)
      new(graph).cluster
    end

    def initialize(graph)
      @graph = graph
    end

    def cluster
      nodes = @graph.nodes.map(&:id)
      edges = @graph.edges
      m = edges.size
      return wrap_singletons(nodes) if m.zero?

      degree = Hash.new(0)
      edges.each do |e|
        degree[e.source_id] += 1
        degree[e.target_id] += 1
      end

      # Each node starts as its own cluster.
      cluster_of = nodes.each_with_object({}) { |n, h| h[n] = n }
      members = nodes.each_with_object({}) { |n, h| h[n] = [ n ] }

      # Edge weight between cluster pairs (undirected; canonical key).
      cluster_edge_weight = Hash.new(0)
      edges.each do |e|
        c1, c2 = e.source_id, e.target_id
        next if c1 == c2
        key = [ c1, c2 ].minmax
        cluster_edge_weight[key] += 1
      end
      cluster_degree = degree.dup

      loop do
        best_pair = nil
        best_gain = 0.0
        cluster_edge_weight.each do |(c1, c2), w_ij|
          # Modularity gain for merging cluster pair: 2 * (w_ij / 2m - (deg(c1) * deg(c2)) / (2m)^2)
          d1 = cluster_degree[c1].to_f
          d2 = cluster_degree[c2].to_f
          q_gain = (w_ij.to_f / m) - (d1 * d2) / (2.0 * m * m)
          if q_gain > best_gain
            best_gain = q_gain
            best_pair = [ c1, c2 ]
          end
        end
        break if best_pair.nil?

        keep, drop = best_pair
        members[keep].concat(members[drop])
        members[drop].each { |n| cluster_of[n] = keep }
        members.delete(drop)
        cluster_degree[keep] += cluster_degree.delete(drop)

        # Recompute weights involving keep/drop.
        new_weights = {}
        cluster_edge_weight.each do |(c1, c2), w|
          next if [ c1, c2 ].include?(drop) && [ c1, c2 ].include?(keep)
          a = (c1 == drop ? keep : c1)
          b = (c2 == drop ? keep : c2)
          next if a == b
          k = [ a, b ].minmax
          new_weights[k] = (new_weights[k] || 0) + w
        end
        cluster_edge_weight = new_weights
      end

      members.values.map { |group| group.uniq }
    end

    private

    def wrap_singletons(nodes)
      nodes.map { |n| [ n ] }
    end
  end
end
