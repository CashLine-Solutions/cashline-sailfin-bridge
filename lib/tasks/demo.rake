namespace :ontology do
  desc <<~DESC
    Seed two fake extraction runs with Sailfin-shaped objects so the UI can be
    exercised end-to-end without Salesforce credentials. Usage:
      bin/rails ontology:demo_data            # creates two runs assigned to first admin
      bin/rails ontology:demo_data RESET=1    # purges existing demo runs first
  DESC
  task demo_data: :environment do
    DemoSeeder.new(reset: ENV["RESET"] == "1").seed!
  end

  # Inline seeder. Idempotent: each call appends two new runs unless RESET=1.
  # The data is intentionally synthetic (no real Salesforce payloads) but
  # shaped like a Sailfin-style AR org: managed-package custom objects with
  # namespaces, formulas, picklists, lookups, and a few standard objects.
  class DemoSeeder
    NAMESPACE = "sailfin"

    OBJECTS_BASELINE = [
      { api: "Account",                          ns: nil,        label: "Account",            custom: false, fields: %i[name owner email phone industry created_date] },
      { api: "Contact",                          ns: nil,        label: "Contact",            custom: false, fields: %i[firstname lastname email phone account_ref] },
      { api: "Opportunity",                      ns: nil,        label: "Opportunity",        custom: false, fields: %i[name amount stage close_date account_ref] },
      { api: "User",                             ns: nil,        label: "User",               custom: false, fields: %i[username email firstname lastname] },
      { api: "#{NAMESPACE}__Brand__c",           ns: NAMESPACE,  label: "Brand",              custom: true,  fields: %i[name region brand_status] },
      { api: "#{NAMESPACE}__Invoice__c",         ns: NAMESPACE,  label: "Invoice",            custom: true,  fields: %i[invoice_number amount status due_date customer_ref invoice_total_calc] },
      { api: "#{NAMESPACE}__Invoice_Line__c",    ns: NAMESPACE,  label: "Invoice Line",       custom: true,  fields: %i[sku unit_price quantity line_total_calc invoice_ref] },
      { api: "#{NAMESPACE}__Customer__c",        ns: NAMESPACE,  label: "Customer",           custom: true,  fields: %i[customer_name credit_rating ssn_last4 tax_id account_ref] },
      { api: "#{NAMESPACE}__Payment__c",         ns: NAMESPACE,  label: "Payment",            custom: true,  fields: %i[amount method status invoice_ref] }
    ].freeze

    OBJECTS_NEXT_DELTAS = {
      # In run B: a new field appears on Invoice, picklist gains a value, formula changes.
      "#{NAMESPACE}__Invoice__c" => {
        added_fields: %i[notes],
        renamed_picklist: { field: :status, add: %w[Disputed], remove: %w[Void] },
        formula_change: :invoice_total_calc
      },
      # Invoice_Line gains a length increase on sku.
      "#{NAMESPACE}__Invoice_Line__c" => {
        length_change: { field: :sku, from: 40, to: 80 }
      },
      # New custom object appears in run B.
      added_object: { api: "#{NAMESPACE}__Statement__c", ns: NAMESPACE, label: "Statement", custom: true, fields: %i[name period_start period_end customer_ref] }
    }.freeze

    PICKLIST_VALUES = {
      industry:        %w[Retail Salon Wholesale Other],
      stage:           %w[Prospecting Qualified ClosedWon ClosedLost],
      brand_status:    %w[Active Paused Retired],
      status:          %w[Draft Sent Paid Void],
      credit_rating:   %w[A B C D Unrated],
      method:          %w[ACH Wire CreditCard Check]
    }.freeze

    SENSITIVITY = {
      email:         "pii",
      phone:         "pii",
      firstname:     "pii",
      lastname:      "pii",
      ssn_last4:     "pii",
      tax_id:        "pii_and_financial",
      credit_rating: "financial",
      amount:        "financial",
      invoice_total_calc: "financial",
      line_total_calc:    "financial",
      unit_price:    "financial"
    }.freeze

    def initialize(reset:)
      @reset = reset
      @user = User.where(role: :admin).order(:id).first
      abort "No admin user found. Run: bin/rails users:create_admin EMAIL=you@example.com" if @user.nil?
    end

    def seed!
      reset_demo_runs! if @reset

      run_a = build_run(label: "demo-baseline", completed_minutes_ago: 90)
      run_b = build_run(label: "demo-delta",    completed_minutes_ago: 5)
      seed_objects!(run_a, baseline: true)
      seed_objects!(run_b, baseline: false)

      puts "Demo runs created:"
      puts "  Run A (baseline): #{run_a.directory_token}  -> http://localhost:3000/runs/#{run_a.id}"
      puts "  Run B (delta):    #{run_b.directory_token}  -> http://localhost:3000/runs/#{run_b.id}"
      puts ""
      puts "Try:"
      puts "  /objects/Account?run=#{run_b.id}"
      puts "  /erds?run=#{run_b.id}"
      puts "  /graph?run=#{run_b.id}"
      puts "  /diffs/new  (then pick A and B)"
    end

    private

    def reset_demo_runs!
      ExtractionRun.where("directory_token LIKE ?", "demo-%").find_each(&:destroy)
    end

    def build_run(label:, completed_minutes_ago:)
      run = ExtractionRun.new(
        user: @user,
        api_version: "62.0",
        seed_objects: %w[Account Contact Opportunity],
        status: "complete",
        started_at: completed_minutes_ago.minutes.ago - 2.minutes,
        completed_at: completed_minutes_ago.minutes.ago,
        installed_packages: [{ "namespace" => NAMESPACE, "version" => label == "demo-baseline" ? "2.4" : "2.5" }],
        directory_token: "#{label}-#{SecureRandom.hex(2)}"
      )
      run.save!
      run
    end

    def seed_objects!(run, baseline:)
      objects = OBJECTS_BASELINE.map(&:dup)
      unless baseline
        objects << OBJECTS_NEXT_DELTAS[:added_object]
      end

      created_objects = {}
      objects.each { |spec| created_objects[spec[:api]] = create_sobject(run, spec, baseline: baseline) }

      seed_relationships!(run, created_objects)
      seed_profiles!(run, created_objects)
    end

    def create_sobject(run, spec, baseline:)
      sobject = Sobject.create!(
        extraction_run: run,
        api_name: spec[:api],
        label: spec[:label],
        namespace_prefix: spec[:ns],
        custom: spec[:custom],
        raw_describe: { "name" => spec[:api] }
      )

      delta = OBJECTS_NEXT_DELTAS[spec[:api]] || {}
      field_keys = spec[:fields].dup
      field_keys += delta[:added_fields] || [] unless baseline

      field_keys.each do |fkey|
        create_sfield(sobject, fkey, baseline: baseline, deltas: delta)
      end

      sobject
    end

    def create_sfield(sobject, fkey, baseline:, deltas:)
      type, length, calculated, formula = field_shape(fkey)
      if deltas[:length_change] && deltas[:length_change][:field] == fkey
        length = baseline ? deltas[:length_change][:from] : deltas[:length_change][:to]
      end
      formula = "Amount - Tax /* updated */" if !baseline && deltas[:formula_change] == fkey

      sfield = Sfield.create!(
        sobject: sobject,
        api_name: salesforce_api_name(sobject, fkey),
        label: fkey.to_s.titleize,
        data_type: type,
        length: length,
        calculated: calculated,
        calculated_formula: formula,
        sensitivity: SENSITIVITY.fetch(fkey, "safe"),
        raw_describe: { "name" => fkey.to_s }
      )

      if (values = picklist_for(fkey))
        if !baseline && deltas[:renamed_picklist] && deltas[:renamed_picklist][:field] == fkey
          values = values - deltas[:renamed_picklist][:remove] + deltas[:renamed_picklist][:add]
        end
        values.each { |v| SpicklistValue.create!(sfield: sfield, value: v, active: true) }
        sfield.update!(picklist_count: values.size)
      end

      sfield
    end

    def field_shape(fkey)
      case fkey
      when :email, :firstname, :lastname, :username, :name, :customer_name, :region, :sku, :notes, :invoice_number
        ["string", 80, false, nil]
      when :phone, :ssn_last4, :tax_id
        ["string", 40, false, nil]
      when :amount, :unit_price
        ["currency", nil, false, nil]
      when :quantity
        ["double", nil, false, nil]
      when :due_date, :close_date, :period_start, :period_end, :created_date
        ["datetime", nil, false, nil]
      when :status, :brand_status, :stage, :credit_rating, :method, :industry
        ["picklist", 40, false, nil]
      when :owner, :account_ref, :customer_ref, :invoice_ref
        ["reference", 18, false, nil]
      when :invoice_total_calc
        ["currency", nil, true, "Amount + Tax"]
      when :line_total_calc
        ["currency", nil, true, "UnitPrice * Quantity"]
      else
        ["string", 255, false, nil]
      end
    end

    def picklist_for(fkey)
      PICKLIST_VALUES[fkey]
    end

    def salesforce_api_name(sobject, fkey)
      base = case fkey
             when :firstname then "FirstName"
             when :lastname  then "LastName"
             when :owner     then "OwnerId"
             when :account_ref then "AccountId"
             when :customer_ref then "Customer__c"
             when :invoice_ref then "Invoice__c"
             when :due_date then "DueDate__c"
             when :created_date then "CreatedDate"
             else
               fkey.to_s.split("_").map(&:capitalize).join
             end
      sobject.custom ? "#{base}__c" : base
    end

    def seed_relationships!(run, sobjects)
      pairs = [
        ["Contact",                    "Account",                       "AccountId"],
        ["Opportunity",                "Account",                       "AccountId"],
        ["#{NAMESPACE}__Invoice__c",   "#{NAMESPACE}__Customer__c",     "Customer__c"],
        ["#{NAMESPACE}__Invoice_Line__c", "#{NAMESPACE}__Invoice__c",   "Invoice__c"],
        ["#{NAMESPACE}__Payment__c",   "#{NAMESPACE}__Invoice__c",      "Invoice__c"],
        ["#{NAMESPACE}__Customer__c",  "Account",                       "AccountId"]
      ]
      pairs.each do |src, tgt, _name|
        next unless sobjects[src] && sobjects[tgt]
        Srelationship.create!(
          extraction_run: run,
          source_sobject: sobjects[src],
          target_sobject: sobjects[tgt],
          relationship_name: _name,
          polymorphic: false
        )
      end

      # If Statement__c exists (run B only), wire it to Customer__c
      if (stmt = sobjects["#{NAMESPACE}__Statement__c"])
        Srelationship.create!(
          extraction_run: run,
          source_sobject: stmt,
          target_sobject: sobjects["#{NAMESPACE}__Customer__c"],
          relationship_name: "Customer__c",
          polymorphic: false
        )
      end
    end

    def seed_profiles!(run, sobjects)
      sobjects.each_value do |sobj|
        profile = ObjectProfile.create!(
          extraction_run: run,
          sobject: sobj,
          status: "complete",
          record_count: rand(50..50_000),
          profiled_at: Time.current
        )

        sobj.sfields.includes(:spicklist_values).each do |sf|
          fp_attrs = {
            object_profile: profile,
            sfield: sf,
            null_rate: rand_null_rate(sf),
            distinct_count: rand(1..1_000),
            min_length: sf.length.present? ? 1 : nil,
            max_length: sf.length,
            top_values: top_values_for(sf),
            sample_values: sample_values_for(sf)
          }
          FieldProfile.create!(fp_attrs)
        end
      end
    end

    def rand_null_rate(sfield)
      # Unused-looking fields for the report view to have signal
      case sfield.api_name
      when /Notes/ then 0.99
      when /Tax/   then 0.92
      else rand(0.0..0.6).round(2)
      end
    end

    def top_values_for(sfield)
      case sfield.data_type
      when "picklist" then sfield.spicklist_values.map { |v| { "value" => v.value, "count" => rand(50..500) } }
      when "string"   then (1..5).map { |i| { "value" => "#{sfield.label}-#{i}", "count" => rand(10..200) } }
      else []
      end
    end

    def sample_values_for(sfield)
      case sfield.data_type
      when "string", "picklist"
        (sfield.spicklist_values.first(3).map(&:value)).presence || %w[Sample-1 Sample-2 Sample-3]
      when "currency", "double"
        [rand(100..10_000).to_s, rand(100..10_000).to_s, rand(100..10_000).to_s]
      else
        []
      end
    end
  end
end
