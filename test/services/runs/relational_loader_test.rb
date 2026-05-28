require "test_helper"
require "fileutils"

module Runs
  class RelationalLoaderTest < ActiveSupport::TestCase
    setup do
      @tmp_root = Rails.root.join("tmp", "test", "relational_loader", SecureRandom.hex(4))
      FileUtils.mkdir_p(@tmp_root)
      RunDirectory.singleton_class.send(:define_method, :default_root) { @test_root }
      RunDirectory.instance_variable_set(:@test_root, @tmp_root)

      @run = ExtractionRun.create!(api_version: "62.0", seed_objects: %w[Account])
      @rd = RunDirectory.for(@run)
      @rd.ensure!
    end

    teardown do
      RunDirectory.singleton_class.send(:remove_method, :default_root)
      FileUtils.rm_rf(@tmp_root)
    end

    def seed_jsonl(api_name, describe_payload, tooling_records: [])
      @rd.append_jsonl!(@rd.object_jsonl_path(api_name), {
        "record_type" => "describe",
        "api_name" => api_name,
        "payload" => describe_payload
      })
      tooling_records.each do |t|
        @rd.append_jsonl!(@rd.object_jsonl_path(api_name), t)
      end
    end

    test "loads 3 objects, 50 fields, and the right relationship rows" do
      seed_jsonl("Account", {
        "name" => "Account",
        "label" => "Account",
        "fields" => (1..30).map { |i| { "name" => "F#{i}", "type" => "string", "label" => "F#{i}" } } +
          [ { "name" => "OwnerId", "type" => "reference", "referenceTo" => %w[User], "relationshipName" => "Owner" } ]
      })
      seed_jsonl("Contact", {
        "name" => "Contact",
        "label" => "Contact",
        "fields" => (1..18).map { |i| { "name" => "G#{i}", "type" => "string", "label" => "G#{i}" } } +
          [ { "name" => "AccountId", "type" => "reference", "referenceTo" => %w[Account], "relationshipName" => "Account" } ]
      })
      seed_jsonl("User", {
        "name" => "User",
        "label" => "User",
        "fields" => []
      })

      RelationalLoader.load!(@run)

      assert_equal 3, @run.sobjects.count
      total_fields = Sfield.joins(:sobject).where(sobjects: { extraction_run_id: @run.id }).count
      assert_equal 30 + 1 + 18 + 1 + 0, total_fields
      assert_equal 2, @run.srelationships.count
    end

    test "re-loading the same run replaces rows without duplicating" do
      seed_jsonl("Account", {
        "name" => "Account", "fields" => [ { "name" => "Name", "type" => "string" } ]
      })
      RelationalLoader.load!(@run)
      first_field_id = Sfield.first.id

      # Add a record, re-load.
      RelationalLoader.load!(@run)

      assert_equal 1, @run.sobjects.count
      assert_equal 1, Sfield.joins(:sobject).where(sobjects: { extraction_run_id: @run.id }).count
      refute_equal first_field_id, Sfield.first.id, "expected rows to be replaced"
    end

    test "polymorphic lookup creates one row with polymorphic=true" do
      seed_jsonl("Task", {
        "name" => "Task",
        "fields" => [
          { "name" => "WhatId", "type" => "reference", "referenceTo" => %w[Account Opportunity], "relationshipName" => "What" }
        ]
      })
      seed_jsonl("Account", { "name" => "Account", "fields" => [] })
      seed_jsonl("Opportunity", { "name" => "Opportunity", "fields" => [] })

      RelationalLoader.load!(@run)

      rels = @run.srelationships
      assert_equal 1, rels.count
      assert rels.first.polymorphic
      assert_equal %w[Account Opportunity], rels.first.reference_to_api_names
    end

    test "picklist values are persisted with active and default_value flags" do
      seed_jsonl("Account", {
        "name" => "Account",
        "fields" => [
          {
            "name" => "Status__c", "type" => "picklist", "label" => "Status",
            "picklistValues" => [
              { "value" => "Active", "label" => "Active", "active" => true, "defaultValue" => true },
              { "value" => "Inactive", "label" => "Inactive", "active" => false, "defaultValue" => false }
            ]
          }
        ]
      })

      RelationalLoader.load!(@run)

      field = Sfield.find_by(api_name: "Status__c")
      assert_equal 2, field.spicklist_values.count
      assert_equal 2, field.picklist_count
      assert field.spicklist_values.find_by(value: "Active").default_value
      refute field.spicklist_values.find_by(value: "Inactive").active
    end

    test "record types load from recordTypeInfos, skipping Master, with scoped picklists attached" do
      seed_jsonl("Account", {
        "name" => "Account",
        "fields" => [ { "name" => "Industry", "type" => "picklist" } ],
        "recordTypeInfos" => [
          { "recordTypeId" => "012MASTER", "name" => "Master", "developerName" => "Master", "master" => true },
          { "recordTypeId" => "012CUST", "name" => "Customer", "developerName" => "Customer",
            "master" => false, "available" => true, "defaultRecordTypeMapping" => true }
        ]
      }, tooling_records: [
        { "record_type" => "record_type_picklists", "api_name" => "Account", "mappings" => [
          { "record_type_id" => "012CUST", "name" => "Customer",
            "picklists" => { "Industry" => %w[Agriculture Technology] } }
        ] }
      ])

      RelationalLoader.load!(@run)

      sobject = Sobject.find_by(api_name: "Account")
      assert_equal 1, sobject.srecord_types.count, "Master should be skipped"
      rt = sobject.srecord_types.first
      assert_equal "Customer", rt.developer_name
      assert rt.default_mapping
      assert_equal %w[Agriculture Technology], rt.picklist_values["Industry"]
    end

    test "object with only the Master record type gets no srecord_types rows" do
      seed_jsonl("Account", {
        "name" => "Account",
        "fields" => [],
        "recordTypeInfos" => [
          { "recordTypeId" => "012MASTER", "name" => "Master", "master" => true }
        ]
      })

      RelationalLoader.load!(@run)

      assert_equal 0, Sobject.find_by(api_name: "Account").srecord_types.count
    end

    test "FieldDefinition compliance metadata is stored and drives sensitivity" do
      seed_jsonl("Account", {
        "name" => "Account",
        "fields" => [ { "name" => "Opaque__c", "type" => "string", "label" => "Opaque" } ]
      }, tooling_records: [
        { "record_type" => "tooling_field_compliance", "api_name" => "Account",
          "field_api_name" => "Opaque__c", "compliance_group" => "PII", "security_classification" => "Restricted" }
      ])

      RelationalLoader.load!(@run)

      field = Sfield.find_by(api_name: "Opaque__c")
      assert_equal "PII", field.compliance_group
      assert_equal "Restricted", field.security_classification
      # Heuristics alone would call this name `safe`; the admin override wins.
      assert_equal "pii_and_financial", field.sensitivity
    end

    test "calculated formula from tooling record is attached to the field" do
      seed_jsonl("Account", {
        "name" => "Account",
        "fields" => [
          { "name" => "Margin__c", "type" => "currency", "calculated" => true, "label" => "Margin" }
        ]
      }, tooling_records: [
        { "record_type" => "tooling_field_metadata", "field_api_name" => "Margin__c", "field_developer_name" => "Margin", "formula" => "Amount__c - Cost__c" }
      ])

      RelationalLoader.load!(@run)

      field = Sfield.find_by(api_name: "Margin__c")
      assert_equal "Amount__c - Cost__c", field.calculated_formula
      assert field.tooling_metadata.present?
    end
  end
end
