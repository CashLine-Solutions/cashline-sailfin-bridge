class FieldProfile < ApplicationRecord
  belongs_to :object_profile
  belongs_to :sfield
end
