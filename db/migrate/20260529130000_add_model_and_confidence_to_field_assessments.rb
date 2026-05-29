class AddModelAndConfidenceToFieldAssessments < ActiveRecord::Migration[8.1]
  def change
    add_column :field_assessments, :model, :string
    add_column :field_assessments, :confidence, :float
  end
end
