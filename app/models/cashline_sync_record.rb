# Abstract base for write-only models that target the external cashline-platform
# sync database (`cashline-sailfin-sync-db`). The Sailfin -> cashline importer
# writes rows here over a dedicated connection, separate from the bridge's own
# primary/cache/audit databases.
#
# The sync DB carries the *cashline-platform* schema (provisioned there via
# db:schema:load), not the bridge schema — so subclasses set their own
# `table_name` and stay intentionally bare (no validations/callbacks/audits);
# they exist only to drive schema-aware bulk `upsert_all`.
class CashlineSyncRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :cashline_sync, reading: :cashline_sync }
end
