namespace :cashline do
  # FILE= rather than PATH= on purpose: PATH= would clobber the shell PATH that
  # rake's KEY=VALUE arg parsing copies into ENV.
  desc "Load a cashline-platform schema snapshot JSON (FILE=...) into cashline_snapshots, verifying its SHA-256 sidecar"
  task load_snapshot: :environment do
    path = ENV["FILE"].presence || ENV["PATH_TO_SNAPSHOT"].presence
    if path.blank? || !File.file?(path)
      abort "Usage: bin/rails cashline:load_snapshot FILE=path/to/snapshot.json"
    end

    snapshot = CashlineSnapshot.load_from_file!(path)
    puts "Loaded CashlineSnapshot ##{snapshot.id}"
    puts "  schema_version: #{snapshot.schema_version}"
    puts "  classes:        #{snapshot.classes.size}"
    puts "  sha256:         #{snapshot.sha256}"
  end
end
