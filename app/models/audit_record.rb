class AuditRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :audit, reading: :audit }
end
