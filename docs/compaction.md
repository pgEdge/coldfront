# COMPACTOR - cold-tier table maintenance

`cmd/compactor` keeps a cold-tier Iceberg table healthy: it compacts
small Parquet files into fewer large ones, expires old snapshots, and
removes orphan files. ColdFront's cold tier writes one Parquet file per
append and nothing else reclaims the resulting bloat, so without
maintenance a busy table accumulates tens of thousands of tiny files and
an unbounded snapshot history.

It is a standalone static binary built on [apache/iceberg-go], separate
from the archiver. Every operation that mutates a table is serialized
through the ColdFront bakery - the same claim cold writes take - so it
never conflicts (409s) with concurrent writers, on a single node or
across a Spock mesh. It runs against a primary; against a read-only
standby it exits with an error.

[apache/iceberg-go]: https://github.com/apache/iceberg-go

## Usage

Run the compactor against a deployment config, naming the table to
maintain:

```text
compactor --config <yaml> --table <name> [flags]
```

The flags below control which maintenance steps run and how aggressively
each reclaims:

| Flag | Default | Effect |
|---|---|---|
| `--target-size-mb N` | 128 | compaction target file size; only files well below it are rewritten |
| `--expire-snapshots` | off | expire old snapshots and (by default) delete the files they alone pinned |
| `--expire-older-than D` | 168h | with `--expire-snapshots`: expire snapshots older than D - lower it to reclaim sooner |
| `--expire-retain-last N` | 1 | with `--expire-snapshots`: always keep at least the N most-recent snapshots |
| `--expire-keep-files` | off | expire metadata only; leave the freed files for an `--orphans` pass |
| `--orphans` | off | delete files under the table location that no retained snapshot references |
| `--orphan-age D` | 72h | with `--orphans`: only delete files older than D - protects in-flight writes; never set 0 in production |
| `--dry-run` | off | report what each step would do; change nothing |

Compaction always runs (a no-op when nothing is below target);
`--expire-snapshots` and `--orphans` are opt-in. A typical maintenance
pass looks like this:

```text
compactor --config deploy.yaml --table events --expire-snapshots --orphans
```

The config is the same deployment YAML the archiver reads - `postgres.dsn`
(used to take the bakery claim),
`iceberg.{warehouse, lakekeeper_endpoint, namespace}`, and exactly one
cold-store stanza.

## Backends

One binary serves every ColdFront cold store; configure exactly one:

| Backend | Config |
|---|---|
| S3-compatible (SeaweedFS, MinIO) | `s3: {endpoint, region, access_key, secret_key, use_ssl, url_style}` |
| AWS S3 | `s3:` with no `endpoint` (uses the AWS SDK credential chain) |
| Google Cloud Storage | `s3:` pointed at `storage.googleapis.com` with HMAC keys (S3-interop) |
| Azure ADLS Gen2 | `azure: {connection_string}` |

## How it works

The compactor loads the table from the Lakekeeper catalog and runs the
requested steps, each under a bakery claim on that table:

- **Compaction** bin-packs below-target data files and rewrites each
  group into one larger file, preserving every row (existing deletes are
  applied). If nothing is below target it does nothing.
- **Snapshot expiry** is age-driven: it drops snapshots older than
  `--expire-older-than` (always keeping the current snapshot and at least
  `--expire-retain-last`) and, by default, deletes the data and manifest
  files only those snapshots referenced. This is what reclaims the small
  files a compaction supersedes - they stay pinned by the pre-compaction
  snapshot until it is expired.
- **Orphan removal** deletes files under the table location that no
  retained snapshot references - the safety net for files left by an
  interrupted write or by `--expire-keep-files`. The `--orphan-age`
  window keeps a concurrent writer's freshly-staged files from being
  removed.

Each mutating step holds the bakery claim across its catalog commit and
releases it when its PostgreSQL transaction commits, so it cannot
interleave with a cold write to the same table. Snapshot maintenance is
the engine's job, not the catalog's: Lakekeeper does no Iceberg snapshot
or orphan maintenance.

## Requirements

The cold tier must run on ColdFront's DuckDB 1.5 base image, which
carries the patches that make duckdb-iceberg's manifests readable by
other Iceberg engines
(see [DUCKDB_1.5_PATCHED.md](https://github.com/pgEdge/ColdFront/blob/main/DUCKDB_1.5_PATCHED.md)). Build the binary with
`make compactor`.
