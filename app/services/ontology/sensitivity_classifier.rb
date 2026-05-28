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

    # Data-sensitivity levels (FieldDefinition.SecurityClassification) that
    # denote sensitive data. `Public`/`Internal` are not sensitive.
    SENSITIVE_CLASSIFICATIONS = /Confidential|Restricted|MissionCritical/i

    # Returns { sensitivity:, signals: [...] }.
    # `field` is the raw describe field hash; `sobject_describe` is the
    # owning object's describe (used to detect person-name siblings).
    # `compliance_group` and `security_classification` are the optional
    # Tooling-API FieldDefinition strings (ComplianceGroup / SecurityClassification) --
    # admin-declared, so they take precedence over the heuristics above.
    def classify(field:, sobject_describe: nil, compliance_group: nil, security_classification: nil)
      return { sensitivity: UNKNOWN, signals: [ "missing_describe" ] } if field.nil? || field.empty?

      signals = []
      pii = false
      financial = false

      pii ||= pii_by_salesforce_native?(field, sobject_describe, signals)
      pii ||= pii_by_type?(field, signals)
      pii ||= pii_by_name_pattern?(field, signals)

      financial ||= financial_by_type?(field, signals)
      financial ||= financial_by_name_pattern?(field, signals)

      if compliance_group.is_a?(String) && compliance_group.match?(/\b(PII|PCI|HIPAA)\b/i)
        pii = true
        signals << "compliance_group:#{compliance_group}"
      end

      # An admin-declared sensitive data-classification (Confidential /
      # Restricted / MissionCritical) means "do not treat as public." There is
      # no standalone confidential tier, so we escalate to `financial` -- the
      # business-sensitive bucket -- which suppresses sampling in Unit 14.
      # Public / Internal are not sensitive and are ignored.
      if security_classification.is_a?(String) && security_classification.match?(SENSITIVE_CLASSIFICATIONS)
        financial = true
        signals << "security_classification:#{security_classification}"
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

    # Identifies fields likely to contain personal or banking PII by name.
    # Names are normalized to insert underscores at camelCase boundaries
    # (`FirstName` -> `First_Name`, `ABANumber__c` -> `ABA_Number__c`) so
    # one pattern matches both Salesforce camelCase and snake_case
    # custom-field conventions. Short tokens use `(?<![a-z])...(?![a-z])`
    # letter-boundaries (Ruby `\b` treats `_` as a word char, which defeats
    # boundary detection between letters and underscores).
    PII_NAME_PATTERN = /
      email | phone |
      ssn | (?<![a-z])ein(?![a-z]) | social_?security | tax_?id |
      dob | birth |
      (?<![a-z])first_?name(?![a-z]) | (?<![a-z])last_?name(?![a-z]) |
      address | postal | zip |
      (?<![a-z])aba(?![a-z]) | (?<![a-z])iban(?![a-z]) | (?<![a-z])swift(?![a-z]) |
      routing | bank_?ac(c?t|count)
    /xi

    # Credential-value patterns: fields likely to *store* a credential value
    # (vs. metadata about credentials -- `LastPasswordChangeDate`,
    # `PermissionsManagePasswordPolicies`). Type-gated to string-like fields
    # so booleans, dates, and references aren't false-flagged.
    PII_CREDENTIAL_NAME_PATTERN = /password|secret|access_?token|refresh_?token|auth_?token|api_?key/i
    CREDENTIAL_VALUE_TYPES = %w[string textarea encryptedstring].freeze

    def pii_by_name_pattern?(field, signals)
      raw = field["name"].to_s
      name = normalize_camel_case(raw)

      if name.match?(PII_NAME_PATTERN)
        signals << "name_pattern:pii:#{raw}"
        return true
      end

      if name.match?(PII_CREDENTIAL_NAME_PATTERN) && CREDENTIAL_VALUE_TYPES.include?(field["type"].to_s.downcase)
        signals << "name_pattern:credential:#{raw}"
        return true
      end

      false
    end

    # Insert underscores at camelCase boundaries so token-anchored patterns
    # match both `FirstName` and `first_name` and `BillingLastName` the same way.
    def normalize_camel_case(name)
      name.gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
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

    def person_name_object?(sobject_describe)
      fields = Array(sobject_describe["fields"]).map { |f| f["name"] }
      fields.include?("FirstName") && fields.include?("LastName")
    end
  end
end
