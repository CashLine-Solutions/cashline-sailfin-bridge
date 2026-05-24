module Salesforce
  # Per-object profiler. Pulls record count from the Tooling API's
  # `EntityDefinition.RecordCount` (avoids the synchronous `SELECT COUNT()`
  # that times out above ~50M rows), then per-field aggregates via SOQL.
  #
  # If `RecordCount` exceeds LARGE_OBJECT_THRESHOLD (100k), the caller should
  # route through Salesforce::BulkV2Runner for sampling (Unit 15) — this
  # runner can still compute counts and null-rates but defers length/range
  # stats to the bulk path.
  class ProfileRunner
    LARGE_OBJECT_THRESHOLD = 100_000
    DEFAULT_TOP_N = 10
    DEFAULT_SAMPLE_SIZE = 5

    def initialize(rest_client:, tooling_client: nil)
      @rest = rest_client
      @tooling = tooling_client
    end

    # Profiles `sobject` and persists `ObjectProfile` + `FieldProfile` rows.
    # `policy` is `Ontology::ProfilingPolicy` (Unit 14) — determines whether
    # top-N / sample values can be collected for a given field.
    def profile!(extraction_run:, sobject:, policy: Ontology::ProfilingPolicy.deny_all)
      profile = ObjectProfile.find_or_create_by!(extraction_run: extraction_run, sobject: sobject) do |p|
        p.status = "pending"
      end

      record_count = fetch_record_count(sobject.api_name)
      profile.update!(record_count: record_count)

      use_bulk = record_count && record_count > LARGE_OBJECT_THRESHOLD
      profile.update!(sampled: use_bulk)

      sobject.sfields.find_each do |sfield|
        compute_field_profile!(profile, sfield, use_bulk: use_bulk, policy: policy)
      end

      profile.update!(status: "complete", profiled_at: Time.current)
      profile
    rescue StandardError => e
      profile&.update!(status: "failed", failure_reason: e.message)
      raise
    end

    private

    def fetch_record_count(api_name)
      return nil unless @tooling

      result = @tooling.query("SELECT QualifiedApiName, RecordCount FROM EntityDefinition WHERE QualifiedApiName = '#{escape(api_name)}'").to_a
      result.first&.[]("RecordCount")&.to_i
    rescue StandardError => e
      Rails.logger.warn "EntityDefinition.RecordCount fetch failed for #{api_name}: #{e.message}"
      nil
    end

    def compute_field_profile!(profile, sfield, use_bulk:, policy:)
      fp = FieldProfile.find_or_create_by!(object_profile: profile, sfield: sfield)
      return if use_bulk # large objects deferred to BulkV2Runner

      api_name = profile.sobject.api_name
      field_name = sfield.api_name
      total = profile.record_count || count_via_soql(api_name)

      null_count = aggregate("SELECT COUNT(Id) c FROM #{api_name} WHERE #{field_name} = null")
      distinct_count = aggregate("SELECT COUNT_DISTINCT(#{field_name}) c FROM #{api_name}")

      attrs = { null_rate: null_rate(null_count, total), distinct_count: distinct_count }
      attrs.merge!(distinct_suppression(distinct_count, sfield))
      attrs.merge!(type_specific_stats(api_name, sfield))
      attrs.merge!(top_and_sample(api_name, sfield, policy))

      fp.update!(attrs)
      fp
    end

    def count_via_soql(api_name)
      aggregate("SELECT COUNT(Id) c FROM #{api_name}")
    end

    def aggregate(soql)
      result = @rest.query(soql).to_a.first
      return 0 unless result
      result["c"] || result[:c] || result.values.first
    rescue StandardError
      0
    end

    def null_rate(null_count, total)
      return nil if total.to_i <= 0
      null_count.to_f / total
    end

    def distinct_suppression(distinct_count, sfield)
      if non_safe?(sfield) && distinct_count.to_i.positive? && distinct_count.to_i < 5
        { distinct_count: nil, distinct_count_suppressed: true }
      else
        { distinct_count_suppressed: false }
      end
    end

    def type_specific_stats(api_name, sfield)
      case sfield.data_type
      when "string", "textarea", "url", "email", "phone"
        length_stats(api_name, sfield)
      when "int", "double", "currency", "percent"
        numeric_stats(api_name, sfield)
      when "date", "datetime"
        date_stats(api_name, sfield)
      else
        {}
      end
    end

    def length_stats(api_name, sfield)
      # Salesforce SOQL does not support LENGTH() in aggregate selects, so this
      # is approximated client-side from a small sample. Heavy objects go via
      # Bulk in Unit 15 where streaming makes this exact.
      rows = safe_query("SELECT #{sfield.api_name} FROM #{api_name} WHERE #{sfield.api_name} != null LIMIT 200")
      values = rows.map { |r| r[sfield.api_name].to_s }.reject(&:empty?)
      return {} if values.empty?

      lengths = values.map(&:length)
      { min_length: lengths.min, max_length: lengths.max, avg_length: lengths.sum.to_f / lengths.size }
    end

    def numeric_stats(api_name, sfield)
      row = safe_query("SELECT MIN(#{sfield.api_name}) mn, MAX(#{sfield.api_name}) mx, AVG(#{sfield.api_name}) avg FROM #{api_name}").first
      return {} unless row

      { min_value: row["mn"], max_value: row["mx"], mean_value: row["avg"] }
    end

    def date_stats(api_name, sfield)
      row = safe_query("SELECT MIN(#{sfield.api_name}) mn, MAX(#{sfield.api_name}) mx FROM #{api_name}").first
      return {} unless row
      { min_date: row["mn"], max_date: row["mx"] }
    end

    def top_and_sample(api_name, sfield, policy)
      decision = policy.allow_sensitive_values?(sfield)
      return {} unless decision.allowed?

      top = collect_top_values(api_name, sfield)
      sample = collect_sample_values(api_name, sfield)
      attrs = {}
      attrs[:top_values] = top if top
      attrs[:sample_values] = sample if sample
      attrs[:sensitive_override_used] = true if non_safe?(sfield)
      attrs
    end

    def collect_top_values(api_name, sfield, limit: DEFAULT_TOP_N)
      soql = "SELECT #{sfield.api_name} v, COUNT(Id) c FROM #{api_name} WHERE #{sfield.api_name} != null " \
             "GROUP BY #{sfield.api_name} ORDER BY COUNT(Id) DESC LIMIT #{limit}"
      rows = safe_query(soql)
      rows.map { |r| { "value" => r["v"], "count" => r["c"].to_i } }
    end

    def collect_sample_values(api_name, sfield, limit: DEFAULT_SAMPLE_SIZE)
      soql = "SELECT #{sfield.api_name} v FROM #{api_name} WHERE #{sfield.api_name} != null LIMIT #{limit}"
      safe_query(soql).map { |r| r["v"] }
    end

    def safe_query(soql)
      @rest.query(soql).to_a
    rescue StandardError => e
      Rails.logger.warn "ProfileRunner query failed: #{e.message} (#{soql.truncate(120)})"
      []
    end

    def non_safe?(sfield)
      sfield.sensitivity != "safe"
    end

    def escape(value)
      value.to_s.gsub("'", "\\\\'")
    end
  end
end
