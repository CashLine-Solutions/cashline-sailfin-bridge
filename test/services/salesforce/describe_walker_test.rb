require "test_helper"

module Salesforce
  class DescribeWalkerTest < ActiveSupport::TestCase
    # A minimal stand-in for the Restforce client surface DescribeWalker uses.
    # The walker calls `client.describe(api_name)` and expects the response to
    # quack like a Restforce describe (responds to [] and has a 'fields' array).
    class StubClient
      def initialize(payloads)
        @payloads = payloads
        @calls = []
      end
      attr_reader :calls

      def describe(api_name)
        @calls << api_name
        payload = @payloads[api_name] or raise "no stub describe for #{api_name}"
        payload
      end
    end

    def describe_payload(name:, namespace: nil, fields:)
      {
        "name" => name,
        "label" => name,
        "namespacePrefix" => namespace,
        "custom" => name.include?("__c"),
        "fields" => fields
      }
    end

    def reference_field(name:, references_to:, relationship_name: nil)
      {
        "name" => name,
        "label" => name,
        "type" => "reference",
        "referenceTo" => Array(references_to),
        "relationshipName" => relationship_name || name.sub(/Id\z/, "")
      }
    end

    def text_field(name:, type: "string")
      { "name" => name, "label" => name, "type" => type }
    end

    test "max_hops=2 across allowlisted seed -> B -> C visits all three" do
      payloads = {
        "A" => describe_payload(name: "A", fields: [ reference_field(name: "BId", references_to: "B") ]),
        "B" => describe_payload(name: "B", fields: [ reference_field(name: "CId", references_to: "C") ]),
        "C" => describe_payload(name: "C", fields: [ text_field(name: "Name") ])
      }
      walker = DescribeWalker.new(
        client: StubClient.new(payloads),
        seed_objects: %w[A],
        namespace_allowlist: [ nil ],
        standard_allowlist: %w[A B C],
        max_hops: 2
      )

      result = walker.walk
      assert_equal %w[A B C].sort, result.visited.sort
      assert_includes result.edges, { source: "A", target: "B", field: "BId" }
      assert_includes result.edges, { source: "B", target: "C", field: "CId" }
    end

    test "max_hops=1 limits the walk to A and its direct neighbors" do
      payloads = {
        "A" => describe_payload(name: "A", fields: [ reference_field(name: "BId", references_to: "B") ]),
        "B" => describe_payload(name: "B", fields: [ reference_field(name: "CId", references_to: "C") ])
      }
      walker = DescribeWalker.new(
        client: StubClient.new(payloads),
        seed_objects: %w[A],
        namespace_allowlist: [ nil ],
        standard_allowlist: %w[A B C],
        max_hops: 1
      )

      result = walker.walk
      assert_equal %w[A B].sort, result.visited.sort
    end

    test "relationship to an out-of-allowlist object terminates at the gateway" do
      payloads = {
        "A" => describe_payload(name: "A", fields: [ reference_field(name: "DropMeId", references_to: "DropMe__c") ])
      }
      walker = DescribeWalker.new(
        client: StubClient.new(payloads),
        seed_objects: %w[A],
        namespace_allowlist: [ "sailfin" ], # excludes the lookup target
        standard_allowlist: %w[A],
        max_hops: 3
      )

      result = walker.walk
      assert_equal %w[A], result.visited
      assert_equal [], result.edges
    end

    test "self-referential relationships do not infinite-loop" do
      payloads = {
        "A" => describe_payload(name: "A", fields: [ reference_field(name: "ParentId", references_to: "A") ])
      }
      walker = DescribeWalker.new(
        client: StubClient.new(payloads),
        seed_objects: %w[A],
        namespace_allowlist: [ nil ],
        standard_allowlist: %w[A],
        max_hops: 5
      )

      result = walker.walk
      assert_equal %w[A], result.visited
      assert_equal 1, result.edges.size
    end

    test "polymorphic references walk every in-scope target" do
      payloads = {
        "Task" => describe_payload(name: "Task", fields: [
          reference_field(name: "WhatId", references_to: %w[Account Opportunity])
        ]),
        "Account" => describe_payload(name: "Account", fields: []),
        "Opportunity" => describe_payload(name: "Opportunity", fields: [])
      }
      walker = DescribeWalker.new(
        client: StubClient.new(payloads),
        seed_objects: %w[Task],
        namespace_allowlist: [ nil ],
        standard_allowlist: %w[Task Account Opportunity],
        max_hops: 1
      )

      result = walker.walk
      assert_equal %w[Account Opportunity Task].sort, result.visited.sort
    end

    test "each object is described exactly once even if reached from two seeds" do
      payloads = {
        "A" => describe_payload(name: "A", fields: [ reference_field(name: "CId", references_to: "C") ]),
        "B" => describe_payload(name: "B", fields: [ reference_field(name: "CId", references_to: "C") ]),
        "C" => describe_payload(name: "C", fields: [])
      }
      stub = StubClient.new(payloads)
      walker = DescribeWalker.new(
        client: stub,
        seed_objects: %w[A B],
        namespace_allowlist: [ nil ],
        standard_allowlist: %w[A B C],
        max_hops: 1
      )

      walker.walk
      assert_equal 1, stub.calls.count("C")
    end

    class FlakyClient
      def initialize(payloads, failures)
        @payloads = payloads
        @failures = failures
      end
      def describe(api_name)
        raise @failures[api_name] if @failures.key?(api_name)
        @payloads[api_name] or raise "no stub describe for #{api_name}"
      end
    end

    test "single inaccessible object becomes a partial failure and walk continues" do
      payloads = {
        "A" => describe_payload(name: "A", fields: [ reference_field(name: "BId", references_to: "B") ]),
        "C" => describe_payload(name: "C", fields: [])
      }
      failures = { "B" => StandardError.new("FLS denied") }
      walker = DescribeWalker.new(
        client: FlakyClient.new(payloads, failures),
        seed_objects: %w[A C],
        namespace_allowlist: [ nil ],
        standard_allowlist: %w[A B C],
        max_hops: 2
      )

      result = walker.walk

      # A and C visited; B failed and was not added to describes
      assert_includes result.visited, "A"
      assert_includes result.visited, "C"
      refute_includes result.visited, "B"

      assert_equal 1, result.partial_failures.size
      assert_equal "B", result.partial_failures.first[:object_api_name]
      assert_match(/FLS denied/, result.partial_failures.first[:reason])
    end
  end
end
