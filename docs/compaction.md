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

Run the compactor against the database server, naming the table to maintain:

```text
compactor --table <[schema.]name> [--dsn <dsn>] [flags]
```

A bare table name means the `public` schema; the schema is also the table's
Iceberg namespace.

The following table describes the flags that control which maintenance steps
run and how aggressively each reclaims:

| Flag | Default | Effect |
|---|---|---|
| `--target-size-mb N` | 128 | Sets the compaction target file size; files below 75% of it are rewritten. |
| `--expire-snapshots` | off | Expires old snapshots and, by default, deletes the files they alone pinned. |
| `--expire-older-than D` | 168h | With `--expire-snapshots`, expires snapshots older than D; lower the value to reclaim sooner, but keep it longer than any transaction that reads the table (see below). |
| `--expire-retain-last N` | 1 | With `--expire-snapshots`, always keeps at least the N most recent snapshots. |
| `--expire-keep-files` | off | With `--expire-snapshots`, expires metadata only and leaves the freed files for an `--orphans` pass. |
| `--orphans` | off | Deletes files under the table location that no retained snapshot references. |
| `--orphan-age D` | 72h | With `--orphans`, deletes only files older than D, which protects in-flight writes; never set the value to 0 in production. |
| `--version` |  | Prints the version and exits. |
| `--dry-run` | off | Reports what each step would do and changes nothing; for snapshot expiry it stages the same expiry the real run commits and reports how many snapshots it would expire and keep. |

Compaction always runs (a no-op when no partition has enough small files);
`--expire-snapshots` and `--orphans` are opt-in. A typical maintenance pass
looks like this:

```text
compactor --table events --expire-snapshots --orphans
```

The compactor connects the way psql does, from the libpq environment (`PGHOST`,
`PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSERVICE`) or `--dsn`, and reads the
rest from that server: the catalog from the `coldfront.warehouse` and
`coldfront.lakekeeper_endpoint` settings and the cold-store credential from the
`coldfront.storage_secret` row, the same configuration every cold write uses.
It needs no file. A vended row gives it no credential, so Lakekeeper's vended
credentials are the only ones it sees. It runs where those addresses resolve,
which is wherever the database server itself reaches Lakekeeper and the store.

## Backends

The following table lists the backends a single binary serves, by the storage
secret the server holds (written by `set_storage_secret`, or by `import` from a
YAML's `s3:` or `azure:` stanza); configure at most one, and none for vended
credentials:

| Backend | Storage secret |
|---|---|
| S3-compatible (SeaweedFS, MinIO) | An `s3` secret with `endpoint`, `region`, the keys, `use_ssl` and `url_style`. |
| AWS S3 | An `s3` secret with `region` and the keys and no `endpoint`. |
| Google Cloud Storage | An `s3` secret with `endpoint` `storage.googleapis.com`, `use_ssl` on and HMAC keys (S3 interoperability). |
| Azure ADLS Gen2 | An `azure` secret whose connection string contains `AccountName` and `AccountKey` (shared key). |

## How It Works

The compactor loads the table from the Lakekeeper catalog and runs the
requested steps, each under a bakery claim on that table:

- Compaction rewrites data files below 75% of the target size, plus any file
  with five or more delete files, bin-packing them partition by partition into
  larger files under their partition and preserving every row (existing deletes
  are applied). A partition, and each bin within it, needs at least five such
  files, so a partition with fewer is left alone. When the table property
  `coldfront.sort-key` names a column, the compactor sorts each group on that
  column as it rewrites the group. If the column does not exist, the compactor
  skips with a `NOT compacted` warning and the other steps still run.
  iceberg-go scopes each position-delete file to its own partition, so a
  rewrite leaves a skipped partition's delete files in place. A delete file
  also stays while any data file it can apply to is left out of the rewrite.
  duckdb-iceberg on DuckDB 1.5 writes no `referenced_data_file` for a delete
  file, so iceberg-go attaches it to every data file of its partition, and a
  partition rewritten only in part keeps all of its delete files.
  duckdb-iceberg's DuckDB 2.0 line writes `referenced_data_file`, which ties
  each delete file to the one data file it names.
- Snapshot expiry is age-driven: it drops snapshots older than
  `--expire-older-than` (always keeping the current snapshot and at least
  `--expire-retain-last`) and, by default, deletes the data and manifest files
  only those snapshots referenced. This is what reclaims the small files a
  compaction supersedes - they stay pinned by the pre-compaction snapshot until
  it is expired.
  A transaction that has read the table keeps the snapshot of its first cold
  read until it ends, and expiry does not know about that transaction: if
  expiry removes the snapshot and deletes its files meanwhile, the
  transaction's next scan fails with the object store's HTTP 404 (a scan that
  already fetched the files answers from DuckDB's file cache instead). Keep
  `--expire-older-than` longer than the longest transaction that reads the
  table; the 168 h default does, and `0s` is for a table nothing is reading.
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

- The [Using ColdFront](usage.md) guide covers the server configuration the
  compactor shares with the archiver, and the deployment YAML `import` writes
  into it.
- The [Vector Storage](architecture_vectors.md) deep dive describes the sort
  key the compactor applies to clustered tables.
- The [Architecture](architecture.md) overview describes the bakery claim each
  compaction step takes.
