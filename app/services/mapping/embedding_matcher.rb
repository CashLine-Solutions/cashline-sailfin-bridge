require "digest"

module Mapping
  # Adds embedding similarity as an additive signal on top of the heuristic
  # proposals (Unit 9). For each Sailfin field it embeds a *descriptor* (never
  # field values), finds the nearest cashline target descriptors via pgvector
  # cosine search, and merges the similarity into mapping_proposals.signals,
  # re-scoring with the heuristic weights.
  #
  # Sensitivity (field-level dimension): pii/financial/unknown_sensitivity
  # fields are embedded as *structural-metadata-only* (api_name + type) —
  # unconditionally, no user carve-out — so label/help-text is never transmitted
  # and the content-hash cache can't leak a privileged user's richer descriptor.
  class EmbeddingMatcher
    W_EMBEDDING = 1.0
    TOP_K = 3
    MIN_SIMILARITY = 0.3

    def initialize(snapshot:, embeddings: nil)
      @snapshot = snapshot
      @embeddings = embeddings || Openai::Embeddings.new
      @dossier = Dossier.new(snapshot: snapshot)
    end

    def available?
      @embeddings.available?
    end

    # Merge embedding candidates into proposals for every field in `run`.
    # Returns false (no-op) when OpenAI isn't configured — heuristic stands.
    def combine!(run, fields: nil)
      return false unless available?

      targets = build_targets
      target_hashes = targets.map { |t| t[:hash] }.uniq
      hash_to_targets = targets.group_by { |t| t[:hash] }

      sources = (fields || source_fields(run)).map do |sf|
        text = descriptor_for_sfield(sf)
        { sfield: sf, text: text, hash: sha(text) }
      end

      ensure_embeddings(targets.to_h { |t| [ t[:hash], t[:text] ] })
      ensure_embeddings(sources.to_h { |s| [ s[:hash], s[:text] ] })
      record_sources(sources)

      sources.each { |s| merge_for_source(s, target_hashes, hash_to_targets) }
      true
    end

    # Purge a field's cached embeddings on a safe -> sensitive upgrade. Deletes
    # its back-references and any now-orphaned cache rows.
    def self.purge_field!(sfield)
      hashes = EmbeddingSource.where(sfield_id: sfield.id).pluck(:content_sha256)
      return if hashes.empty?
      EmbeddingSource.where(sfield_id: sfield.id).delete_all
      orphaned = hashes.reject { |h| EmbeddingSource.exists?(content_sha256: h) }
      EmbeddingCache.where(content_sha256: orphaned).delete_all if orphaned.any?
    end

    private

    # Descriptor text = the full role dossier (sensitivity-gated inside Dossier:
    # non-safe fields render structural-metadata-only, so nothing sensitive is
    # transmitted). This is the change that lets embeddings match on role, not
    # just name.
    def descriptor_for_sfield(sfield)
      @dossier.render(@dossier.source(sfield))
    end

    def build_targets
      @snapshot.classes.flat_map do |class_name|
        @snapshot.fields_for(class_name).reject { |c| HeuristicMatcher::SKIP_FIELDS.include?(c["name"]) }.map do |col|
          text = @dossier.render(@dossier.target(class_name, col["name"]))
          { class: class_name, field: col["name"], text: text, hash: sha(text) }
        end
      end
    end

    # hash_to_text: { content_sha256 => descriptor_text }. Embeds only the
    # descriptors not already cached (content-addressed, so re-runs don't rebill).
    def ensure_embeddings(hash_to_text)
      missing = hash_to_text.reject { |hash, _| EmbeddingCache.exists?(content_sha256: hash) }
      return if missing.empty?

      vectors = @embeddings.embed(missing.values)
      missing.keys.each_with_index do |hash, i|
        vector = vectors[i]
        next if vector.nil?
        EmbeddingCache.create!(content_sha256: hash, embedding: vector)
      rescue ActiveRecord::RecordNotUnique
        next
      end
    end

    def record_sources(sources)
      sources.each do |s|
        EmbeddingSource.find_or_create_by!(sfield_id: s[:sfield].id, content_sha256: s[:hash])
      rescue ActiveRecord::RecordNotUnique
        next
      end
    end

    def merge_for_source(source, target_hashes, hash_to_targets)
      cache = EmbeddingCache.find_by(content_sha256: source[:hash])
      return if cache.nil?

      neighbors = EmbeddingCache.where(content_sha256: target_hashes)
        .nearest_neighbors(:embedding, cache.embedding, distance: "cosine")
        .first(TOP_K)

      neighbors.each do |neighbor|
        similarity = (1.0 - neighbor.neighbor_distance).round(4)
        next if similarity < MIN_SIMILARITY
        Array(hash_to_targets[neighbor.content_sha256]).each do |target|
          merge_proposal(source[:sfield], target[:class], target[:field], similarity)
        end
      end
    end

    def merge_proposal(sfield, target_class, target_field, similarity)
      return if MappingProposal.rejected?(source_field_id: sfield.id, target_class: target_class, target_field: target_field)

      proposal = MappingProposal.find_or_initialize_by(
        source_field_id: sfield.id, cashline_snapshot_id: @snapshot.id,
        target_class: target_class, target_field: target_field
      )
      return if proposal.state == "accepted"

      proposal.state = "open" if proposal.new_record?
      signals = proposal.signals.presence || {}
      signals["lexical"] ||= 0.0
      signals["type"] = false unless signals.key?("type")
      signals["picklist"] ||= 0.0
      signals["embedding"] = similarity
      proposal.signals = signals
      proposal.score = recompute_score(signals)
      proposal.save!
    end

    def recompute_score(signals)
      (HeuristicMatcher::W_LEXICAL * signals["lexical"].to_f) +
        (signals["type"] ? HeuristicMatcher::W_TYPE : 0.0) +
        (HeuristicMatcher::W_PICKLIST * signals["picklist"].to_f) +
        (W_EMBEDDING * signals["embedding"].to_f)
    end

    def source_fields(run)
      Sfield.joins(:sobject).where(sobjects: { extraction_run_id: run.id })
    end

    def sha(text)
      Digest::SHA256.hexdigest(text)
    end
  end
end
