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
      responses = [
        [ "FROM CustomField", [
          { "Id" => "00N", "DeveloperName" => "Margin", "Metadata" => { "formula" => "Amount__c - Cost__c" } },
          { "Id" => "00P", "DeveloperName" => "Plain", "Metadata" => { "formula" => nil } }
        ] ],
        [ "FROM ValidationRule", [] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))

      records = fetcher.fetch_for("Account")
      formulas = records.select { |r| r["record_type"] == "tooling_field_metadata" }

      assert_equal 1, formulas.size
      assert_equal "Margin", formulas.first["field_developer_name"]
      assert_equal "Amount__c - Cost__c", formulas.first["formula"]
    end

    test "returns a tooling_validation_rule record for each rule with error formula" do
      responses = [
        [ "FROM CustomField", [] ],
        [ "FROM ValidationRule", [
          { "Id" => "03V", "ValidationName" => "NonZero", "Metadata" => { "errorConditionFormula" => "Amount__c == 0" } }
        ] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))

      records = fetcher.fetch_for("Account")
      rules = records.select { |r| r["record_type"] == "tooling_validation_rule" }

      assert_equal 1, rules.size
      assert_equal "NonZero", rules.first["rule_name"]
    end

    test "object with no formula fields and no rules returns empty array" do
      responses = [
        [ "FROM CustomField", [] ],
        [ "FROM ValidationRule", [] ]
      ]
      fetcher = ToolingFetcher.new(client: StubToolingClient.new(responses))
      assert_equal [], fetcher.fetch_for("Account")
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
