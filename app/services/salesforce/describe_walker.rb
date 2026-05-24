module Salesforce
  # BFS walker over Salesforce describe payloads. Starts at `seed_objects` and
  # crosses reference fields outward until either max_hops is exceeded or the
  # next hop falls outside the configured allowlists.
  #
  # An edge is followed only if both endpoints satisfy
  #
  #     (object.namespacePrefix ∈ namespace_allowlist)
  #     OR  (object.api_name      ∈ standard_allowlist)
  #
  # The gateway object that exposes an out-of-scope lookup is itself visited;
  # the off-scope target is not. Self-references and diamond merges do not
  # cause extra describes — each object is described at most once.
  class DescribeWalker
    Result = Struct.new(:visited, :edges, :describes, :partial_failures, keyword_init: true)

    def initialize(client:, seed_objects:, namespace_allowlist:, standard_allowlist:, max_hops:)
      @client = client
      @seed_objects = Array(seed_objects).uniq
      @namespace_allowlist = Array(namespace_allowlist)
      @standard_allowlist = Array(standard_allowlist).to_set
      @max_hops = max_hops.to_i
    end

    def walk
      visited = {}
      edges = []
      describes = {}
      partial_failures = []

      queue = @seed_objects.map { |name| [ name, 0 ] }

      until queue.empty?
        api_name, depth = queue.shift
        next if visited.key?(api_name)

        # Per-object rescue: a single inaccessible managed-package object
        # (FLS denied, deleted between listing and describe, transient 5xx)
        # must not abort the entire walk. The caller records each failure
        # as a partial failure on the run and continues.
        payload = begin
          @client.describe(api_name)
        rescue StandardError => e
          partial_failures << { object_api_name: api_name, reason: "describe failed: #{e.class}: #{e.message}" }
          next
        end

        describes[api_name] = payload
        visited[api_name] = true

        next if depth >= @max_hops

        Array(payload["fields"]).each do |field|
          next unless field["type"] == "reference"

          Array(field["referenceTo"]).each do |target|
            edges << { source: api_name, target: target, field: field["name"] }
            next if visited.key?(target)
            next unless target_in_scope?(target, describes[target])

            queue << [ target, depth + 1 ]
          end
        end
      end

      # Filter edges so we only keep those whose target was actually visited;
      # otherwise the "gateway only" rule (out-of-scope target → not visited)
      # would leak dead edges. This also makes diff between runs cleaner.
      kept_edges = edges.select { |e| visited.key?(e[:target]) }

      Result.new(visited: visited.keys, edges: kept_edges, describes: describes, partial_failures: partial_failures)
    end

    private

    def target_in_scope?(api_name, maybe_payload)
      # Standard allowlist is an explicit yes — check it first since it's free.
      return true if @standard_allowlist.include?(api_name)

      # Without a describe payload yet, infer namespace from naming convention.
      # Custom objects look like `pkg__Object__c`. Standard objects have no
      # double-underscore prefix. This lets us decide whether to even fetch
      # the describe at all.
      inferred_namespace = api_name.include?("__") ? api_name.split("__", 2).first : nil
      @namespace_allowlist.include?(inferred_namespace)
    end
  end
end
