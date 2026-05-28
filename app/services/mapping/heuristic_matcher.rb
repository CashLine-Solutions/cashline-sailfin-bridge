module Mapping
  # API-free candidate mapping: scores cashline targets against a Sailfin source
  # field by lexical token similarity, data-type compatibility, and picklist /
  # enum value overlap. Cheap, PII-safe, and handles the common lexical cases;
  # embeddings (Unit 10) are an additive signal only if this leaves a gap.
  #
  # Ranking contract (tested): the combined score lets a type-compatible,
  # picklist-overlapping candidate outrank a closer pure-lexical match — the
  # weighting is more than exact-string matching. Exact weights are tunable.
  class HeuristicMatcher
    W_LEXICAL = 1.0
    W_TYPE = 0.5
    W_PICKLIST = 1.0
    DEFAULT_TOP_N = 3
    MIN_SCORE = 0.1

    # Noise targets nobody maps onto.
    SKIP_FIELDS = %w[id created_at updated_at].freeze

    # Salesforce data_type => compatible cashline abstract types.
    SF_TYPE_MAP = {
      "string" => %w[string text], "textarea" => %w[string text], "email" => %w[string],
      "phone" => %w[string], "url" => %w[string], "picklist" => %w[string integer],
      "multipicklist" => %w[string text], "reference" => %w[integer string], "id" => %w[integer string],
      "boolean" => %w[boolean], "int" => %w[integer], "double" => %w[decimal float integer],
      "currency" => %w[decimal integer], "percent" => %w[decimal float], "date" => %w[date],
      "datetime" => %w[datetime], "time" => %w[time], "address" => %w[string text]
    }.freeze

    def initialize(snapshot:, top_n: DEFAULT_TOP_N)
      @snapshot = snapshot
      @top_n = top_n
      @targets = build_targets
    end

    # [{ target_class:, target_field:, score:, signals: {lexical:, type:, picklist:} }, ...]
    def candidates_for(sfield)
      src_tokens = tokens("#{sfield.api_name} #{sfield.label}")
      src_type = sfield.data_type
      src_values = picklist_values(sfield)

      @targets.map { |t| score_target(t, src_tokens, src_type, src_values) }
        .select { |c| c[:score] >= MIN_SCORE }
        .sort_by { |c| [ -c[:score], c[:target_class], c[:target_field] ] }
        .first(@top_n)
    end

    private

    def score_target(target, src_tokens, src_type, src_values)
      lexical = jaccard(src_tokens, target[:tokens])
      type_ok = type_compatible?(src_type, target[:type])
      picklist = picklist_overlap(src_values, target[:enum_values])
      score = (lexical * W_LEXICAL) + (type_ok ? W_TYPE : 0.0) + (picklist * W_PICKLIST)
      {
        target_class: target[:class], target_field: target[:field], score: score.round(4),
        signals: { "lexical" => lexical.round(4), "type" => type_ok, "picklist" => picklist.round(4) }
      }
    end

    def build_targets
      @snapshot.classes.flat_map do |class_name|
        @snapshot.fields_for(class_name).reject { |col| SKIP_FIELDS.include?(col["name"]) }.map do |col|
          {
            class: class_name, field: col["name"], type: col["type"],
            tokens: tokens(col["name"]), enum_values: col["enum_values"]
          }
        end
      end
    end

    def tokens(str)
      str.to_s
        .gsub(/__(c|r|pc|x)\b/i, " ")          # strip Salesforce custom suffixes
        .gsub(/([a-z0-9])([A-Z])/, '\1 \2')    # split camelCase
        .downcase
        .split(/[^a-z0-9]+/)
        .reject(&:blank?)
        .to_set
    end

    def jaccard(a, b)
      return 0.0 if a.empty? || b.empty?
      (a & b).size.to_f / (a | b).size
    end

    def type_compatible?(sf_type, target_type)
      return false if sf_type.blank? || target_type.blank?
      (SF_TYPE_MAP[sf_type] || [ sf_type ]).include?(target_type)
    end

    # Active source picklist values, downcased (down-weights dead/inactive values).
    def picklist_values(sfield)
      values = sfield.spicklist_values.select(&:active).map(&:value)
      values = sfield.spicklist_values.map(&:value) if values.empty?
      values.compact.map(&:downcase).to_set
    end

    def picklist_overlap(src_values, enum_values)
      return 0.0 if src_values.empty? || enum_values.blank?
      enum_set = enum_values.keys.map { |k| k.to_s.downcase }.to_set
      (src_values & enum_set).size.to_f / src_values.size
    end
  end
end
