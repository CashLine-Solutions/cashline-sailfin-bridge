require "digest"

# A frozen JSON snapshot of cashline-platform's current Rails schema, produced
# by `cashline:export_schema` over there and ingested by `cashline:load_snapshot`
# here. The whole descriptor lives in a single `schema_json` JSONB column — the
# mapping grid filters relational `mapping_entries`; this JSONB is read mainly to
# build the target picklist and resolve natural keys.
#
# Mappings reference targets by natural key (class_name, field_name) rather than
# a surrogate FK into snapshot rows, so re-snapshotting a moving target doesn't
# silently orphan work.
class CashlineSnapshot < ApplicationRecord
  class IntegrityError < StandardError; end

  has_many :mapping_entries, dependent: :destroy

  validates :sha256, presence: true
  validates :loaded_at, presence: true

  # The active snapshot when none is explicitly selected (Unit 3).
  def self.current
    order(loaded_at: :desc).first
  end

  # Verify the sidecar SHA-256, then persist the snapshot and audit the load.
  # The exporter writes `<path>` plus `<path>.sha256` next to it.
  def self.load_from_file!(path, request: nil)
    json_path = path.to_s
    raise ArgumentError, "snapshot file not found: #{json_path}" unless File.exist?(json_path)

    sidecar = "#{json_path}.sha256"
    raise ArgumentError, "missing sidecar (expected #{sidecar})" unless File.exist?(sidecar)

    raw = File.read(json_path)
    actual = Digest::SHA256.hexdigest(raw)
    expected = File.read(sidecar).strip
    unless ActiveSupport::SecurityUtils.secure_compare(actual, expected)
      raise IntegrityError, "SHA-256 mismatch for #{json_path}: sidecar=#{expected} actual=#{actual}"
    end

    snapshot = create!(loaded_at: Time.current, sha256: actual, schema_json: JSON.parse(raw))
    AuditEvent.record!(
      action: "cashline_snapshot.loaded",
      user: nil,
      subject: snapshot,
      params: { path: json_path, sha256: actual },
      request: request
    )
    snapshot
  end

  def schema_version
    schema_json["schema_version"]
  end

  # The raw per-class descriptor hashes (string keys, straight from JSONB).
  def class_descriptors
    @class_descriptors ||= Array(schema_json["classes"])
  end

  # Sorted class names — e.g. ["Customer::Account", "Ingestion::Connector", "Invoice"].
  def classes
    class_descriptors.map { |c| c["class_name"] }.sort
  end

  # { "Ingestion" => ["Ingestion::Connector", ...], nil => ["Invoice", ...] }
  # Powers the namespace-grouped target picklist (Unit 6).
  def classes_by_namespace
    class_descriptors
      .group_by { |c| c["namespace"] }
      .transform_values { |cs| cs.map { |c| c["class_name"] }.sort }
  end

  # Column descriptor hashes for a class: name, sql_type, type, null, default,
  # comment, and (for enum columns) enum_values.
  def fields_for(class_name)
    cd = class_index[class_name]
    cd ? Array(cd["columns"]) : []
  end

  # The seam Units 6 and 8 depend on: the column descriptor (type + enum values)
  # for one natural-key target, or nil if the snapshot no longer has it.
  def field(class_name, field_name)
    fields_for(class_name).find { |col| col["name"] == field_name }
  end

  def field?(class_name, field_name)
    field(class_name, field_name).present?
  end

  def enum_bearing?(class_name, field_name)
    field(class_name, field_name)&.dig("enum_values").present?
  end

  # The value=>integer mapping for an enum-bearing target field, else nil.
  def enum_values(class_name, field_name)
    field(class_name, field_name)&.dig("enum_values")
  end

  private

  def class_index
    @class_index ||= class_descriptors.index_by { |c| c["class_name"] }
  end
end
