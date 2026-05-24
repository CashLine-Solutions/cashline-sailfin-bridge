require "json"

module Runs
  # Walks the per-object JSONL files of a completed extraction run and loads
  # them into the normalized `sobjects` / `sfields` / `srelationships` /
  # `spicklist_values` tables in the primary DB.
  #
  # Idempotent per run: re-running deletes the existing rows for that
  # extraction_run_id and re-inserts. Field rows are anchored by sobject_id
  # so the cascade is straightforward.
  class RelationalLoader
    def self.load!(run)
      new(run).load!
    end

    def initialize(run)
      @run = run
      @rd = RunDirectory.for(run)
    end

    def load!
      clear_existing_rows!

      ApplicationRecord.transaction do
        loaded_objects = {}

        each_object_jsonl do |api_name, records|
          describe_record = records.find { |r| r["record_type"] == "describe" }
          next unless describe_record

          payload = describe_record["payload"] || describe_record # legacy shape support
          tooling_records = records.select { |r| %w[tooling_field_metadata tooling_validation_rule].include?(r["record_type"]) }

          sobject = upsert_sobject(api_name, payload)
          loaded_objects[api_name] = sobject

          load_fields(sobject, payload, tooling_records)
        end

        load_relationships(loaded_objects)
      end

      @run
    end

    private

    def clear_existing_rows!
      # FK cascade handles sfields and spicklist_values via dependent: :destroy
      # at the AR layer, but we use delete_all here for speed since we re-run
      # the whole run in one transaction.
      sobject_ids = Sobject.where(extraction_run_id: @run.id).pluck(:id)
      sfield_ids = Sfield.where(sobject_id: sobject_ids).pluck(:id)

      SpicklistValue.where(sfield_id: sfield_ids).delete_all
      Srelationship.where(extraction_run_id: @run.id).delete_all
      Sfield.where(id: sfield_ids).delete_all
      Sobject.where(id: sobject_ids).delete_all
    end

    def each_object_jsonl
      return enum_for(:each_object_jsonl) unless block_given?

      Dir.glob(@rd.root.join("*.jsonl")).each do |path|
        next if path.end_with?(".profile.jsonl") # those belong to ProfileObjectJob
        api_name = File.basename(path, ".jsonl")
        records = File.readlines(path).filter_map do |line|
          line.strip.empty? ? nil : JSON.parse(line)
        end
        yield(api_name, records)
      end
    end

    def upsert_sobject(api_name, payload)
      Sobject.create!(
        extraction_run: @run,
        api_name: payload["name"] || api_name,
        label: payload["label"],
        namespace_prefix: payload["namespacePrefix"],
        custom: !!payload["custom"],
        is_name_field: Array(payload["fields"]).any? { |f| f["nameField"] },
        raw_describe: payload
      )
    end

    def load_fields(sobject, payload, tooling_records)
      Array(payload["fields"]).each do |field|
        formula = nil
        tooling_for_field = tooling_records.find { |t| t["field_developer_name"].to_s == field["name"].to_s.sub(/__c\z/, "") }
        formula = tooling_for_field["formula"] if tooling_for_field

        sensitivity = Ontology::SensitivityClassifier.classify(
          field: field,
          sobject_describe: payload,
          compliance_group: tooling_for_field && tooling_for_field["compliance_group"]
        )

        sfield = Sfield.create!(
          sobject: sobject,
          api_name: field["name"],
          label: field["label"],
          data_type: field["type"],
          length: field["length"],
          nillable: field.fetch("nillable", true),
          calculated: !!field["calculated"],
          calculated_formula: formula,
          encrypted: !!field["encrypted"],
          name_field: !!field["nameField"],
          compound_field_name: field["compoundFieldName"],
          picklist_count: Array(field["picklistValues"]).size,
          references_count: Array(field["referenceTo"]).size,
          namespace_prefix: field["namespacePrefix"],
          accessible: field.fetch("accessible", true),
          createable: field.fetch("createable", true),
          updateable: field.fetch("updateable", true),
          filterable: field.fetch("filterable", true),
          raw_describe: field,
          tooling_metadata: tooling_for_field,
          sensitivity: sensitivity[:sensitivity],
          sensitivity_signals: sensitivity[:signals]
        )

        Array(field["picklistValues"]).each do |pv|
          SpicklistValue.create!(
            sfield: sfield,
            value: pv["value"],
            label: pv["label"],
            active: pv.fetch("active", true),
            default_value: !!pv["defaultValue"]
          )
        end
      end
    end

    def load_relationships(loaded_objects)
      loaded_objects.each do |source_api, source_sobject|
        Array(source_sobject.raw_describe["fields"]).each do |field|
          next unless field["type"] == "reference"

          targets = Array(field["referenceTo"])
          source_field = source_sobject.sfields.find_by(api_name: field["name"])
          polymorphic = targets.size > 1

          # For polymorphic refs we create ONE row with reference_to_api_names
          # populated and target_sobject_id NULL when no single target applies.
          if polymorphic
            Srelationship.create!(
              extraction_run: @run,
              source_sobject: source_sobject,
              target_sobject: loaded_objects[targets.first],
              source_field: source_field,
              relationship_name: field["relationshipName"],
              cascade_delete: !!field["cascadeDelete"],
              restricted_delete: !!field["restrictedDelete"],
              polymorphic: true,
              reference_to_api_names: targets
            )
          else
            target_api = targets.first
            target_sobject = loaded_objects[target_api]
            Srelationship.create!(
              extraction_run: @run,
              source_sobject: source_sobject,
              target_sobject: target_sobject,
              source_field: source_field,
              relationship_name: field["relationshipName"],
              cascade_delete: !!field["cascadeDelete"],
              restricted_delete: !!field["restrictedDelete"],
              polymorphic: false,
              reference_to_api_names: targets
            )
          end
        end
      end
    end
  end
end
