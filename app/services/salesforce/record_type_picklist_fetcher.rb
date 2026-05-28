module Salesforce
  # Pulls per-record-type picklist availability from the REST describe/layouts
  # endpoint. The standard `/sobjects/{name}/describe` returns only an object's
  # *global* picklist vocabulary; which values are valid for a given record type
  # lives in `recordTypeMappings[].picklistsForRecordType[]` here.
  #
  #   GET /services/data/vXX.X/sobjects/{name}/describe/layouts/
  #
  # One call per object returns every record type's mapping, so callers should
  # only invoke this for objects that actually have non-Master record types.
  # Failures (managed package, no layout access, transient 5xx) degrade to nil --
  # the global vocabulary in spicklist_values is still complete.
  class RecordTypePicklistFetcher
    def initialize(client:, api_version: Salesforce::API_VERSION)
      @client = client
      @api_version = api_version
    end

    # Returns a single jsonl-ready record describing per-record-type picklist
    # availability, or nil when there is nothing useful to record.
    def fetch_for(api_name)
      body = layouts(api_name)
      return nil unless body.is_a?(Hash)

      mappings = Array(body["recordTypeMappings"]).filter_map do |rtm|
        picklists = picklists_for(rtm)
        next if picklists.empty?

        {
          "record_type_id" => rtm["recordTypeId"],
          "name" => rtm["name"],
          "available" => rtm.fetch("available", true),
          "picklists" => picklists
        }
      end
      return nil if mappings.empty?

      { "record_type" => "record_type_picklists", "api_name" => api_name, "mappings" => mappings }
    end

    private

    def picklists_for(rtm)
      Array(rtm["picklistsForRecordType"]).each_with_object({}) do |pl, acc|
        name = pl["picklistName"]
        next if name.blank?

        acc[name] = Array(pl["picklistValues"])
                      .select { |pv| pv.fetch("active", true) }
                      .map { |pv| pv["value"] }
      end
    end

    def layouts(api_name)
      path = "/services/data/v#{@api_version}/sobjects/#{api_name}/describe/layouts/"
      response = @client.get(path)
      response.respond_to?(:body) ? response.body : response
    rescue StandardError => e
      Rails.logger.warn "Salesforce::RecordTypePicklistFetcher failed for #{api_name}: #{e.message}"
      nil
    end
  end
end
