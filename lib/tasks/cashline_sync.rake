# Shared helpers for the cashline_sync import tasks.
module CashlineSyncImport
  module_function

  # The run to import: explicit RUN=, else the latest run holding +object+ rows.
  def resolve_run_id(object_api_name)
    (ENV["RUN"].presence || SfRecord.where(object_api_name: object_api_name).pick(:extraction_run_id))&.to_i
  end

  def sample_limit
    ENV["SAMPLE"].presence&.to_i
  end

  # Run one importer and print its stats. Returns the stats hash.
  def run!(klass, label:, run_id:, limit:)
    puts "Importing #{label} (run=#{run_id}, sample=#{limit || 'ALL'}) into the sync DB..."
    stats = klass.new(extraction_run_id: run_id, limit: limit).call
    puts "Done:"
    stats.each { |k, v| puts "  #{k}: #{v}" }
    stats
  end
end

namespace :cashline_sync do
  desc "Full sync for a run, in dependency order: users (history + assignees), " \
       "accounts (emits the crosswalk), then contacts, invoices and tasks (route " \
       "through it). The safe one-shot. RUN=<id> SAMPLE=<limit>"
  task import_all: :environment do
    run_id = CashlineSyncImport.resolve_run_id("Account")
    abort "No extraction run with Account records found." unless run_id
    limit = CashlineSyncImport.sample_limit

    CashlineSyncImport.run!(Sync::UserImporter, label: "Users", run_id: run_id, limit: limit)
    puts
    CashlineSyncImport.run!(Sync::AccountImporter, label: "Accounts", run_id: run_id, limit: limit)
    puts
    CashlineSyncImport.run!(Sync::ContactImporter, label: "Contacts", run_id: run_id, limit: limit)
    puts
    CashlineSyncImport.run!(Sync::InvoiceImporter, label: "Invoices", run_id: run_id, limit: limit)
    puts
    CashlineSyncImport.run!(Sync::TaskImporter, label: "Tasks", run_id: run_id, limit: limit)
  end

  desc "Import Sailfin Users into the platform users table for historical " \
       "reference and task attribution. All imported blocked (no login); " \
       "non-destructive on re-sync (never re-blocks/re-passwords an invited " \
       "user). Keyed on sailfin_user_id. RUN=<extraction_run_id> SAMPLE=<limit>"
  task import_users: :environment do
    run_id = CashlineSyncImport.resolve_run_id("User")
    abort "No extraction run with User records found." unless run_id
    CashlineSyncImport.run!(Sync::UserImporter, label: "Users", run_id: run_id, limit: CashlineSyncImport.sample_limit)
  end

  desc "Full-refresh import of Sailfin Accounts into the cashline sync DB: " \
       "purges this operator's customer orgs/groups/accounts, then rebuilds from " \
       "source + confirmed groupings, and emits the account crosswalk. " \
       "RUN=<extraction_run_id> SAMPLE=<limit> (omit SAMPLE for full)"
  task import_accounts: :environment do
    run_id = CashlineSyncImport.resolve_run_id("Account")
    abort "No extraction run with Account records found." unless run_id
    CashlineSyncImport.run!(Sync::AccountImporter, label: "Accounts", run_id: run_id, limit: CashlineSyncImport.sample_limit)
  end

  desc "Import Sailfin Contacts into the cashline sync DB's customer_contacts, " \
       "routed to the rolled-up/merged customer via the account crosswalk. Run " \
       "import_accounts FIRST (or use import_all). RUN=<extraction_run_id> SAMPLE=<limit>"
  task import_contacts: :environment do
    run_id = CashlineSyncImport.resolve_run_id("Contact")
    abort "No extraction run with Contact records found." unless run_id
    CashlineSyncImport.run!(Sync::ContactImporter, label: "Contacts", run_id: run_id, limit: CashlineSyncImport.sample_limit)
  end

  desc "Import Sailfin transactions (invoices) into the cashline sync DB, routed " \
       "to the rolled-up/merged customer via the account crosswalk. One invoice " \
       "per (client_group, invoice_number). Run import_accounts FIRST (or use " \
       "import_all). RUN=<extraction_run_id> SAMPLE=<limit>"
  task import_invoices: :environment do
    run_id = CashlineSyncImport.resolve_run_id("Account")
    abort "No extraction run found." unless run_id
    CashlineSyncImport.run!(Sync::InvoiceImporter, label: "Invoices", run_id: run_id, limit: CashlineSyncImport.sample_limit)
  end

  desc "Import Sailfin Tasks into the cashline sync DB, forking each to " \
       "communication_events (logged email/call) or operational_tasks (work " \
       "items), routed via the account crosswalk. Run import_accounts + " \
       "import_users FIRST (or use import_all). RUN=<extraction_run_id> SAMPLE=<limit>"
  task import_tasks: :environment do
    run_id = CashlineSyncImport.resolve_run_id("Task")
    abort "No extraction run with Task records found." unless run_id
    CashlineSyncImport.run!(Sync::TaskImporter, label: "Tasks", run_id: run_id, limit: CashlineSyncImport.sample_limit)
  end

  desc "Detect candidate customer groupings (parent roll-ups) from Sailfin " \
       "Account names/structure for operator review. RUN=<extraction_run_id>"
  task detect_groupings: :environment do
    run_id = CashlineSyncImport.resolve_run_id("Account")
    abort "No extraction run with Account records found." unless run_id
    run = ExtractionRun.find(run_id)

    puts "Detecting customer groupings (run=#{run_id})..."
    stats = Sync::CustomerGroupingDetector.call(run)
    puts "Done:"
    stats.each { |k, v| puts "  #{k}: #{v}" }
  end
end
