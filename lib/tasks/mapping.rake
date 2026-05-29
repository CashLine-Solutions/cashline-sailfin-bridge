namespace :mapping do
  def resolve_run_and_snapshot
    run = ENV["RUN"] ? ExtractionRun.find(ENV["RUN"]) : ExtractionRun.where(status: "complete").order(:id).last
    snapshot = ENV["SNAPSHOT"] ? CashlineSnapshot.find(ENV["SNAPSHOT"]) : CashlineSnapshot.current
    abort "No complete extraction run found" unless run
    abort "No cashline snapshot loaded" unless snapshot
    [ run, snapshot ]
  end

  # Escalate a field to the stronger model when the cheap tier was unsure
  # ("problem assessments") or the field is sensitive ("high-value").
  def escalate_field?(sfield, snapshot, threshold)
    fa = FieldAssessment.find_by(sfield_id: sfield.id, cashline_snapshot_id: snapshot.id)
    return true if fa.nil? # tier-1 produced nothing → let the strong model try
    sensitive = %w[financial pii pii_and_financial].include?(sfield.sensitivity.to_s)
    low_conf = fa.confidence.nil? || fa.confidence < threshold
    sensitive || low_conf
  end

  desc "Evaluate the matcher vs the gold set. RUN= SNAPSHOT= MODE=heuristic|proposals (default heuristic)"
  task eval: :environment do
    run, snapshot = resolve_run_and_snapshot
    matcher = ENV["MODE"] == "proposals" ? Mapping::ProposalCandidates.new(snapshot) : Mapping::HeuristicMatcher.new(snapshot: snapshot)

    puts "Matcher eval — run ##{run.id} vs snapshot ##{snapshot.id} — mode=#{ENV['MODE'] || 'heuristic'}"
    puts "=" * 78
    report = Mapping::Evaluator.new(run: run, snapshot: snapshot, matcher: matcher).call

    puts "\nMAPPED objects (does the right target class win?)"
    report[:mapped].each do |r|
      mark = r.hit_at_1 ? "P@1 ✓" : (r.hit_at_k ? "P@3 ~" : "miss ✗")
      ranked = r.ranked.map { |cls, score| "#{cls}(#{score.round(1)})" }.join(", ")
      puts "  [#{mark}] #{r.source_object}"
      puts "         gold: #{r.gold_targets.join(' | ')}"
      puts "         top#{r.ranked.size}: #{ranked}"
    end

    puts "\nNO-TARGET objects (should NOT get a confident home)"
    report[:no_target].each do |r|
      top = r.ranked.first
      flag = (r.top_score.to_f >= Mapping::Evaluator::FALSE_CONFIDENCE) ? "⚠ false-confident" : "ok (low conf)"
      puts "  [#{flag}] #{r.source_object} → #{top ? "#{top.first}(#{top.last.round(2)})" : '(none)'}"
    end

    puts "\n" + "=" * 78
    puts "precision@1:          #{report[:precision_at_1]}"
    puts "recall@3:             #{report[:recall_at_k]}"
    puts "false-confident gaps: #{report[:false_confident_gaps]}/#{report[:no_target].size}"
  end

  desc "Field-level precision@1/recall@3: heuristic vs embedding vs LLM on the field gold set. RUN= SNAPSHOT="
  task field_eval: :environment do
    run, snapshot = resolve_run_and_snapshot
    hm = Mapping::HeuristicMatcher.new(snapshot: snapshot)
    pc = Mapping::ProposalCandidates.new(snapshot)
    llm_on = Anthropic::ClientFactory.configured?

    resolved = Mapping::GoldSet.new.field_pairs.filter_map do |p|
      sf = Sfield.joins(:sobject).find_by(sobjects: { extraction_run_id: run.id, api_name: p.source_object }, api_name: p.source_field)
      sf && [ p, sf ]
    end
    fields = resolved.map(&:last)

    topk = ->(cands, k = 3) { cands.first(k).map { |c| "#{c[:target_class]}.#{c[:target_field]}" } }

    # Heuristic, read directly from the matcher.
    heur = resolved.to_h { |_, sf| [ sf.id, topk.call(hm.candidates_for(sf)) ] }

    # Embedding: repopulate heuristic proposals for these fields, merge embeddings.
    fields.each do |sf|
      MappingProposal.where(source_field_id: sf.id, cashline_snapshot_id: snapshot.id, state: "open").delete_all
      hm.candidates_for(sf).each do |c|
        next if MappingProposal.exists?(source_field_id: sf.id, cashline_snapshot_id: snapshot.id, target_class: c[:target_class], target_field: c[:target_field])
        MappingProposal.create!(source_field_id: sf.id, cashline_snapshot_id: snapshot.id,
          target_class: c[:target_class], target_field: c[:target_field], score: c[:score], signals: c[:signals], state: "open")
      end
    end
    Mapping::EmbeddingMatcher.new(snapshot: snapshot).combine!(run, fields: fields) if Openai::ClientFactory.configured?
    emb = resolved.to_h { |_, sf| [ sf.id, topk.call(pc.candidates_for(sf)) ] }

    # LLM: adjudicate each field, then re-read.
    llm = {}
    if llm_on
      adj = Mapping::LlmAdjudicator.new(snapshot: snapshot)
      fields.each { |sf| adj.adjudicate(sf) }
      llm = resolved.to_h { |_, sf| [ sf.id, topk.call(pc.candidates_for(sf)) ] }
    end

    hit1 = ->(list, targets) { list.first && targets.include?(list.first) }
    hitk = ->(list, targets) { (list & targets).any? }
    mark = ->(b) { b ? "✓" : "✗" }
    cols = llm_on ? %w[heur embed llm] : %w[heur embed]

    puts "Field-level eval — run ##{run.id} vs snapshot ##{snapshot.id} — #{resolved.size} pairs#{llm_on ? '' : ' (no Anthropic key → LLM skipped)'}"
    puts "=" * 78
    printf("%-48s %-6s %-6s %-6s\n", "source field", *cols)
    tallies = Hash.new(0)
    resolved.each do |p, sf|
      preds = { "heur" => heur[sf.id], "embed" => emb[sf.id], "llm" => llm[sf.id] }
      marks = cols.map do |c|
        h = hit1.call(preds[c], p.targets)
        tallies["#{c}_p1"] += 1 if h
        tallies["#{c}_r3"] += 1 if hitk.call(preds[c], p.targets)
        mark.call(h)
      end
      printf("%-48s %-6s %-6s %-6s\n", "#{p.source_object}.#{p.source_field}".last(48), *marks)
    end

    puts "=" * 78
    n = resolved.size
    puts "precision@1:  " + cols.map { |c| "#{c}=#{(tallies["#{c}_p1"].to_f / n).round(2)}" }.join("  ")
    puts "recall@3:     " + cols.map { |c| "#{c}=#{(tallies["#{c}_r3"].to_f / n).round(2)}" }.join("  ")
  end

  desc "Retrieve (heuristic) then LLM-rerank proposals. RUN= SNAPSHOT= OBJECTS=a,b FIELD_LIMIT=n (default: gold objects, all fields)"
  task adjudicate: :environment do
    run, snapshot = resolve_run_and_snapshot
    matcher = Mapping::HeuristicMatcher.new(snapshot: snapshot)
    adjudicator = Mapping::LlmAdjudicator.new(snapshot: snapshot)
    abort "Anthropic not configured — run `bin/rails credentials:edit` and add anthropic.api_key" unless adjudicator.available?

    names = ENV["OBJECTS"].present? ? ENV["OBJECTS"].split(",").map(&:strip) : Mapping::GoldSet.new.source_objects
    field_limit = ENV["FIELD_LIMIT"].to_i

    fields = names.flat_map do |name|
      obj = run.sobjects.find_by(api_name: name)
      next [] unless obj
      scope = obj.sfields.order(:api_name).includes(:spicklist_values)
      (field_limit > 0 ? scope.limit(field_limit) : scope).to_a
    end

    puts "Adjudicating #{fields.size} fields across #{names.size} objects — ~#{fields.size} LLM calls (model: #{Anthropic::Messages::DEFAULT_MODEL})"
    puts "=" * 78

    # Stage 1 — retrieval: (re)populate this field's open heuristic proposals.
    fields.each do |sf|
      MappingProposal.where(source_field_id: sf.id, cashline_snapshot_id: snapshot.id, state: "open").delete_all
      matcher.candidates_for(sf).each do |c|
        next if MappingProposal.rejected?(source_field_id: sf.id, target_class: c[:target_class], target_field: c[:target_field])
        next if MappingProposal.exists?(source_field_id: sf.id, cashline_snapshot_id: snapshot.id, target_class: c[:target_class], target_field: c[:target_field])
        MappingProposal.create!(source_field_id: sf.id, cashline_snapshot_id: snapshot.id,
          target_class: c[:target_class], target_field: c[:target_field], score: c[:score], signals: c[:signals], state: "open")
      end
    end

    # Stage 1b — embedding signal (retrieval enrichment) before the LLM rerank.
    Mapping::EmbeddingMatcher.new(snapshot: snapshot).combine!(run, fields: fields) if Openai::ClientFactory.configured?

    # Stage 2 — rerank + assess: LLM picks the target and writes a role note + disposition.
    done = 0
    fields.each_with_index do |sf, i|
      adjudicator.adjudicate(sf) && (done += 1)
      print(i % 50 == 49 ? "#{i + 1}\n" : ".")
    rescue Anthropic::Error, Faraday::Error => e
      run.record_partial_failure!(object_api_name: "adjudicate:#{sf.api_name}", reason: e.message)
      print "x"
    end
    puts "\nadjudicated #{done}/#{fields.size} fields."

    # Stage 3 — disambiguation: one winner per contested cashline target.
    contested = Mapping::LlmDisambiguator.new(snapshot: snapshot).resolve!(run)
    puts "disambiguated #{contested} contested target(s). Re-run `bin/rails mapping:eval MODE=proposals` to measure lift."
  end

  desc "Tiered full assessment: cheap model on every field, escalate uncertain/sensitive to Opus. RUN= SNAPSHOT= OBJECTS=a,b ESCALATE_BELOW=0.75 ESCALATE_MAX=800 RESUME=1"
  task assess: :environment do
    run, snapshot = resolve_run_and_snapshot
    threshold = (ENV["ESCALATE_BELOW"] || "0.75").to_f
    escalate_max = (ENV["ESCALATE_MAX"] || "800").to_i
    resume = ENV["RESUME"] == "1"

    matcher = Mapping::HeuristicMatcher.new(snapshot: snapshot)
    mini = Openai::Chat.new
    abort "OpenAI not configured (need openai.api_key) for the tier-1 pass" unless mini.available?
    opus_on = Anthropic::ClientFactory.configured?

    names = ENV["OBJECTS"].present? ? ENV["OBJECTS"].split(",").map(&:strip) : run.sobjects.order(:api_name).pluck(:api_name)
    fields = names.flat_map do |name|
      obj = run.sobjects.find_by(api_name: name)
      obj ? obj.sfields.order(:api_name).includes(:spicklist_values, :sobject).to_a : []
    end

    puts "Tiered assess — run ##{run.id} vs snapshot ##{snapshot.id} — #{fields.size} fields"
    puts "tier-1: #{mini.model}; escalate below conf #{threshold} (cap #{escalate_max})#{opus_on ? " to #{Anthropic::Messages::DEFAULT_MODEL}" : " — Opus NOT configured, tier-1 only"}"
    puts "=" * 78

    # Stage 1 — retrieval: heuristic proposals (free).
    fields.each do |sf|
      MappingProposal.where(source_field_id: sf.id, cashline_snapshot_id: snapshot.id, state: "open").delete_all
      matcher.candidates_for(sf).each do |c|
        next if MappingProposal.rejected?(source_field_id: sf.id, target_class: c[:target_class], target_field: c[:target_field])
        next if MappingProposal.exists?(source_field_id: sf.id, cashline_snapshot_id: snapshot.id, target_class: c[:target_class], target_field: c[:target_field])
        MappingProposal.create!(source_field_id: sf.id, cashline_snapshot_id: snapshot.id, target_class: c[:target_class], target_field: c[:target_field], score: c[:score], signals: c[:signals], state: "open")
      end
    end
    # Embedding enrichment is best-effort: a transient OpenAI hiccup must not
    # abort the whole assessment — tier-1 still runs on the heuristic candidates.
    begin
      Mapping::EmbeddingMatcher.new(snapshot: snapshot).combine!(run, fields: fields) if Openai::ClientFactory.configured?
      puts "retrieval done (heuristic + embeddings)."
    rescue StandardError => e
      puts "retrieval: embeddings skipped (#{e.class}: #{e.message}); proceeding heuristic-only."
    end

    # Stage 2 — tier-1: the cheap model assesses every field.
    mini_adj = Mapping::LlmAdjudicator.new(snapshot: snapshot, client: mini)
    done = 0
    fields.each_with_index do |sf, i|
      next if resume && FieldAssessment.exists?(sfield_id: sf.id, cashline_snapshot_id: snapshot.id, model: mini.model)
      mini_adj.adjudicate(sf)
      done += 1
      print(i % 100 == 99 ? " #{i + 1}\n" : ".")
    rescue Openai::Error, Faraday::Error => e
      run.record_partial_failure!(object_api_name: "assess:#{sf.api_name}", reason: e.message)
      print "x"
    end
    puts "\ntier-1 (#{mini.model}) assessed #{done} fields."

    # Stage 3 — escalation to Opus for the uncertain / sensitive subset.
    if opus_on
      escalate = fields.select { |sf| escalate_field?(sf, snapshot, threshold) }
                       .sort_by { |sf| FieldAssessment.find_by(sfield_id: sf.id, cashline_snapshot_id: snapshot.id)&.confidence || 0.0 }
                       .first(escalate_max)
      puts "escalating #{escalate.size} fields to #{Anthropic::Messages::DEFAULT_MODEL}..."
      opus_adj = Mapping::LlmAdjudicator.new(snapshot: snapshot, client: Anthropic::Messages.new)
      escalate.each_with_index do |sf, i|
        opus_adj.adjudicate(sf)
        print(i % 50 == 49 ? " #{i + 1}\n" : ".")
      rescue Anthropic::Error, Faraday::Error => e
        run.record_partial_failure!(object_api_name: "escalate:#{sf.api_name}", reason: e.message)
        print "x"
      end
      puts "\nescalated #{escalate.size} fields."

      contested = Mapping::LlmDisambiguator.new(snapshot: snapshot, client: Anthropic::Messages.new).resolve!(run)
      puts "disambiguated #{contested} contested target(s)."
    end

    by_disp = FieldAssessment.where(cashline_snapshot_id: snapshot.id).group(:disposition).count
    puts "\nDone. assessments by disposition: #{by_disp}"
  end

  desc "Re-assess Sailfin reference/lookup + external-id fields with Opus. RUN= SNAPSHOT= [INCLUDE_AUDIT=1] [DRY_RUN=1]"
  task escalate_refs: :environment do
    run, snapshot = resolve_run_and_snapshot
    opus = Anthropic::Messages.new
    abort "Anthropic not configured — set anthropic.api_key" unless opus.available?

    # Lookups (data_type 'reference') plus custom external-id/key fields, which
    # gpt-4o-mini tends to mislabel `discard` rather than `sailfin_sync`. Standard
    # audit references are excluded (they really are discard) unless INCLUDE_AUDIT.
    audit_refs = %w[CreatedById LastModifiedById OwnerId LastModifiedByID]
    fields = Sfield.joins(:sobject)
      .where(sobjects: { extraction_run_id: run.id })
      .where("sfields.data_type = 'reference' OR sfields.api_name ~* '(_id|_ids|_key)__c$'")
      .includes(:spicklist_values, :sobject)
      .to_a
    fields.reject! { |sf| audit_refs.include?(sf.api_name) } unless ENV["INCLUDE_AUDIT"] == "1"
    # Resumable: skip fields Opus already re-assessed (e.g. after a credit stall),
    # unless FORCE=1 re-does them all.
    fields.reject! { |sf| FieldAssessment.exists?(sfield_id: sf.id, cashline_snapshot_id: snapshot.id, model: opus.model) } unless ENV["FORCE"] == "1"

    puts "Reference/ID fields to re-assess with #{opus.model}: #{fields.size}"
    if ENV["DRY_RUN"] == "1"
      fields.first(40).each { |sf| puts "  #{sf.sobject.api_name}.#{sf.api_name} (#{sf.data_type})" }
      puts "  ... (#{fields.size} total)" if fields.size > 40
      next
    end

    adj = Mapping::LlmAdjudicator.new(snapshot: snapshot, client: opus)
    fields.each_with_index do |sf, i|
      adj.adjudicate(sf)
      print(i % 50 == 49 ? " #{i + 1}\n" : ".")
    rescue Anthropic::Error, Faraday::Error => e
      run.record_partial_failure!(object_api_name: "escalate_refs:#{sf.api_name}", reason: e.message)
      print "x"
    end

    contested = begin
      Mapping::LlmDisambiguator.new(snapshot: snapshot, client: opus).resolve!(run)
    rescue Anthropic::Error, Faraday::Error => e
      puts "\ndisambiguation skipped (#{e.class}): #{e.message}"
      0
    end
    puts "\nre-assessed #{fields.size} fields; disambiguated #{contested}."
    puts "dispositions: #{FieldAssessment.where(cashline_snapshot_id: snapshot.id).group(:disposition).count}"
  end

  desc "Re-assess low-confidence tier-1 (mini) fields with Opus. RUN= SNAPSHOT= BELOW=0.75 [DRY_RUN=1]"
  task escalate_uncertain: :environment do
    run, snapshot = resolve_run_and_snapshot
    opus = Anthropic::Messages.new
    abort "Anthropic not configured — set anthropic.api_key" unless opus.available?
    below = (ENV["BELOW"] || "0.75").to_f

    # Fields the cheap tier flagged as uncertain (and that Opus hasn't already
    # re-done). Unlike mapping:assess this does NOT reset proposals — it only
    # re-adjudicates this set with Opus, preserving everything else.
    field_ids = FieldAssessment.where(cashline_snapshot_id: snapshot.id, model: Openai::Chat::DEFAULT_MODEL)
      .where("confidence < ?", below).pluck(:sfield_id)
    fields = Sfield.where(id: field_ids).includes(:spicklist_values, :sobject).to_a

    puts "Low-confidence mini fields (< #{below}) to re-assess with #{opus.model}: #{fields.size}"
    next if ENV["DRY_RUN"] == "1"

    adj = Mapping::LlmAdjudicator.new(snapshot: snapshot, client: opus)
    fields.each_with_index do |sf, i|
      adj.adjudicate(sf)
      print(i % 50 == 49 ? " #{i + 1}\n" : ".")
    rescue Anthropic::Error, Faraday::Error => e
      run.record_partial_failure!(object_api_name: "escalate_uncertain:#{sf.api_name}", reason: e.message)
      print "x"
    end

    contested = begin
      Mapping::LlmDisambiguator.new(snapshot: snapshot, client: opus).resolve!(run)
    rescue Anthropic::Error, Faraday::Error => e
      puts "\ndisambiguation skipped (#{e.class}): #{e.message}"
      0
    end
    puts "\nre-assessed #{fields.size} fields; disambiguated #{contested}."
    puts "dispositions: #{FieldAssessment.where(cashline_snapshot_id: snapshot.id).group(:disposition).count}"
  end
end
