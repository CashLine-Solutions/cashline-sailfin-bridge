require "test_helper"

module Salesforce
  class ToolingFetcherTest < ActiveSupport::TestCase
    class StubToolingClient
      attr_reader :queries
      def initialize(responses)
        @responses = responses
        @queries = []
      end

      def query(soql)
        @queries << soql
        matched = @responses.find { |pattern, _| soql.include?(pattern) }
        (matched ? matched[1] : []).each
      end
    end

    test "returns a tooling_field_metadata record for each formula field" do
      # Metadata is fetched in a second per-Id query, not inline with the list.
      responses = [
        [ "DeveloperName, NamespacePrefix FROM CustomField", [
          { "Id" => "00N", "DeveloperName" => "Margin", "NamespacePrefix" => nil },
          { "Id" => "00P", "DeveloperName" => "Plain", "NamespacePrefix" => nil }
        ] ],
        [ "FROM CustomField WHERE Id = '00N'", [ { "Metadata" => { "formula" => "Amount__c - Cost__c" } } ] ],
        [ "FROM CustomField WHERE Id = '00P'", [ { "Metadata" => { "formula" => nil } } ] ],
        [ "FROM ValidationRule", [] ],
        [ "FROM FieldDefinition", [] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))

      records = fetcher.fetch_for("Account")
      formulas = records.select { |r| r["record_type"] == "tooling_field_metadata" }

      assert_equal 1, formulas.size
      assert_equal "Margin", formulas.first["field_developer_name"]
      assert_equal "Margin__c", formulas.first["field_api_name"]
      assert_equal "Amount__c - Cost__c", formulas.first["formula"]
    end

    test "reconstructs the namespaced field api name for managed-package fields" do
      responses = [
        [ "DeveloperName, NamespacePrefix FROM CustomField", [
          { "Id" => "00N", "DeveloperName" => "Friday_Collection", "NamespacePrefix" => "sfsrm" }
        ] ],
        [ "FROM CustomField WHERE Id = '00N'", [ { "Metadata" => { "formula" => "1 + 1" } } ] ],
        [ "FROM ValidationRule", [] ],
        [ "FROM FieldDefinition", [] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))

      formula = fetcher.fetch_for("sfsrm__Collection_Forecast__c").find { |r| r["record_type"] == "tooling_field_metadata" }
      assert_equal "sfsrm__Friday_Collection__c", formula["field_api_name"]
    end

    test "returns a tooling_validation_rule record for each rule with error formula" do
      responses = [
        [ "DeveloperName, NamespacePrefix FROM CustomField", [] ],
        [ "ValidationName FROM ValidationRule", [
          { "Id" => "03V", "ValidationName" => "NonZero" }
        ] ],
        [ "FROM ValidationRule WHERE Id = '03V'", [ { "Metadata" => { "errorConditionFormula" => "Amount__c == 0" } } ] ],
        [ "FROM FieldDefinition", [] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))

      records = fetcher.fetch_for("Account")
      rules = records.select { |r| r["record_type"] == "tooling_validation_rule" }

      assert_equal 1, rules.size
      assert_equal "NonZero", rules.first["rule_name"]
      assert_equal "Amount__c == 0", rules.first["error_condition_formula"]
    end

    test "object with no formula fields and no rules returns empty array" do
      responses = [
        [ "FROM CustomField", [] ],
        [ "FROM ValidationRule", [] ],
        [ "FROM FieldDefinition", [] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))
      assert_equal [], fetcher.fetch_for("Account")
    end

    test "returns a tooling_field_compliance record only for fields with compliance metadata" do
      responses = [
        [ "FROM CustomField", [] ],
        [ "FROM ValidationRule", [] ],
        [ "FROM FieldDefinition", [
          { "QualifiedApiName" => "Bank_Account_No__c", "ComplianceGroup" => "PII", "SecurityClassification" => "Restricted" },
          { "QualifiedApiName" => "Notes__c", "ComplianceGroup" => nil, "SecurityClassification" => "Confidential" },
          { "QualifiedApiName" => "Plain__c", "ComplianceGroup" => nil, "SecurityClassification" => nil }
        ] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))

      records = fetcher.fetch_for("Account").select { |r| r["record_type"] == "tooling_field_compliance" }

      assert_equal 2, records.size
      bank = records.find { |r| r["field_api_name"] == "Bank_Account_No__c" }
      assert_equal "PII", bank["compliance_group"]
      assert_equal "Restricted", bank["security_classification"]
      notes = records.find { |r| r["field_api_name"] == "Notes__c" }
      assert_nil notes["compliance_group"]
      assert_equal "Confidential", notes["security_classification"]
    end

    test "swallows tooling query errors and returns empty (managed-package degradation)" do
      raising = Object.new
      def raising.query(_soql)
        raise StandardError, "tooling unavailable for managed pkg"
      end
      fetcher = ToolingFetcher.new(client: raising)
      assert_equal [], fetcher.fetch_for("pkg__Foo__c")
    end

    test "escapes single quotes in api_name to prevent SOQL injection" do
      stub = StubToolingClient.new([])
      fetcher = ToolingFetcher.new(client: stub)
      fetcher.fetch_for("Foo'); DROP TABLE")

      # Original quote should be escaped in every emitted query.
      assert stub.queries.all? { |q| q.include?("Foo\\'); DROP TABLE") }, stub.queries.inspect
    end
  end
end
