require "test_helper"

module Ontology
  class SensitivityClassifierTest < ActiveSupport::TestCase
    def classify(field, sobject: nil, compliance_group: nil, security_classification: nil)
      SensitivityClassifier.classify(
        field: field,
        sobject_describe: sobject,
        compliance_group: compliance_group,
        security_classification: security_classification
      )
    end

    test "Email type → pii" do
      result = classify({ "name" => "Email", "type" => "email" })
      assert_equal "pii", result[:sensitivity]
      assert_includes result[:signals], "type:email"
    end

    test "BillingStreet (compound address) → pii" do
      result = classify({ "name" => "BillingStreet", "type" => "string", "compoundFieldName" => "BillingAddress" })
      assert_equal "pii", result[:sensitivity]
      assert(result[:signals].any? { |s| s.start_with?("compound_address") })
    end

    test "Amount__c currency → financial" do
      result = classify({ "name" => "Amount__c", "type" => "currency" })
      assert_equal "financial", result[:sensitivity]
    end

    test "Account.Name (business name, no FirstName/LastName siblings) → safe" do
      sobject = { "name" => "Account", "fields" => [ { "name" => "Name", "nameField" => true } ] }
      result = classify({ "name" => "Name", "type" => "string", "nameField" => true }, sobject: sobject)
      assert_equal "safe", result[:sensitivity]
    end

    test "Contact.LastName (with FirstName sibling) → pii" do
      sobject = {
        "name" => "Contact",
        "fields" => [
          { "name" => "FirstName", "type" => "string" },
          { "name" => "LastName", "type" => "string", "nameField" => true }
        ]
      }
      result = classify({ "name" => "LastName", "type" => "string", "nameField" => true }, sobject: sobject)
      assert_equal "pii", result[:sensitivity]
    end

    test "Discount__c currency → financial (cautious)" do
      result = classify({ "name" => "Discount__c", "type" => "currency" })
      assert_equal "financial", result[:sensitivity]
    end

    test "ComplianceGroup=PII override beats name pattern absence" do
      result = classify({ "name" => "OpaqueField__c", "type" => "string" }, compliance_group: "PII")
      assert_equal "pii", result[:sensitivity]
    end

    test "Encrypted field → pii" do
      result = classify({ "name" => "SSN__c", "type" => "string", "encrypted" => true })
      assert_equal "pii", result[:sensitivity]
    end

    test "Combined pii + financial → pii_and_financial" do
      result = classify({ "name" => "PaymentEmail__c", "type" => "email", "compoundFieldName" => nil })
      # Has 'email' type (pii) AND 'payment' name pattern (financial).
      assert_equal "pii_and_financial", result[:sensitivity]
    end

    test "Missing/empty field returns unknown_sensitivity (fail-closed)" do
      result = classify({})
      assert_equal "unknown_sensitivity", result[:sensitivity]
      assert_includes result[:signals], "missing_describe"
    end

    test "SecurityClassification=Confidential escalates an otherwise-safe field to financial" do
      result = classify({ "name" => "OpaqueNote__c", "type" => "string" }, security_classification: "Confidential")
      assert_equal "financial", result[:sensitivity]
      assert_includes result[:signals], "security_classification:Confidential"
    end

    test "SecurityClassification=Internal is not sensitive → safe" do
      result = classify({ "name" => "OpaqueNote__c", "type" => "string" }, security_classification: "Internal")
      assert_equal "safe", result[:sensitivity]
    end

    test "ComplianceGroup=PII + SecurityClassification=Restricted → pii_and_financial" do
      result = classify(
        { "name" => "OpaqueField__c", "type" => "string" },
        compliance_group: "PII", security_classification: "Restricted"
      )
      assert_equal "pii_and_financial", result[:sensitivity]
    end

    test "Phone type → pii" do
      result = classify({ "name" => "MobilePhone", "type" => "phone" })
      assert_equal "pii", result[:sensitivity]
    end

    # FirstName/LastName in real Salesforce describes have `nameField=false`
    # (only the compound `Name` is the nameField). The name-pattern fallback
    # must still catch the camelCase variants.
    test "Contact.FirstName (no nameField, camelCase) → pii via name pattern" do
      result = classify({ "name" => "FirstName", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "Contact.LastName (no nameField, camelCase) → pii via name pattern" do
      result = classify({ "name" => "LastName", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "Account.ABA__c → pii (banking PII)" do
      result = classify({ "name" => "ABA__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "Account.IBAN__c → pii (banking PII)" do
      result = classify({ "name" => "IBAN__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "Account.Bank_Account_No__c → pii (banking PII)" do
      result = classify({ "name" => "Bank_Account_No__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "Account.Routing_No__c → pii (banking PII)" do
      result = classify({ "name" => "Routing_No__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "sfcapp__ABANumber__c → pii (banking PII, embedded number)" do
      result = classify({ "name" => "sfcapp__ABANumber__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "sfsrm__EIN_or_Social_Security_Numbre_s__c → pii (typo'd field name)" do
      result = classify({ "name" => "sfsrm__EIN_or_Social_Security_Numbre_s__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "sfsrm__Archival_Password__c string → pii via credential pattern" do
      result = classify({ "name" => "sfsrm__Archival_Password__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    test "sfsrm__AWSSecretKey__c string → pii via credential pattern" do
      result = classify({ "name" => "sfsrm__AWSSecretKey__c", "type" => "string" })
      assert_equal "pii", result[:sensitivity]
    end

    # Type-gate keeps Salesforce permission booleans and metadata datetimes safe.
    test "Profile.PermissionsManagePasswordPolicies boolean → safe (permission flag, not a password)" do
      result = classify({ "name" => "PermissionsManagePasswordPolicies", "type" => "boolean" })
      assert_equal "safe", result[:sensitivity]
    end

    test "User.LastPasswordChangeDate datetime → safe (metadata, not the password)" do
      result = classify({ "name" => "LastPasswordChangeDate", "type" => "datetime" })
      assert_equal "safe", result[:sensitivity]
    end

    test "Network.HeadlessForgotPasswordTemplateId reference → safe (template id)" do
      result = classify({ "name" => "HeadlessForgotPasswordTemplateId", "type" => "reference" })
      assert_equal "safe", result[:sensitivity]
    end

    # Letter-boundary lookarounds keep banking tokens from matching substrings.
    # We intentionally err toward false-positive on Swift* at token boundaries
    # (SWIFT banking codes dominate real Salesforce orgs), but `swift` mid-word
    # must not match.
    test "Swiftness__c → safe (`swift` followed by letters, not a token boundary)" do
      result = classify({ "name" => "Swiftness__c", "type" => "string" })
      assert_equal "safe", result[:sensitivity]
    end

    test "Einstein-named permission → safe (`ein` not at a token boundary)" do
      result = classify({ "name" => "PermissionsAccessEinsteinAnalytics", "type" => "boolean" })
      assert_equal "safe", result[:sensitivity]
    end
  end
end
