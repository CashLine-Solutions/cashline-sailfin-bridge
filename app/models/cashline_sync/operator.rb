module CashlineSync
  # Thin write-only target on the cashline sync DB (table: operators). No
  # validations/callbacks/audits — exists to drive schema-aware writes/upserts.
  class Operator < CashlineSyncRecord
    self.table_name = "operators"
  end
end
