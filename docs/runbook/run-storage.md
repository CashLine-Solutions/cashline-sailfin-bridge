# Run Storage Operations

Each extraction writes raw Salesforce JSON payloads to a per-run directory under `storage/runs/`. This document covers layout, sensitivity handling, retention, and operations.

## Layout

```
storage/
├── runs/
│   ├── 2026-05-23T14-00-00Z-a1b2/
│   │   ├── _manifest.json
│   │   ├── Account.jsonl
│   │   ├── Contact.jsonl
│   │   ├── Opportunity.jsonl
│   │   └── ...
│   └── 2026-05-24T09-30-00Z-c3d4/
│       └── ...
└── runs/
    └── sensitive/
        └── 2026-05-23T20-15-00Z-e5f6/  (mode 0700)
            ├── _manifest.json
            └── ...
```

- **Non-sensitive runs** live under `storage/runs/` with default permissions.
- **Sensitive runs** (created with `include_sensitive: true`) live under `storage/runs/sensitive/` with **mode 0700** — only the Rails process user can read them.

## Why the file system

The on-disk JSON is the immutable input to `Runs::RelationalLoader`, which builds the normalized Postgres tables. If the DB rows are ever corrupt, you can `rake runs:rebuild_db RUN=<directory_token>` to regenerate them deterministically from the JSON. This is also the reason for run-level idempotency (requirement R20) — the directory token in `ExtractionRun#directory_token` is what ties on-disk and DB state together.

## What's in each file

| File | Contents |
|---|---|
| `_manifest.json` | Run metadata: api_version, started_at, walk_options, seed_objects, objects_visited, edges (relationships discovered during the walk) |
| `<ObjectApi>.jsonl` | One JSON line per record_type. Currently: `{"record_type": "describe", "api_name": "Account", "payload": {...}}` for the full Salesforce describe; later record_types may be added (tooling metadata, profile samples). |

Reading a run is straightforward: open `_manifest.json` to see what objects to expect, then stream each `<ObjectApi>.jsonl` line by line.

## Sensitivity enforcement

The `Runs::RunDirectory.for(run)` service picks the parent directory based on `run.include_sensitive`:

- `false` → `Rails.root.join("storage/runs/#{run.directory_token}")`
- `true`  → `Rails.root.join("storage/runs/sensitive/#{run.directory_token}")`, created with `FileUtils.mkdir_p` then `File.chmod(0o700)`.

The `0700` permission is **not** a security boundary in isolation — anyone with root or filesystem-level access to the host can still read the files. It is a defense-in-depth measure: a process running as a different user on the same host cannot accidentally read sensitive payloads.

In production, deploy the Rails app under a dedicated user (e.g. `cashline`), and ensure `storage/runs/sensitive/` is not backed up to the same retention class as non-sensitive data.

## Retention

- **Non-sensitive runs:** kept indefinitely. Operators may prune manually if disk pressure is an issue.
- **Sensitive runs:** auto-purged 30 days after `retained_until` (set on creation). The `PurgeExpiredSensitiveRunsJob` runs daily via GoodJob cron (see `config/initializers/good_job.rb`).

Purge is destructive: the on-disk directory is removed AND the `extraction_run` row is `destroy!`ed (which cascades through profiles, fields, picklist values, relationships, clusters, and any `run_diffs` involving the run as either side).

If you need to extend retention on a specific sensitive run, update the row:

```bash
bin/rails runner 'ExtractionRun.find(<id>).update!(retained_until: 90.days.from_now)'
```

Or revoke its sensitivity entirely if it turns out to be safe (with appropriate audit logging):

```bash
bin/rails runner 'ExtractionRun.find(<id>).update!(include_sensitive: false, retained_until: nil)'
```

The on-disk directory is **not** moved by either operation — only the metadata changes. If you want sensitive runs to physically migrate when reclassified, do that as a separate step.

## Disk capacity

A typical run's directory size scales with:
- Number of objects visited (linear)
- Average describe payload size (~50 KB for standard objects; can be larger for managed-package objects with many fields)
- Whether Bulk 2.0 samples are persisted (Unit 15) — these can be large

A Sailfin-shaped extraction (~200 visited objects, full describe) is roughly 10–40 MB per run. Sensitive runs with Bulk samples can grow to 100+ MB. Plan for 1 GB of `storage/` headroom per 30-day window in production.

Monitor with:

```bash
du -sh storage/runs/* | sort -h
du -sh storage/runs/sensitive/* | sort -h
```

## Rebuilding the DB from a run directory

If the relational tables for a run get corrupt or you want to apply schema changes that the loader handles:

```bash
bin/rails runs:rebuild_db RUN=<directory_token>
```

This is **destructive in the sense that the existing DB rows for that run are replaced**, but **non-destructive on disk** — the JSON files are the source of truth and stay untouched. The loader is idempotent.

## Migrating storage between hosts

`storage/runs/` is the canonical home for raw extracts; the DB can always be rebuilt from it. To migrate to a new host:

1. Stop the Rails app + GoodJob workers on the source host.
2. `rsync -a --info=progress2 storage/runs/ new-host:/path/to/storage/runs/`
3. On the new host, restore the audit + primary DBs.
4. For each run, run `rake runs:rebuild_db RUN=<directory_token>` if needed (only if the DB is empty/stale; if you migrated the DB, skip).

## What about backups?

Two recommendations:

- **Non-sensitive runs:** include `storage/runs/` (excluding `sensitive/`) in your normal backup rotation.
- **Sensitive runs:** **do not include `storage/runs/sensitive/` in long-term backups.** The 30-day retention window is a feature, not a bug — backing it up beyond 30 days defeats the purge guarantee.

If you must back up sensitive runs (e.g., regulatory requirement during an active extraction), use a separate backup target with its own retention policy, and document the deviation.

## Common operations cheat sheet

```bash
# List all runs with directory tokens and sizes
bin/rails runner 'ExtractionRun.order(:id).each { |r| puts "%-40s %s %d objects" % [r.directory_token, r.status, r.sobjects.count] }'

# Force-purge a specific sensitive run early (skips the retained_until check)
bin/rails runner 'run = ExtractionRun.find(<id>); Runs::RunDirectory.for(run).purge!; run.destroy!'

# List sensitive runs and their retention
bin/rails runner 'ExtractionRun.sensitive.find_each { |r| puts "#{r.directory_token}  retained_until=#{r.retained_until}" }'

# Manually trigger the purge job (don't wait for the daily cron)
bin/rails runner 'PurgeExpiredSensitiveRunsJob.new.perform'
```
