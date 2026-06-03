require "digest"
require "fileutils"
require "json"

module Runs
  # Owns the on-disk layout of a single extraction run.
  #
  #   storage/runs/<timestamp>/                  # non-sensitive
  #   storage/runs/sensitive/<timestamp>/        # include_sensitive=true; mode 0700
  #
  # One JSONL file per object, one manifest, no symlinks. The sensitive root
  # is enforced at 0700 — a boot check (see `RunDirectory.boot_check!`) refuses
  # to start if the directory is group- or world-readable.
  class RunDirectory
    SENSITIVE_SUBDIR = "sensitive".freeze
    PERMS_SENSITIVE_DIR = 0o700

    class InsecureSensitiveDirectory < StandardError; end

    attr_reader :run

    def self.for(run)
      new(run)
    end

    # Called from `bin/setup` and from an initializer. Refuses to boot when
    # the sensitive root exists with broader-than-owner permissions.
    def self.boot_check!(root: default_root)
      sensitive_root = root.join(SENSITIVE_SUBDIR)
      return unless File.exist?(sensitive_root)

      mode = File.stat(sensitive_root).mode & 0o777
      return if (mode & 0o077).zero? # no group/other bits set

      raise InsecureSensitiveDirectory,
            "#{sensitive_root} has mode #{mode.to_s(8)}; expected 700. " \
            "Backups and aggregation tools must respect this. Fix with `chmod 700 #{sensitive_root}`."
    end

    def self.default_root
      Rails.root.join("storage", "runs")
    end

    def initialize(run)
      @run = run
    end

    def sensitive?
      run.include_sensitive
    end

    def root
      base = self.class.default_root
      base = base.join(SENSITIVE_SUBDIR) if sensitive?
      base.join(run.directory_token)
    end

    def ensure!
      FileUtils.mkdir_p(root)
      File.chmod(PERMS_SENSITIVE_DIR, root) if sensitive?
      root
    end

    def manifest_path
      root.join("_manifest.json")
    end

    def object_jsonl_path(object_api_name)
      root.join("#{sanitize(object_api_name)}.jsonl")
    end

    # Raw record-data backup lives under records/ so it does not collide with
    # the per-object describe JSONL (and so content_digest, which globs *.jsonl
    # at the run root, ignores it). One JSONL file per object: one line per row.
    def records_dir
      root.join("records")
    end

    def record_backup_path(object_api_name)
      records_dir.join("#{sanitize(object_api_name)}.jsonl")
    end

    def ensure_records_dir!
      FileUtils.mkdir_p(records_dir)
      File.chmod(PERMS_SENSITIVE_DIR, records_dir) if sensitive?
      records_dir
    end

    def write_manifest!(payload)
      ensure!
      File.write(manifest_path, JSON.pretty_generate(payload))
    end

    def append_jsonl!(path, record)
      ensure!
      File.open(path, "a") { |f| f.puts(JSON.generate(record)) }
    end

    def purge!
      return unless root.exist?
      FileUtils.rm_rf(root)
    end

    # Deterministic digest of the run directory contents. Used by
    # ExtractToolingJob to stamp the run with a content_hash at completion,
    # and by ComputeDiffJob to detect on-disk/DB skew before diffing.
    def content_digest
      return nil unless root.exist?

      entries = Dir.glob(root.join("*.jsonl")).sort.map do |path|
        sha = Digest::SHA256.file(path).hexdigest
        "#{File.basename(path)}:#{File.size(path)}:#{sha}"
      end
      manifest = manifest_path
      if File.exist?(manifest)
        sha = Digest::SHA256.file(manifest).hexdigest
        entries << "_manifest.json:#{File.size(manifest)}:#{sha}"
      end

      return nil if entries.empty?
      Digest::SHA256.hexdigest(entries.join("\n"))
    end

    private

    def sanitize(name)
      name.to_s.gsub(/[^A-Za-z0-9_\.\-]/, "_")
    end
  end
end
