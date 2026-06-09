module CashlineSync
  class Invoice < CashlineSyncRecord
    self.table_name = "invoices"
  end
end
