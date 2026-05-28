require "test_helper"
require "ostruct"

module Salesforce
  class RecordTypePicklistFetcherTest < ActiveSupport::TestCase
    class StubRestClient
      attr_reader :paths
      def initialize(body)
        @body = body
        @paths = []
      end

      def get(path)
        @paths << path
        OpenStruct.new(body: @body)
      end
    end

    LAYOUTS_BODY = {
      "recordTypeMappings" => [
        {
          "recordTypeId" => "012AAA",
          "name" => "Customer",
          "available" => true,
          "picklistsForRecordType" => [
            {
              "picklistName" => "Industry",
              "picklistValues" => [
                { "value" => "Agriculture", "active" => true },
                { "value" => "Technology", "active" => true },
                { "value" => "Retired", "active" => false }
              ]
            }
          ]
        },
        {
          "recordTypeId" => "012MASTER",
          "name" => "Master",
          "available" => true,
          "picklistsForRecordType" => []
        }
      ]
    }.freeze

    test "parses per-record-type picklist availability, dropping inactive values" do
      client = StubRestClient.new(LAYOUTS_BODY)
      record = RecordTypePicklistFetcher.new(client: client, api_version: "62.0").fetch_for("Account")

      assert_equal "record_type_picklists", record["record_type"]
      assert_equal "Account", record["api_name"]
      # The Master mapping has no picklists → dropped; only Customer remains.
      assert_equal 1, record["mappings"].size

      customer = record["mappings"].first
      assert_equal "012AAA", customer["record_type_id"]
      assert_equal %w[Agriculture Technology], customer["picklists"]["Industry"]
    end

    test "hits the describe/layouts endpoint for the object" do
      client = StubRestClient.new(LAYOUTS_BODY)
      RecordTypePicklistFetcher.new(client: client, api_version: "62.0").fetch_for("Account")

      assert_equal [ "/services/data/v62.0/sobjects/Account/describe/layouts/" ], client.paths
    end

    test "returns nil when there are no record type mappings" do
      client = StubRestClient.new({ "recordTypeMappings" => [] })
      assert_nil RecordTypePicklistFetcher.new(client: client).fetch_for("Account")
    end

    test "degrades to nil when the layouts call raises" do
      raising = Object.new
      def raising.get(_path) = raise StandardError, "no layout access"
      assert_nil RecordTypePicklistFetcher.new(client: raising).fetch_for("pkg__Foo__c")
    end
  end
end
