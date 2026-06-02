module Mapping
  # Resolves many-to-one suggestion collisions. When one cashline target field is
  # the top suggestion for several Sailfin source fields, one Opus call (per
  # contested target) picks the single best source; the suggestion is then
  # suppressed on the losers (signals["disambig_suppressed"] = true) so the grid
  # shows it only on the winner. Run after the per-field adjudication.
  class LlmDisambiguator
    def initialize(snapshot:, client: nil)
      @snapshot = snapshot
      @client = client || Anthropic::Messages.new
      @dossier = Dossier.new(snapshot: snapshot)
    end

    def available?
      @client.available?
    end

    # Returns the number of contested targets resolved, or false if unavailable.
    def resolve!(run)
      return false unless available?
      contested = contested_targets(run)
      contested.each { |(tc, tf), proposals| resolve_one(tc, tf, proposals) }
      contested.size
    end

    private

    # { [target_class, target_field] => [winning-candidate proposal per source] }
    # for targets that more than one source field currently leads with.
    def contested_targets(run)
      top_proposal_per_field(run)
        .group_by { |p| [ p.target_class, p.target_field ] }
        .select { |_, proposals| proposals.size > 1 }
    end

    # Only the LLM's *chosen* pick per field competes — disambiguation resolves
    # collisions among confident matches, not raw heuristic/embedding leftovers
    # (which would suppress un-adjudicated fields and burn calls run-wide).
    def top_proposal_per_field(run)
      field_ids = Sfield.joins(:sobject).where(sobjects: { extraction_run_id: run.id }).select(:id)
      MappingProposal.open.for_session(@snapshot.id)
        .where(source_field_id: field_ids)
        .includes(source_field: :sobject)
        .order(score: :desc)
        .group_by(&:source_field_id)
        .filter_map { |_, proposals| proposals.reject { |p| p.signals["disambig_suppressed"] }.find { |p| p.signals["llm"].to_f > 0 } }
    end

    def resolve_one(target_class, target_field, proposals)
      ids = (0...proposals.size).map(&:to_s)
      result = @client.tool_call(
        system: system_prompt,
        user: user_prompt(target_class, target_field, proposals),
        tool: decision_tool(ids),
        cache_key: "mapping/disambiguator/v1"
      )
      winner = result["source_id"].to_s

      proposals.each_with_index do |proposal, idx|
        signals = (proposal.signals || {}).merge("disambig_suppressed" => (idx.to_s != winner))
        signals["disambig_reason"] = result["rationale"] if idx.to_s == winner && result["rationale"].present?
        proposal.update!(signals: signals)
      end
    end

    def decision_tool(ids)
      {
        name: "pick_best_source",
        description: "Pick the single Sailfin source field that best maps to the shared cashline target.",
        input_schema: {
          type: "object",
          properties: {
            source_id: { type: "string", enum: ids, description: "id of the winning source field" },
            rationale: { type: "string", description: "one sentence on why this source is the best fit" }
          },
          required: %w[source_id]
        }
      }
    end

    def system_prompt
      <<~SYS
        Several Sailfin source fields are all suggested to map onto the SAME cashline
        target field. Only one can own a direct mapping. Pick the single source field
        whose functional role best matches the target — weigh relationships, data
        distribution, and the role of the parent object, not name similarity.
        Respond only by calling the pick_best_source tool.
      SYS
    end

    def user_prompt(target_class, target_field, proposals)
      target = @dossier.target(target_class, target_field)
      sources = proposals.each_with_index.map do |proposal, i|
        "### source #{i}\n#{@dossier.render(@dossier.source(proposal.source_field))}"
      end
      <<~USR
        CASHLINE TARGET:
        #{target ? @dossier.render(target) : "#{target_class}.#{target_field}"}

        COMPETING SOURCE FIELDS (pick the best by id):
        #{sources.join("\n\n")}
      USR
    end
  end
end
