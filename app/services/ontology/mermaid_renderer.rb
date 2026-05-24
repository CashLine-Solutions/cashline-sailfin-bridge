module Ontology
  # Generates a Mermaid ER diagram for a single cluster of sobjects.
  # Server-side; client-side rendering happens via the `erd` Stimulus controller.
  #
  # Mermaid identifiers can't contain quotes, brackets, or reserved words;
  # we sanitize Salesforce names before emission.
  class MermaidRenderer
    RESERVED = %w[true false null int integer string number]

    def self.for_cluster(cluster)
      new(cluster).render
    end

    def initialize(cluster)
      @cluster = cluster
      @sobjects = cluster.sobjects.includes(:sfields).order(:api_name).to_a
      @sobject_ids = @sobjects.map(&:id).to_set
      @sobject_by_id = @sobjects.index_by(&:id)
    end

    def render
      lines = ["erDiagram"]
      @sobjects.each do |so|
        lines << "  #{safe_id(so.api_name)} {"
        so.sfields.order(:api_name).first(15).each do |f|
          lines << "    #{safe_type(f.data_type)} #{safe_id(f.api_name)} #{safe_modifier(f)}"
        end
        lines << "  }"
      end

      Srelationship
        .where(extraction_run_id: @cluster.extraction_run_id)
        .where.not(target_sobject_id: nil)
        .pluck(:source_sobject_id, :target_sobject_id, :relationship_name)
        .each do |src_id, tgt_id, name|
          next unless @sobject_ids.include?(src_id) && @sobject_ids.include?(tgt_id)
          src = @sobject_by_id[src_id]
          tgt = @sobject_by_id[tgt_id]
          lines << %(  #{safe_id(src.api_name)} }o--|| #{safe_id(tgt.api_name)} : "#{safe_label(name || 'refs')}")
        end

      lines.join("\n")
    end

    private

    def safe_id(name)
      sanitized = name.to_s.gsub(/[^A-Za-z0-9_]/, "_")
      sanitized = "_#{sanitized}" if sanitized =~ /\A\d/
      sanitized = "_#{sanitized}" if RESERVED.include?(sanitized.downcase)
      sanitized
    end

    def safe_type(type)
      (type.presence || "string").to_s.gsub(/[^A-Za-z0-9_]/, "_")
    end

    def safe_label(name)
      name.to_s.gsub(/["\\]/, "")
    end

    def safe_modifier(f)
      flags = []
      flags << "PK" if f.name_field
      flags << "FK" if f.references_count.to_i > 0
      flags.join(" ")
    end
  end
end
