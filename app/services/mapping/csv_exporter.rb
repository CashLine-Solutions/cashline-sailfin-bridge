require "csv"

module Mapping
  # Renders the mapping store as two CSVs that feed the downstream test-import
  # loop (built in cashline-platform).
  #
  # The field-level CSV is "structurally safe" — it carries no real field
  # values, only structure + aggregate metadata. The free-text columns
  # (transformation_note, source_citation) CAN contain real values pasted by a
  # reviewer, so they are blanked unless include_free_text is set (gated on
  # sensitive_data_access by the controller). The value-companion CSV carries
  # real picklist values and is only produced for sensitive_data_access users.
  #
  # NOTE: the eventual consumer is cashline-platform's Ingestion::FieldMapping
  # (source_column/target_path/target_type/transform_rule). These columns do NOT
  # match that shape one-to-one — the reconciliation is a known cost owned by
  # the cashline-platform import step.
  class CsvExporter
    FIELD_HEADERS = %w[
      cashline_class cashline_field cashline_type
      mapping_type confidence
      sailfin_object sailfin_field
      transformation_note source_citation
      needs_crosswalk reviewed
      last_updated_by last_updated_at
    ].freeze

    VALUE_HEADERS = %w[cashline_target source_value target_enum_value notes].freeze

    def initialize(entries:, snapshot:, include_free_text:)
      @entries = entries
      @snapshot = snapshot
      @include_free_text = include_free_text
    end

    def field_csv
      CSV.generate do |csv|
        csv << FIELD_HEADERS
        @entries.each { |entry| csv << field_row(entry) }
      end
    end

    def value_csv
      CSV.generate do |csv|
        csv << VALUE_HEADERS
        @entries.each do |entry|
          target = "#{entry.target_class}##{entry.target_field}"
          entry.mapping_value_entries.each do |ve|
            csv << [ target, ve.source_value, ve.target_enum_value, ve.notes ]
          end
        end
      end
    end

    private

    def field_row(entry)
      [
        entry.target_class,
        entry.target_field,
        cashline_type(entry),
        entry.mapping_type,
        entry.confidence,
        entry.source_field&.sobject&.api_name,
        entry.source_field&.api_name,
        free_text(entry.transformation_note),
        free_text(entry.source_citation),
        entry.needs_crosswalk,
        entry.reviewed,
        entry.updated_by&.email_address,
        entry.updated_at&.iso8601
      ]
    end

    def cashline_type(entry)
      return nil if @snapshot.nil? || entry.target_class.blank?
      @snapshot.field(entry.target_class, entry.target_field)&.dig("type")
    end

    def free_text(value)
      @include_free_text ? value : nil
    end
  end
end
