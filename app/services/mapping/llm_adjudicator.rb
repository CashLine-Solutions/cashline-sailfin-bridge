module Mapping
  # Stage 2 of retrieve -> rerank. The heuristic pass (ComputeMappingProposalsJob)
  # retrieves a candidate set per source field as open MappingProposals; this
  # reranks/adjudicates that set with an LLM reading the full role dossiers, then
  # writes an `llm` signal + rationale onto the chosen proposal and rescores so
  # the LLM's pick rises to the top.
  #
  # Cost: one LLM call per source field that has open proposals. Callers should
  # scope which fields run (see ComputeLlmAdjudicationJob / rake mapping:adjudicate)
  # since Opus over thousands of fields is expensive.
  #
  # Hallucination guard: candidate ids are an enum in the tool schema AND
  # validated against the supplied set; an unrecognized id is treated as NO_MATCH.
  # Position-bias guard: candidate order is shuffled per call (research: LLM
  # rerankers anchor on slot 1).
  class LlmAdjudicator
    W_LLM = 2.0
    TOP_K = 8

    def initialize(snapshot:, client: nil, top_k: TOP_K)
      @snapshot = snapshot
      @client = client || Anthropic::Messages.new
      @top_k = top_k
      @dossier = Dossier.new(snapshot: snapshot)
    end

    def available?
      @client.available?
    end

    # Adjudicate every source field in `run` that has open proposals. Returns the
    # number of fields adjudicated, or false if the client is unavailable.
    def combine!(run)
      return false unless available?
      source_fields(run).find_each.sum { |sf| adjudicate(sf) ? 1 : 0 }
    end

    # One Opus call per field: rerank its candidate set AND produce a functional-
    # role note + keep/need/discard disposition (persisted as a FieldAssessment).
    # Runs even with no candidates so every field gets a note + disposition.
    def adjudicate(sfield)
      shuffled = open_proposals(sfield).shuffle
      ids = (0...shuffled.size).map(&:to_s)
      result = @client.tool_call(
        system: system_prompt,
        user: user_prompt(sfield, shuffled),
        tool: decision_tool(ids)
      )
      apply_decision(sfield, shuffled, result)
      true
    end

    private

    def open_proposals(sfield)
      MappingProposal
        .where(source_field_id: sfield.id, cashline_snapshot_id: @snapshot.id, state: "open")
        .order(score: :desc)
        .limit(@top_k)
        .to_a
    end

    def apply_decision(sfield, shuffled, result)
      chosen = result["target_id"].to_s
      confidence = result["confidence"].to_f

      shuffled.each_with_index do |proposal, idx|
        is_chosen = (idx.to_s == chosen)
        signals = (proposal.signals || {}).merge("llm" => is_chosen ? confidence : 0.0)
        if is_chosen
          signals["llm_rationale"] = result["rationale"]
          signals["llm_evidence"] = Array(result["evidence"]).presence
        end
        proposal.update!(signals: signals.compact, score: rescore(signals))
      end

      persist_assessment(sfield, result)
    end

    # Store the field-level note + disposition (covers fields with no proposal too).
    def persist_assessment(sfield, result)
      note = result["role_note"].presence
      disposition = result["disposition"].to_s.presence_in(FieldAssessment::DISPOSITIONS)
      return if note.nil? && disposition.nil?

      assessment = FieldAssessment.find_or_initialize_by(sfield_id: sfield.id, cashline_snapshot_id: @snapshot.id)
      assessment.role_note = note if note
      assessment.disposition = disposition if disposition
      assessment.disposition_reason = result["disposition_reason"].presence
      assessment.assessed_at = Time.current
      assessment.save!
    end

    def rescore(signals)
      (HeuristicMatcher::W_LEXICAL * signals["lexical"].to_f) +
        (signals["type"] ? HeuristicMatcher::W_TYPE : 0.0) +
        (HeuristicMatcher::W_PICKLIST * signals["picklist"].to_f) +
        signals.fetch("embedding", 0.0).to_f +
        (W_LLM * signals.fetch("llm", 0.0).to_f)
    end

    def decision_tool(ids)
      {
        name: "record_match",
        description: "Record the best-fit cashline target for the source field (or NO_MATCH), plus a role note and a keep/need/discard disposition.",
        input_schema: {
          type: "object",
          properties: {
            target_id: { type: "string", enum: ids + [ "NO_MATCH" ], description: "id of the chosen candidate, or NO_MATCH" },
            confidence: { type: "number", description: "0.0-1.0 confidence in the chosen match" },
            rationale: { type: "string", description: "one sentence on the functional-role reasoning for the match" },
            evidence: { type: "array", items: { type: "string" }, description: "the specific field attributes that drove the decision" },
            role_note: { type: "string", description: "one or two sentences describing the SOURCE field's functional role in Sailfin: what it stores and its part in the object's purpose" },
            disposition: { type: "string", enum: FieldAssessment::DISPOSITIONS, description: "keep = a candidate genuinely fits; need_in_cashline = no candidate fits but the field IS used (per its data stats) so cashline should add it; discard = no fit and the field is unused/vestigial" },
            disposition_reason: { type: "string", description: "one sentence justifying the disposition" }
          },
          required: %w[target_id confidence rationale role_note disposition]
        }
      }
    end

    def system_prompt
      examples = GoldSet.new.mapped.first(6).map { |e| "  #{e.source_object} -> #{e.targets.first}" }.join("\n")
      <<~SYS
        You map a Salesforce (Sailfin) accounts-receivable field onto the single
        best-fit field in a forward-looking "cashline" data model, choosing from a
        fixed candidate list.

        Decide on FUNCTIONAL ROLE, not name similarity. Weigh the field's
        relationships, data distribution, formula, picklist vocabulary, and the role
        of its parent object. A close name with the wrong role is a worse match than
        a different name with the right role. If none of the candidates is a genuine
        fit, return NO_MATCH rather than forcing one.

        Also produce:
        - role_note: one or two plain sentences on what the source field stores and
          its role in the object — the kind of note a data analyst would jot down.
        - disposition: keep / need_in_cashline / sync_reference / discard.
          * keep — a candidate genuinely fits (you chose one); map it to that real
            cashline field and use it going forward.
          * sync_reference — the field is a Sailfin-specific identifier, source key,
            or cross-reference (record IDs, association/junction IDs, external-system
            keys) that cashline should retain ONLY to map and sync data during the
            Sailfin migration. It is stored as a `sailfin_`-prefixed reference column,
            NOT adopted as cashline's own key, and is purged once Sailfin is shut
            down. (e.g. the id linking an Account to a Brand — keep it to bridge the
            data, but cashline mints its own mapping id.)
          * need_in_cashline — a genuine, lasting business capability that is
            actually USED in Sailfin (judge from data stats: low null rate, real
            distinct values, meaningful content) but has no cashline home. Treat this
            as a GAP to surface for cashline's own design: cashline will model the
            capability its own way, informed by operator interviews, NOT by copying
            Sailfin's field shape. Only used fields qualify — an unused field is
            `discard`, even if it belongs to a domain cashline plans to build fresh.
          * discard — unused or vestigial (mostly null, single/zero distinct values,
            or pure Salesforce administrative plumbing). Not worth carrying forward.

        Confirmed entity-level mappings, for orientation (source object -> cashline class):
        #{examples}

        Respond only by calling the record_match tool.
      SYS
    end

    def user_prompt(sfield, candidates)
      blocks = candidates.each_with_index.map do |proposal, i|
        target = @dossier.target(proposal.target_class, proposal.target_field)
        rendered = target ? @dossier.render(target) : "[cashline] #{proposal.target_class}.#{proposal.target_field} (no longer in snapshot)"
        "### candidate #{i}\n#{rendered}"
      end
      <<~USR
        SOURCE FIELD:
        #{@dossier.render(@dossier.source(sfield))}

        CANDIDATES (choose the best by id, or NO_MATCH):
        #{blocks.presence&.join("\n\n") || "(no candidate targets)"}
      USR
    end

    def source_fields(run)
      Sfield.joins(:sobject)
        .where(sobjects: { extraction_run_id: run.id })
        .where(id: MappingProposal.where(cashline_snapshot_id: @snapshot.id, state: "open").select(:source_field_id))
        .includes(:spicklist_values)
    end
  end
end
