require "digest"

module Ontology
  # Categorized diff between two extraction runs. Deterministic — the same pair
  # of runs always produces the same diff. Order matters: (run_a, run_b) means
  # "what changed going from run_a to run_b" — `_added` is in B not A, `_removed`
  # is in A not B.
  class DiffCalculator
    def self.compute(run_a, run_b)
      new(run_a, run_b).compute
    end

    def initialize(run_a, run_b)
      @a = run_a
      @b = run_b
    end

    def compute
      a_objects = load_objects(@a)
      b_objects = load_objects(@b)

      a_keys = a_objects.keys.to_set
      b_keys = b_objects.keys.to_set

      object_added = (b_keys - a_keys).sort
      object_removed = (a_keys - b_keys).sort
      shared = (a_keys & b_keys).sort

      field_added = []
      field_removed = []
      field_type_changed = []
      field_length_changed = []
      picklist_added = []
      picklist_removed = []
      formula_changed = []

      shared.each do |obj_key|
        af = a_objects[obj_key][:fields]
        bf = b_objects[obj_key][:fields]

        a_fkeys = af.keys.to_set
        b_fkeys = bf.keys.to_set

        (b_fkeys - a_fkeys).sort.each do |fkey|
          field_added << { "object" => obj_key, "field" => fkey, "data_type" => bf[fkey][:data_type] }
        end
        (a_fkeys - b_fkeys).sort.each do |fkey|
          field_removed << { "object" => obj_key, "field" => fkey, "data_type" => af[fkey][:data_type] }
        end

        (a_fkeys & b_fkeys).sort.each do |fkey|
          a_field = af[fkey]
          b_field = bf[fkey]

          if a_field[:data_type] != b_field[:data_type]
            field_type_changed << { "object" => obj_key, "field" => fkey, "from" => a_field[:data_type], "to" => b_field[:data_type] }
          end

          if length_changed?(a_field[:length], b_field[:length])
            field_length_changed << { "object" => obj_key, "field" => fkey, "from" => a_field[:length], "to" => b_field[:length] }
          end

          if normalize_formula(a_field[:formula]) != normalize_formula(b_field[:formula])
            formula_changed << { "object" => obj_key, "field" => fkey }
          end

          if a_field[:picklist_hash] != b_field[:picklist_hash]
            added_vals = b_field[:picklist_values] - a_field[:picklist_values]
            removed_vals = a_field[:picklist_values] - b_field[:picklist_values]
            picklist_added << { "object" => obj_key, "field" => fkey, "values" => added_vals } if added_vals.any?
            picklist_removed << { "object" => obj_key, "field" => fkey, "values" => removed_vals } if removed_vals.any?
          end
        end
      end

      a_rels = load_relationships(@a)
      b_rels = load_relationships(@b)
      a_rel_set = a_rels.to_set
      b_rel_set = b_rels.to_set

      # Sort by stringified element so polymorphic relationships (target_sobject
      # nil) don't break Array#<=>. Without this, any org with Task.WhatId /
      # Event.WhoId that changed between runs crashes the diff with ArgumentError.
      relationship_added = (b_rel_set - a_rel_set).to_a.sort_by { |arr| arr.map(&:to_s) }
      relationship_removed = (a_rel_set - b_rel_set).to_a.sort_by { |arr| arr.map(&:to_s) }

      {
        "run_a_id" => @a.id,
        "run_b_id" => @b.id,
        "api_version_a" => @a.api_version,
        "api_version_b" => @b.api_version,
        "object_added" => object_added,
        "object_removed" => object_removed,
        "field_added" => field_added,
        "field_removed" => field_removed,
        "field_type_changed" => field_type_changed,
        "field_length_changed" => field_length_changed,
        "picklist_values_added" => picklist_added,
        "picklist_values_removed" => picklist_removed,
        "relationship_added" => relationship_added.map { |r| relationship_record(r) },
        "relationship_removed" => relationship_removed.map { |r| relationship_record(r) },
        "formula_logic_changed" => formula_changed,
        "validation_rule_changed" => [],
        "installed_package_changes" => installed_package_changes(@a, @b)
      }
    end

    private

    # Salesforce already encodes managed-package namespace into api_name
    # (e.g., `MyNs__Foo__c`), so the api_name is itself the qualified key.
    def load_objects(run)
      sobjects = run.sobjects.includes(sfields: :spicklist_values)
      sobjects.each_with_object({}) do |sobj, hash|
        fields = sobj.sfields.each_with_object({}) do |sf, fh|
          values = sf.spicklist_values.select(&:active).map(&:value).sort.uniq
          fh[sf.api_name] = {
            data_type: sf.data_type,
            length: sf.length,
            formula: sf.calculated_formula,
            picklist_values: values,
            picklist_hash: values.any? ? Digest::SHA256.hexdigest(values.join("|")) : nil
          }
        end
        hash[sobj.api_name] = { fields: fields, namespace_prefix: sobj.namespace_prefix }
      end
    end

    def load_relationships(run)
      run.srelationships
         .includes(:source_sobject, :target_sobject)
         .map { |r| [ r.source_sobject.api_name, r.target_sobject&.api_name, r.relationship_name, r.polymorphic ] }
    end

    def relationship_record(arr)
      {
        "source" => arr[0],
        "target" => arr[1],
        "relationship_name" => arr[2],
        "polymorphic" => arr[3]
      }
    end

    def normalize_formula(formula)
      return nil if formula.blank?
      formula.gsub(/\s+/, " ").strip
    end

    def length_changed?(a, b)
      return false if a.to_i.zero? && b.to_i.zero?
      a.to_i != b.to_i
    end

    def installed_package_changes(a, b)
      a_packages = packages_by_namespace(a.installed_packages)
      b_packages = packages_by_namespace(b.installed_packages)
      keys_a = a_packages.keys
      keys_b = b_packages.keys

      version_changed = (keys_a & keys_b).sort.filter_map do |ns|
        va = a_packages[ns]["version"]
        vb = b_packages[ns]["version"]
        next nil if va == vb
        { "namespace" => ns, "from" => va, "to" => vb }
      end

      {
        "added" => (keys_b - keys_a).sort,
        "removed" => (keys_a - keys_b).sort,
        "version_changed" => version_changed
      }
    end

    def packages_by_namespace(packages)
      return {} if packages.blank?
      Array(packages).each_with_object({}) do |entry, h|
        if entry.is_a?(Hash)
          ns = entry["namespace"] || entry["Namespace"] || entry["namespacePrefix"] || entry["NamespacePrefix"]
          version = entry["version"] || entry["Version"] || entry["VersionNumber"]
          h[ns] = { "version" => version } if ns
        else
          h[entry.to_s] = { "version" => nil }
        end
      end
    end
  end
end
