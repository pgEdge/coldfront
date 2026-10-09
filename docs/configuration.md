# Configuring ColdFront

After installing ColdFront packages or building from source, several
components still need configuring before the cold tier comes online:

- PostgreSQL and ColdFront's own configuration, detailed in this
  guide, regardless of which installation path you followed.
- your object store, documented in
  [Configuring your Object Store](object_store.md).
- installing, configuring, and bootstrapping Lakekeeper, and the
  one-time per-database setup that ties everything together,
  documented in the [Configuring Lakekeeper](one_time_setup.md)
  guide.

## Configuring PostgreSQL

A package installation does not configure PostgreSQL. Add the following
settings to `postgresql.conf`, then restart PostgreSQL:

```ini
shared_preload_libraries = 'pg_duckdb,coldfront'
duckdb.extension_directory = '/usr/lib/pgedge/coldfront/duckdb-extensions'
duckdb.allow_unsigned_extensions = true
duckdb.autoinstall_known_extensions = false
coldfront.iceberg_async_parquet = on
coldfront.iceberg_bakery_patch = on
coldfront.warehouse = '<warehouse-name>'
coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
coldfront.local_pg_dsn = 'host=/var/run/postgresql dbname=<db> user=<role>'
```

Together, the three `duckdb.*` settings point pg_duckdb at the directory
where `pgedge-coldfront-duckdb-extensions` installs ColdFront's patched
DuckDB extensions, rather than letting it fetch the unpatched upstream
build - the same substitution that reintroduces HTTP 409 failures under
concurrent cold writes. The patched extensions are unsigned, so
`duckdb.allow_unsigned_extensions` must stay on; and because a missing
extension file would otherwise trigger that same fallback,
`duckdb.autoinstall_known_extensions` stays off.

The two `coldfront.iceberg_*` settings take effect only on a Spock mesh, where
a node then uploads Parquet files outside the bakery claim and serializes only
the catalog commit. The packaged duckdb-iceberg includes the patch that this
ordering requires, and the [Distributed Setup](distributed_setup.md) guide
describes the mesh settings.

ColdFront also exposes the following settings, which adjust write
behavior and execution; tune them as needed:

| Setting | Description |
|---|---|
| `coldfront.allow_mixed_writes` | Controls tiered-mode `UPDATE`/`DELETE` whose WHERE cannot be proven to target one tier. `on` emits a dual-tier CTE; `off` rejects with an error and a hint. Not relevant in decoupled mode (every write is single-tier by definition). The default is `on`. |
| `coldfront.cold_write_batch_size` | Sets how many cold rows a tiered `INSERT` gathers (see [Caveats](caveats.md)) before writing them to Iceberg as one `INSERT`. A larger value writes fewer, larger Parquet files; the remainder always flushes, so a small write stays one file. The default is `10000`, with a minimum of `1`. |
| `coldfront.vector_probe` | Sets whether a recognized similarity search reads only the clusters nearest its query vector. `off` gives an exact scan of the whole corpus. Affects only a table with a trained vector column ([usage_vectors.md](usage_vectors.md)). The default is `on`. |
| `coldfront.vector_nprobe` | Sets how many clusters such a search reads, overriding the column's own `nprobe`; at or above the column's `nlist` the search is exhaustive. The default is `0`, which uses the configured value. |
| `duckdb.force_execution` | Benchmark before enabling: on a mixed workload it helps `count(distinct)` and similar but regresses index lookups, top-K with PK ordering, and JSON access. The default is `off`. |
| `duckdb.temporary_directory` | Sets where DuckDB spills. Each backend gets its own subdirectory there, named after its process id, so concurrent spills cannot collide; one left by a departed backend is reclaimed. See [architecture.md](architecture_guides/index.md#duckdb-spill-files-are-not-namespaced-per-instance). |
| `duckdb.max_temp_directory_size` | A cap per connection, not a cluster total. For a total budget, divide it by the concurrent sessions, or give the temp path its own filesystem or quota. The default is 90% of free space per session. |

## Writing ColdFront's Configuration

Server-level settings live in `postgresql.conf`, each managed table's
configuration is a row in `coldfront.partition_config`, and the
cold-store credential lives in `coldfront.storage_secret`.

Write the configuration with `coldfront.set_storage_secret()` and the
`register` command. `set_storage_secret()` writes the following to
`coldfront.storage_secret`; the
[Configuring your Object Store](object_store.md) guide shares the exact
values for each supported backend:

- `<access-key-id>` - your object store's access key.
- `<secret-key>` - the matching secret.
- `<endpoint>` - your object store's endpoint.

```sql
SELECT coldfront.set_storage_secret('<access-key-id>', '<secret-key>', '<endpoint>');
```

`register` writes the following to `coldfront.partition_config`:

- `<table>` - the table name.
- `<period>` - the partition cadence, e.g. `monthly`.
- `<hot-period>` - how long a partition stays hot before the archiver
  moves it to the cold tier.

```bash
./bin/archiver register --table <table> \
    --period <period> --hot-period "<hot-period>"
```

Or do both in one step by importing a deployment YAML:

```bash
archiver import --config deploy.yaml
```

The `pgedge-coldfront` package installs an example deployment YAML at
`/etc/pgedge/coldfront/config.yaml`. The file is only an example; edit it and pass it to `import` - no
ColdFront tool reads it unless `--config` names it.
After an import, the server holds the configuration. A later run that is given
a YAML checks the file against the server and refuses to run if any value
differs. The only value such a run takes from the file is `postgres.dsn`, which
connects when `--dsn` is unset. The
[Managing Partitioned Tables (CLI)](usage_partitioner.md#managing-partitioned-tables-cli)
section of the Using ColdFront in Standalone Partitioned Mode guide describes
`register`, `import`, and `export`.
