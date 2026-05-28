module Salesforce
  # Pulls formula source and validation rule logic via the Tooling API for a
  # given object (`EntityDefinition.QualifiedApiName`). Restforce.tooling returns
  # a client that already speaks the /tooling SOQL surface.
  #
  # Metadata and FullName can only be retrieved one record at a time — a
  # multi-row SELECT that includes either field is rejected with MALFORMED_QUERY.
  # So we list the Ids first (cheap, multi-row) and then fetch each record's
  # Metadata blob by Id. Managed-package fields commonly have a nil
  # Metadata.formula — we skip those rather than failing the run.
  class ToolingFetcher
    def initialize(client:)
      @client = client
    end

    # Returns an array of records ready to be appended to the run's per-object
    # jsonl. Each record carries its own `record_type` so the relational loader
    # can route on it later.
    def fetch_for(api_name)
      formula_records(api_name) + validation_rule_records(api_name) + compliance_records(api_name)
    end

    private

    # Admin-declared field sensitivity from FieldDefinition. ComplianceGroup
    # (PII/PCI/HIPAA/...) and SecurityClassification (Public/Internal/
    # Confidential/Restricted/MissionCritical) are the authoritative inputs
    # to Ontology::SensitivityClassifier -- without them the classifier falls
    # back entirely to name/type heuristics. FieldDefinition must be filtered
    # by EntityDefinition.QualifiedApiName; QualifiedApiName matches the field
    # describe `name` (e.g. `Bank_Account_No__c`).
    def compliance_records(api_name)
      soql = <<~SOQL.squish
        SELECT QualifiedApiName, ComplianceGroup, SecurityClassification
        FROM FieldDefinition
        WHERE EntityDefinition.QualifiedApiName = '#{escape(api_name)}'
      SOQL

      results = safe_query(soql)
      results.filter_map do |row|
        compliance_group = row["ComplianceGroup"]
        security_classification = row["SecurityClassification"]
        next if compliance_group.blank? && security_classification.blank?

        {
          "record_type" => "tooling_field_compliance",
          "api_name" => api_name,
          "field_api_name" => row["QualifiedApiName"],
          "compliance_group" => compliance_group.presence,
          "security_classification" => security_classification.presence
        }
      end
    end

    def formula_records(api_name)
      soql = <<~SOQL.squish
        SELECT Id, DeveloperName, NamespacePrefix
        FROM CustomField
        WHERE EntityDefinition.QualifiedApiName = '#{escape(api_name)}'
      SOQL

      safe_query(soql).filter_map do |row|
        metadata = fetch_metadata("CustomField", row["Id"])
        formula = metadata_value(metadata, "formula")
        next if formula.blank?

        {
          "record_type" => "tooling_field_metadata",
          "api_name" => api_name,
          "field_api_name" => qualified_field_name(row),
          "field_developer_name" => row["DeveloperName"],
          "formula" => formula,
          "metadata" => metadata
        }
      end
    end

    def validation_rule_records(api_name)
      soql = <<~SOQL.squish
        SELECT Id, ValidationName
        FROM ValidationRule
        WHERE EntityDefinition.QualifiedApiName = '#{escape(api_name)}'
      SOQL

      safe_query(soql).filter_map do |row|
        metadata = fetch_metadata("ValidationRule", row["Id"])
        error_formula = metadata_value(metadata, "errorConditionFormula")
        next if error_formula.blank?

        {
          "record_type" => "tooling_validation_rule",
          "api_name" => api_name,
          "rule_name" => row["ValidationName"],
          "error_condition_formula" => error_formula,
          "metadata" => metadata
        }
      end
    end

    # Metadata/FullName can only be retrieved one record at a time, so fetch the
    # blob by Id. Returns the Metadata hash, or nil when absent/unavailable.
    def fetch_metadata(sobject_type, id)
      return nil if id.blank?

      row = safe_query("SELECT Metadata FROM #{sobject_type} WHERE Id = '#{escape(id)}'").first
      return nil unless row

      metadata = row["Metadata"] || row[:Metadata]
      metadata if metadata.is_a?(Hash) || metadata.respond_to?(:[])
    end

    # CustomField.DeveloperName drops the namespace and the `__c` suffix, but the
    # describe `name` the loader matches against carries both. Reconstruct it:
    # `[namespace__]DeveloperName__c`.
    def qualified_field_name(row)
      [ row["NamespacePrefix"].presence, row["DeveloperName"] ].compact.join("__") + "__c"
    end

    def safe_query(soql)
      @client.query(soql).to_a
    rescue StandardError => e
      Rails.logger.warn "Salesforce::ToolingFetcher query failed: #{e.message}"
      []
    end

    def metadata_value(metadata, key)
      return nil unless metadata

      metadata[key] || metadata[key.to_sym]
    end

    def escape(value)
      value.to_s.gsub("'", "\\\\'")
    end
  end
end
