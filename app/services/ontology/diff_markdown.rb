module Ontology
  # Markdown rendering of a RunDiff for R8a (Markdown export of a diff).
  class DiffMarkdown
    def self.render(run_diff)
      new(run_diff).render
    end

    def initialize(run_diff)
      @run_diff = run_diff
      @diff = run_diff.diff || {}
      @lines = []
    end

    def render
      header
      object_section
      field_section
      relationship_section
      formula_section
      package_section
      @lines.join("\n")
    end

    private

    def header
      @lines << "# Schema diff: run #{@run_diff.run_a_id} → run #{@run_diff.run_b_id}"
      @lines << ""
      @lines << "_Computed at #{@run_diff.computed_at&.iso8601}_"
      @lines << ""
      @lines << "**Total changes:** #{@run_diff.total_changes}"
      if @diff["api_version_a"] && @diff["api_version_a"] != @diff["api_version_b"]
        @lines << ""
        @lines << "> Cross-API-version diff: `#{@diff["api_version_a"]}` → `#{@diff["api_version_b"]}`"
      end
      @lines << ""
    end

    def object_section
      list("Objects added", @diff["object_added"]) { |o| "- `#{o}`" }
      list("Objects removed", @diff["object_removed"]) { |o| "- `#{o}`" }
    end

    def field_section
      list("Fields added", @diff["field_added"]) { |f| "- `#{f["object"]}.#{f["field"]}` _(#{f["data_type"]})_" }
      list("Fields removed", @diff["field_removed"]) { |f| "- `#{f["object"]}.#{f["field"]}` _(#{f["data_type"]})_" }
      list("Field type changed", @diff["field_type_changed"]) { |f| "- `#{f["object"]}.#{f["field"]}`: `#{f["from"]}` → `#{f["to"]}`" }
      list("Field length changed", @diff["field_length_changed"]) { |f| "- `#{f["object"]}.#{f["field"]}`: #{f["from"]} → #{f["to"]}" }
      list("Picklist values added", @diff["picklist_values_added"]) { |p| "- `#{p["object"]}.#{p["field"]}`: #{Array(p["values"]).join(", ")}" }
      list("Picklist values removed", @diff["picklist_values_removed"]) { |p| "- `#{p["object"]}.#{p["field"]}`: #{Array(p["values"]).join(", ")}" }
    end

    def relationship_section
      list("Relationships added", @diff["relationship_added"]) do |r|
        "- `#{r["source"]} → #{r["target"] || "(polymorphic)"}`#{r["polymorphic"] ? " _(polymorphic)_" : ""}"
      end
      list("Relationships removed", @diff["relationship_removed"]) do |r|
        "- `#{r["source"]} → #{r["target"] || "(polymorphic)"}`#{r["polymorphic"] ? " _(polymorphic)_" : ""}"
      end
    end

    def formula_section
      list("Formula logic changed", @diff["formula_logic_changed"]) { |f| "- `#{f["object"]}.#{f["field"]}`" }
    end

    def package_section
      pkgs = @diff["installed_package_changes"] || {}
      return if Array(pkgs["added"]).empty? && Array(pkgs["removed"]).empty? && Array(pkgs["version_changed"]).empty?
      @lines << "## Installed packages"
      @lines << ""
      Array(pkgs["added"]).each { |p| @lines << "- Added: `#{p}`" }
      Array(pkgs["removed"]).each { |p| @lines << "- Removed: `#{p}`" }
      Array(pkgs["version_changed"]).each { |p| @lines << "- `#{p["namespace"]}`: `#{p["from"]}` → `#{p["to"]}`" }
      @lines << ""
    end

    def list(title, items)
      return if items.blank?
      @lines << "## #{title}"
      @lines << ""
      Array(items).each { |item| @lines << yield(item) }
      @lines << ""
    end
  end
end
