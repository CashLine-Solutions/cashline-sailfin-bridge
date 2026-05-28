class Sfield < ApplicationRecord
  self.table_name = "sfields"

  belongs_to :sobject
  has_many :spicklist_values, dependent: :destroy
  has_many :field_profiles, dependent: :destroy
  has_many :mapping_entries, foreign_key: :source_field_id, dependent: :destroy

  validates :api_name, presence: true

  PICKLIST_TYPES = %w[picklist multipicklist].freeze

  # On a safe -> sensitive reclassification, purge any full-content embeddings
  # cached for this field so a richer descriptor can't outlive its safe status.
  after_update :purge_embeddings_on_sensitivity_upgrade

  def picklist?
    PICKLIST_TYPES.include?(data_type) || spicklist_values.exists?
  end

  private

  def purge_embeddings_on_sensitivity_upgrade
    return unless saved_change_to_sensitivity?
    was, now = saved_change_to_sensitivity
    return unless was.to_s == "safe" && now.to_s != "safe"
    Mapping::EmbeddingMatcher.purge_field!(self)
  end
end
