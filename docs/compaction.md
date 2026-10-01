# COMPACTOR - Cold-Tier Table Maintenance

`cmd/compactor` keeps a cold-tier Iceberg table healthy: it compacts each
partition's small Parquet files into fewer large ones, expires old snapshots,
and removes orphan files. ColdFront's cold tier writes one Parquet file per
append and nothing else reclaims the resulting bloat, so without maintenance a
busy table accumulates tens of thousands of tiny files and an unbounded
snapshot history. The compactor is a standalone static binary built on
[apache/iceberg-go], separate from the archiver. Every operation that mutates a
table is serialized through the ColdFront bakery - the same claim cold writes
take - so it never conflicts (HTTP 409) with concurrent writers, on a single
node or across a Spock mesh. The compactor runs against a primary; against a
read-only standby, any run other than `--dry-run` fails at its first bakery
claim.

[apache/iceberg-go]: https://github.com/apache/iceberg-go

## Usage

Run the compactor against a deployment config, naming the table to maintain:

```text
compactor --config <yaml> --table <[schema.]name> [flags]
```

A bare table name means the `public` schema; the schema is also the table's
Iceberg namespace.

The following table describes the flags that control which maintenance steps
run and how aggressively each reclaims:

| Flag | Default | Effect |
|---|---|---|
| `--target-size-mb N` | 128 | Sets the compaction target file size; files below 75% of it are rewritten. |
| `--expire-snapshots` | off | Expires old snapshots and, by default, deletes the files they alone pinned. |
| `--expire-older-than D` | 168h | With `--expire-snapshots`, expires snapshots older than D; lower the value to reclaim sooner. |
| `--expire-retain-last N` | 1 | With `--expire-snapshots`, always keeps at least the N most recent snapshots. |
| `--expire-keep-files` | off | With `--expire-snapshots`, expires metadata only and leaves the freed files for an `--orphans` pass. |
| `--orphans` | off | Deletes files under the table location that no retained snapshot references. |
| `--orphan-age D` | 72h | With `--orphans`, deletes only files older than D, which protects in-flight writes; never set the value to 0 in production. |
| `--version` |  | Prints the version and exits. |
| `--dry-run` | off | Reports what each step would do and changes nothing; for snapshot expiry it reports only the snapshot count and the `--expire-retain-last` floor. |

Compaction always runs (a no-op when no partition has enough small files);
`--expire-snapshots` and `--orphans` are opt-in. A typical maintenance pass
looks like this:

```text
compactor --config deploy.yaml --table events --expire-snapshots --orphans
```

The config is the same deployment YAML the archiver reads - `postgres.dsn` (for
the bakery claim), `iceberg.{warehouse, lakekeeper_endpoint}`, and at most one
cold-store stanza: `s3:` or `azure:` for static credentials, or none when the
deployment uses vended credentials (`set_storage_secret_vended`).

## Backends

The following table lists the backends a single binary serves; configure at
most one, and none for vended credentials:

| Backend | Config |
|---|---|
| S3-compatible (SeaweedFS, MinIO) | `s3: {endpoint, region, access_key, secret_key, use_ssl, url_style}` |
| AWS S3 | `s3: {region, access_key, secret_key}` with no `endpoint`; without keys, the AWS SDK default credential chain applies |
| Google Cloud Storage | `s3: {endpoint: storage.googleapis.com, use_ssl: true, access_key, secret_key}` with HMAC keys (S3 interoperability) |
| Azure ADLS Gen2 | `azure: {connection_string}`, which must contain `AccountName` and `AccountKey` (shared key) |

## How It Works

The compactor loads the table from the Lakekeeper catalog and runs the
requested steps, each under a bakery claim on that table:

- Compaction rewrites data files below 75% of the target size, plus any file
  with five or more delete files, bin-packing them partition by partition into
  larger files under their partition and preserving every row (existing deletes
  are applied). A partition, and each bin within it, needs at least five such
  files, so a partition with fewer is left alone. When the table property
  `coldfront.sort-key` names a column, each group is sorted on that column as
  it is rewritten; if the column does not exist, compaction is skipped with a
  `NOT compacted` warning and the other steps still run. Before planning, each
  data file's position-delete files are scoped to its own partition, the only
  ones that can reference its rows: iceberg-go attaches them by the delete
  file's `file_path` bounds, which duckdb-iceberg writes under DuckDB's own
  field id, so it would otherwise attach every delete file to every data file
  and remove a skipped partition's delete files along with a rewritten one.
- Snapshot expiry is age-driven: it drops snapshots older than
  `--expire-older-than` (always keeping the current snapshot and at least
  `--expire-retain-last`) and, by default, deletes the data and manifest files
  only those snapshots referenced. This is what reclaims the small files a
  compaction supersedes - they stay pinned by the pre-compaction snapshot until
  it is expired.
- Orphan removal deletes files under the table location that no retained
  snapshot references, which covers files left by an interrupted write or by
  `--expire-keep-files`. The `--orphan-age` window keeps a concurrent writer's
  freshly-staged files from being removed.

Each mutating step holds the bakery claim across its catalog commit and
releases it when its PostgreSQL transaction commits, so it cannot interleave
with a cold write to the same table. Snapshot maintenance is the engine's job,
not the catalog's: Lakekeeper does no Iceberg snapshot or orphan maintenance.

## Requirements

The compactor (`cmd/compactor`, apache/iceberg-go) reads the cold-tier Iceberg
tables directly. Build the binary with `make compactor`, which vets, lints
(golangci-lint required), tests, and builds `./bin/compactor`.

## Next Steps

To go further with ColdFront, consult the following documents:

- The [Using ColdFront](usage.md) guide covers the deployment YAML the
  compactor shares with the archiver.
- The [Vector Storage](architecture_vectors.md) deep dive describes the sort
  key the compactor applies to clustered tables.
- The [Architecture](architecture.md) overview describes the bakery claim each
  compaction step takes.
