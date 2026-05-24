class CreateFieldProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :field_profiles do |t|
      t.references :object_profile, null: false, foreign_key: true
      t.references :sfield, null: false, foreign_key: true
      t.float :null_rate
      t.integer :distinct_count
      t.boolean :distinct_count_suppressed, null: false, default: false
      t.integer :min_length
      t.integer :max_length
      t.float :avg_length
      t.decimal :min_value, precision: 30, scale: 6
      t.decimal :max_value, precision: 30, scale: 6
      t.decimal :mean_value, precision: 30, scale: 6
      t.decimal :p50_value, precision: 30, scale: 6
      t.decimal :p95_value, precision: 30, scale: 6
      t.datetime :min_date
      t.datetime :max_date
      t.jsonb :top_values, null: false, default: []
      t.jsonb :sample_values, null: false, default: []
      t.boolean :sensitive_override_used, null: false, default: false
      t.timestamps
    end

    add_index :field_profiles, %i[object_profile_id sfield_id], unique: true
  end
end
