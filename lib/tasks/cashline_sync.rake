namespace :cashline_sync do
  desc "Import a sample of Sailfin Accounts into the cashline sync DB. " \
       "RUN=<extraction_run_id> SAMPLE=<limit> (omit SAMPLE for full)"
  task import_accounts: :environment do
    run_id = (ENV["RUN"].presence || SfRecord.where(object_api_name: "Account").pick(:extraction_run_id))&.to_i
    abort "No extraction run with Account records found." unless run_id
    limit = ENV["SAMPLE"].presence&.to_i

    puts "Importing Accounts (run=#{run_id}, sample=#{limit || 'ALL'}) into the sync DB..."
    stats = Sync::AccountImporter.new(extraction_run_id: run_id, limit: limit).call
    puts "Done:"
    stats.each { |k, v| puts "  #{k}: #{v}" }
  end

  desc "Detect candidate customer groupings (parent roll-ups) from Sailfin " \
       "Account names/structure for operator review. RUN=<extraction_run_id>"
  task detect_groupings: :environment do
    run_id = (ENV["RUN"].presence || SfRecord.where(object_api_name: "Account").pick(:extraction_run_id))&.to_i
    abort "No extraction run with Account records found." unless run_id
    run = ExtractionRun.find(run_id)

    puts "Detecting customer groupings (run=#{run_id})..."
    stats = Sync::CustomerGroupingDetector.call(run)
    puts "Done:"
    stats.each { |k, v| puts "  #{k}: #{v}" }
  end
end
