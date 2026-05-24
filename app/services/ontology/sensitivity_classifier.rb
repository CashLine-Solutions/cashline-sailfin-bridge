module Ontology
  # Classifies a Salesforce field as `safe`, `pii`, `financial`, or
  # `pii_and_financial`. Used by Unit 14 to decide whether top-N + samples
  # can be collected for the field.
  #
  # Fail-closed: when input is incomplete the result is `unknown_sensitivity`,
  # which Unit 14 treats the same as `pii` for the purpose of suppression.
  module SensitivityClassifier
    extend self

    SAFE = "safe".freeze
    PII = "pii".freeze
    FINANCIAL = "financial".freeze
    PII_AND_FINANCIAL = "pii_and_financial".freeze
    UNKNOWN = "unknown_sensitivity".freeze

    # Returns { sensitivity:, signals: [...] }.
    # `field` is the raw describe field hash; `sobject_describe` is the
    # owning object's describe (used to detect person-name siblings);
    # `compliance_group` is the optional Tooling-API FieldDefinition string.
    def classify(field:, sobject_describe: nil, compliance_group: nil)
      return { sensitivity: UNKNOWN, signals: [ "missing_describe" ] } if field.nil? || field.empty?

      signals = []
      pii = false
      financial = false

      pii ||= pii_by_salesforce_native?(field, sobject_describe, signals)
      pii ||= pii_by_type?(field, signals)
      pii ||= pii_by_name_pattern?(field, signals)

      financial ||= financial_by_type?(field, signals)
      financial ||= financial_by_name_pattern?(field, signals)

      if compliance_group.is_a?(String)
        if compliance_group.match?(/\b(PII|PCI|HIPAA)\b/i)
          pii = true
          signals << "compliance_group:#{compliance_group}"
        end
        if compliance_group.match?(/Confidential/i) && financial_pattern_match?(field["name"].to_s)
          financial = true
          signals << "compliance_group_confidential:financial_name"
        end
      end

      sensitivity =
        if pii && financial then PII_AND_FINANCIAL
        elsif pii then PII
        elsif financial then FINANCIAL
        else SAFE
        end

      { sensitivity: sensitivity, signals: signals }
    end

    private

    def pii_by_salesforce_native?(field, sobject_describe, signals)
      if field["encrypted"]
        signals << "encrypted"
        return true
      end

      compound = field["compoundFieldName"].to_s
      if compound.match?(/Address\z|MailingAddress|BillingAddress|ShippingAddress|OtherAddress/)
        signals << "compound_address:#{compound}"
        return true
      end

      if field["nameField"] && sobject_describe && person_name_object?(sobject_describe)
        signals << "name_field_on_person_object"
        return true
      end

      false
    end

    def pii_by_type?(field, signals)
      case field["type"]
      when "email"
        signals << "type:email"
        true
      when "phone"
        signals << "type:phone"
        true
      else
        false
      end
    end

    PII_NAME_PATTERN = /email|phone|ssn|tax_id|dob|birth|first_name|last_name|address|postal|zip/i

    def pii_by_name_pattern?(field, signals)
      name = field["name"].to_s
      return false unless name.match?(PII_NAME_PATTERN)

      signals << "name_pattern:pii:#{name}"
      true
    end

    def financial_by_type?(field, signals)
      case field["type"]
      when "currency"
        signals << "type:currency"
        true
      when "percent"
        signals << "type:percent"
        true
      else
        false
      end
    end

    FINANCIAL_NAME_PATTERN = /amount|balance|payment|credit|debit|rating|score|invoice|salary|wage|revenue/i

    def financial_by_name_pattern?(field, signals)
      name = field["name"].to_s
      return false unless name.match?(FINANCIAL_NAME_PATTERN)

      signals << "name_pattern:financial:#{name}"
      true
    end

    def financial_pattern_match?(name)
      name.match?(FINANCIAL_NAME_PATTERN)
    end

    def person_name_object?(sobject_describe)
      fields = Array(sobject_describe["fields"]).map { |f| f["name"] }
      fields.include?("FirstName") && fields.include?("LastName")
    end
  end
end
