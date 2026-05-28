# One-off: re-run Ontology::SensitivityClassifier against every sfield using
# the stored `raw_describe`, update sfields.sensitivity + sensitivity_signals,
# and (when a field flips from `safe` to non-safe) scrub field_profiles.top_values
# and field_profiles.sample_values that were collected under the wrong label.
#
# Usage:
#   bin/rails runner script/reclassify_sensitivity.rb

require "set"

flipped_to_pii = Set.new
flipped_to_financial = Set.new
flipped_to_pii_and_financial = Set.new
unchanged = 0
total = 0

# Group fields by sobject so we can reuse the sobject_describe shape (fields
# array) for the person-name-sibling check. We build the describe from the
# stored sfields rows — same source of truth.
Sobject.find_each do |sobject|
  sobject_describe = {
    "name" => sobject.api_name,
    "fields" => sobject.sfields.pluck(:api_name, :raw_describe).map { |n, rd|
      { "name" => n, "nameField" => rd.is_a?(Hash) ? rd["nameField"] : false }
    }
  }

  sobject.sfields.find_each do |sf|
    total += 1
    old = sf.sensitivity
    field = sf.raw_describe.is_a?(Hash) ? sf.raw_describe : {}
    # raw_describe is the SF describe payload; "name" key matches the api_name.
    # Some old rows may lack "name"; fall back so the classifier still works.
    field = field.merge("name" => sf.api_name) unless field.key?("name")
    result = Ontology::SensitivityClassifier.classify(
      field: field,
      sobject_describe: sobject_describe,
      # Admin-declared FieldDefinition metadata persisted at load time -- pass
      # it back through so re-classification doesn't drop the authoritative
      # override and silently downgrade a flagged field to `safe`.
      compliance_group: sf.compliance_group,
      security_classification: sf.security_classification
    )
    new_sensitivity = result[:sensitivity]
    next if old == new_sensitivity && sf.sensitivity_signals == result[:signals]

    sf.update_columns(
      sensitivity: new_sensitivity,
      sensitivity_signals: result[:signals]
    )

    if old == "safe" && new_sensitivity != "safe"
      case new_sensitivity
      when "pii" then flipped_to_pii << sf.id
      when "financial" then flipped_to_financial << sf.id
      when "pii_and_financial" then flipped_to_pii_and_financial << sf.id
      end
    else
      unchanged += 1
    end
  end
end

leaked_ids = flipped_to_pii + flipped_to_pii_and_financial
puts "Re-classified #{total} sfields."
puts "  safe -> pii:                 #{flipped_to_pii.size}"
puts "  safe -> financial:           #{flipped_to_financial.size}"
puts "  safe -> pii_and_financial:   #{flipped_to_pii_and_financial.size}"
puts "  other changes:               #{unchanged}"
puts ""
puts "Scrubbing leaked top_values / sample_values on #{leaked_ids.size} sfields..."

scrubbed = FieldProfile.where(sfield_id: leaked_ids.to_a)
                       .where("jsonb_array_length(top_values) > 0 OR jsonb_array_length(sample_values) > 0")
                       .update_all(top_values: [], sample_values: [])
puts "Scrubbed #{scrubbed} field_profiles rows."

# Verification: the named-and-shamed fields from the review should now be
# classified non-safe. Bail noisily if any are still `safe`.
named_and_shamed = %w[
  ABA__c IBAN__c Bank_Account_No__c Routing_No__c
  sfsrm__EIN_or_Social_Security_Numbre_s__c
  sfsrm__Archival_Password__c
  sfsrm__AWSSecretKey__c
  FirstName LastName
]
still_safe = Sfield.where(api_name: named_and_shamed, sensitivity: "safe")
                   .joins(:sobject).distinct.pluck("sobjects.api_name", :api_name)
if still_safe.any?
  warn "WARNING: the following named-and-shamed fields are still classified safe:"
  still_safe.each { |so, sf| warn "  #{so}.#{sf}" }
  exit 1
else
  puts "All named-and-shamed fields are now classified pii / pii_and_financial. \xe2\x9c\x93"
end
