require "test_helper"

module Ontology
  class DiffCalculatorTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email_address: "d@example.com", password: "secret-pass-1", role: :analyst)
      @run_a = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: [], include_sensitive: false)
      @run_b = ExtractionRun.create!(api_version: "62.0", user: @user, seed_objects: [], include_sensitive: false)
    end

    test "field added between runs surfaces in field_added with api_name" do
      old_account = Sobject.create!(extraction_run: @run_a, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: old_account, api_name: "Name", data_type: "string", raw_describe: {})

      new_account = Sobject.create!(extraction_run: @run_b, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: new_account, api_name: "Name", data_type: "string", raw_describe: {})
      Sfield.create!(sobject: new_account, api_name: "Custom__c", data_type: "string", raw_describe: {})

      diff = DiffCalculator.compute(@run_a, @run_b)

      assert_equal 1, diff["field_added"].size
      assert_equal "Custom__c", diff["field_added"].first["field"]
      assert_equal "Account", diff["field_added"].first["object"]
      assert_empty diff["field_removed"]
    end

    test "renamed picklist value yields both added and removed" do
      old_acc = Sobject.create!(extraction_run: @run_a, api_name: "Account", raw_describe: {})
      old_field = Sfield.create!(sobject: old_acc, api_name: "Status", data_type: "picklist", raw_describe: {})
      %w[New Open Closed].each { |v| SpicklistValue.create!(sfield: old_field, value: v, active: true) }

      new_acc = Sobject.create!(extraction_run: @run_b, api_name: "Account", raw_describe: {})
      new_field = Sfield.create!(sobject: new_acc, api_name: "Status", data_type: "picklist", raw_describe: {})
      %w[New Open Resolved].each { |v| SpicklistValue.create!(sfield: new_field, value: v, active: true) }

      diff = DiffCalculator.compute(@run_a, @run_b)

      assert_equal [ { "object" => "Account", "field" => "Status", "values" => [ "Resolved" ] } ], diff["picklist_values_added"]
      assert_equal [ { "object" => "Account", "field" => "Status", "values" => [ "Closed" ] } ], diff["picklist_values_removed"]
    end

    test "identical schemas produce an empty diff" do
      [ @run_a, @run_b ].each do |run|
        acc = Sobject.create!(extraction_run: run, api_name: "Account", raw_describe: {})
        Sfield.create!(sobject: acc, api_name: "Name", data_type: "string", raw_describe: {})
        Sfield.create!(sobject: acc, api_name: "Email", data_type: "email", raw_describe: {})
      end

      record = RunDiff.new(diff: DiffCalculator.compute(@run_a, @run_b))
      assert_predicate record, :empty?
    end

    test "formula text differing only in whitespace is not flagged" do
      old_acc = Sobject.create!(extraction_run: @run_a, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: old_acc, api_name: "Total__c", data_type: "currency", calculated: true,
                     calculated_formula: "Amount + Tax", raw_describe: {})

      new_acc = Sobject.create!(extraction_run: @run_b, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: new_acc, api_name: "Total__c", data_type: "currency", calculated: true,
                     calculated_formula: "Amount   +   Tax\n", raw_describe: {})

      diff = DiffCalculator.compute(@run_a, @run_b)
      assert_empty diff["formula_logic_changed"]
    end

    test "formula text with real logic change is flagged" do
      old_acc = Sobject.create!(extraction_run: @run_a, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: old_acc, api_name: "Total__c", data_type: "currency", calculated: true,
                     calculated_formula: "Amount + Tax", raw_describe: {})

      new_acc = Sobject.create!(extraction_run: @run_b, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: new_acc, api_name: "Total__c", data_type: "currency", calculated: true,
                     calculated_formula: "Amount - Tax", raw_describe: {})

      diff = DiffCalculator.compute(@run_a, @run_b)
      assert_equal [ { "object" => "Account", "field" => "Total__c" } ], diff["formula_logic_changed"]
    end

    test "object added and removed are categorized separately" do
      Sobject.create!(extraction_run: @run_a, api_name: "Old", raw_describe: {})
      Sobject.create!(extraction_run: @run_b, api_name: "New", raw_describe: {})

      diff = DiffCalculator.compute(@run_a, @run_b)
      assert_equal [ "New" ], diff["object_added"]
      assert_equal [ "Old" ], diff["object_removed"]
    end

    test "relationship added between runs surfaces in relationship_added" do
      [ @run_a, @run_b ].each do |run|
        a = Sobject.create!(extraction_run: run, api_name: "Account", raw_describe: {})
        c = Sobject.create!(extraction_run: run, api_name: "Contact", raw_describe: {})
        if run == @run_b
          Srelationship.create!(extraction_run: run, source_sobject: c, target_sobject: a, relationship_name: "Account")
        end
      end

      diff = DiffCalculator.compute(@run_a, @run_b)
      assert_equal 1, diff["relationship_added"].size
      assert_equal "Contact", diff["relationship_added"].first["source"]
      assert_equal "Account", diff["relationship_added"].first["target"]
      assert_empty diff["relationship_removed"]
    end

    test "installed_package_changes surfaces added, removed, and version changes" do
      @run_a.update!(installed_packages: [
        { "namespace" => "sailfin", "version" => "1.0" },
        { "namespace" => "legacy", "version" => "0.5" }
      ])
      @run_b.update!(installed_packages: [
        { "namespace" => "sailfin", "version" => "1.2" },
        { "namespace" => "new_pkg", "version" => "0.1" }
      ])

      diff = DiffCalculator.compute(@run_a, @run_b)

      assert_equal [ "new_pkg" ], diff["installed_package_changes"]["added"]
      assert_equal [ "legacy" ], diff["installed_package_changes"]["removed"]
      assert_equal [ { "namespace" => "sailfin", "from" => "1.0", "to" => "1.2" } ],
                   diff["installed_package_changes"]["version_changed"]
    end

    test "computation is deterministic across calls" do
      acc_a = Sobject.create!(extraction_run: @run_a, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: acc_a, api_name: "Name", data_type: "string", raw_describe: {})

      acc_b = Sobject.create!(extraction_run: @run_b, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: acc_b, api_name: "Name", data_type: "string", raw_describe: {})
      Sfield.create!(sobject: acc_b, api_name: "Email__c", data_type: "email", raw_describe: {})

      first = DiffCalculator.compute(@run_a, @run_b)
      second = DiffCalculator.compute(@run_a, @run_b)
      assert_equal first, second
    end

    test "field_type_changed and field_length_changed are reported" do
      old_acc = Sobject.create!(extraction_run: @run_a, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: old_acc, api_name: "Name", data_type: "string", length: 80, raw_describe: {})

      new_acc = Sobject.create!(extraction_run: @run_b, api_name: "Account", raw_describe: {})
      Sfield.create!(sobject: new_acc, api_name: "Name", data_type: "textarea", length: 255, raw_describe: {})

      diff = DiffCalculator.compute(@run_a, @run_b)
      assert_equal [ { "object" => "Account", "field" => "Name", "from" => "string", "to" => "textarea" } ],
                   diff["field_type_changed"]
      assert_equal [ { "object" => "Account", "field" => "Name", "from" => 80, "to" => 255 } ],
                   diff["field_length_changed"]
    end

    test "polymorphic relationship diff does not crash on nil target" do
      a_task = Sobject.create!(extraction_run: @run_a, api_name: "Task", raw_describe: {})
      a_acct = Sobject.create!(extraction_run: @run_a, api_name: "Account", raw_describe: {})
      Srelationship.create!(extraction_run: @run_a, source_sobject: a_task, target_sobject: a_acct,
                            relationship_name: "What", polymorphic: false, reference_to_api_names: [ "Account" ])

      b_task = Sobject.create!(extraction_run: @run_b, api_name: "Task", raw_describe: {})
      Sobject.create!(extraction_run: @run_b, api_name: "Account", raw_describe: {})
      # Polymorphic ref with no concrete target_sobject — target_sobject_id NULL
      # is the production shape of multi-reference fields like Task.WhatId.
      Srelationship.create!(extraction_run: @run_b, source_sobject: b_task, target_sobject: nil,
                            relationship_name: "WhatId", polymorphic: true,
                            reference_to_api_names: %w[Account Opportunity Contract])

      assert_nothing_raised do
        diff = DiffCalculator.compute(@run_a, @run_b)
        assert diff["relationship_added"].is_a?(Array)
        assert diff["relationship_removed"].is_a?(Array)
      end
    end
  end
end
