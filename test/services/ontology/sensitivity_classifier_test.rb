require "test_helper"

module Ontology
  class SensitivityClassifierTest < ActiveSupport::TestCase
    def classify(field, sobject: nil, compliance_group: nil)
      SensitivityClassifier.classify(field: field, sobject_describe: sobject, compliance_group: compliance_group)
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
      sobject = { "name" => "Account", "fields" => [{ "name" => "Name", "nameField" => true }] }
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

    test "ComplianceGroup=Confidential + financial name pattern → financial" do
      result = classify({ "name" => "Salary__c", "type" => "string" }, compliance_group: "Confidential")
      # name matches /salary/ → financial via pattern AND compliance override.
      assert_equal "financial", result[:sensitivity]
    end

    test "Phone type → pii" do
      result = classify({ "name" => "MobilePhone", "type" => "phone" })
      assert_equal "pii", result[:sensitivity]
    end
  end
end
