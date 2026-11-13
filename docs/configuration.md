# Configuring ColdFront

After installing the ColdFront packages or building ColdFront from source,
configure the following components before the cold tier comes online:

- PostgreSQL and ColdFront, described below.
- Lakekeeper, including its installation, its bootstrap, and the one-time
  setup for each database, described in the
  [Configuring Lakekeeper](configure_lakekeeper.md) guide.
- Your object store, described in the
  [Configuring your Object Store](object_store.md) guide.

## Configuring PostgreSQL

The ColdFront packages do not configure PostgreSQL. After a package
installation, add the following settings to `postgresql.conf`, then restart
PostgreSQL:

```ini
shared_preload_libraries = 'pg_duckdb,coldfront'
duckdb.extension_directory = '/usr/lib/pgedge/coldfront/duckdb-extensions'
duckdb.allow_unsigned_extensions = true
duckdb.autoinstall_known_extensions = false
duckdb.postgres_role = 'coldfront_duckdb'
coldfront.iceberg_async_parquet = on
coldfront.iceberg_bakery_patch = on
coldfront.warehouse = '<warehouse-name>'
coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
coldfront.local_pg_dsn = 'host=/var/run/postgresql dbname=<db> user=<role>'
```

Building from source on Docker configures PostgreSQL for you: the
entrypoint writes its own settings when it initializes the data directory,
taking the warehouse, the Lakekeeper endpoint, and the DuckDB role from
environment variables. When you build from source on bare metal, you set the
values manually during [installation](installation.md). The descriptions that
follow cover the package settings; the tuning settings apply to every
installation.

The `duckdb.*` extension settings make pg_duckdb load ColdFront's
patched DuckDB extensions instead of fetching the unpatched upstream build,
which fails with HTTP 409 errors under concurrent cold writes:

- `duckdb.extension_directory` points pg_duckdb at the directory where the
  `pgedge-coldfront-duckdb-extensions` package installs the patched
  extensions.
- `duckdb.allow_unsigned_extensions` must stay on, because the patched
  extensions are unsigned.
- `duckdb.autoinstall_known_extensions` must stay off, so that a missing
  extension file causes an error instead of a download of the upstream
  build.

`duckdb.postgres_role` names the role whose members may run DuckDB. Without
it, only superusers can run DuckDB, and `coldfront.grant_app_access()` fails.
Create the role before you grant access to an application role:

```sql
CREATE ROLE coldfront_duckdb NOLOGIN;
```

Keep both `coldfront.iceberg_*` settings on. Together, they let an `INSERT`
or `COPY` upload its Parquet files before taking the write lock, so
concurrent writes wait only for the short catalog commit. The packaged
duckdb-iceberg includes the patch that this ordering requires. The
[Configuring a Distributed Deployment](distributed_setup.md) guide describes
the additional settings for a Spock mesh.

ColdFront also exposes the following settings, which adjust write behavior
and execution; tune them as needed:

| Setting | Description |
|---|---|
| `coldfront.allow_mixed_writes` | Controls a tiered-mode `UPDATE` or `DELETE` whose `WHERE` clause cannot be proven to target one tier. `on` runs the statement against both tiers; `off` rejects it with an error and a hint. Decoupled mode ignores this setting, because every write there targets one tier. The default is `on`. |
| `coldfront.cold_write_batch_size` | Sets how many cold rows a tiered `INSERT` gathers before writing them to Iceberg as one `INSERT` (see [Caveats](caveats.md)). A larger value writes fewer, larger Parquet files; the remaining rows are always written, so a small write produces one file. The default is `10000`, and the minimum is `1`. |
| `coldfront.vector_probe` | Sets whether a similarity search reads only the clusters nearest its query vector; `off` scans the whole corpus for an exact result. Applies only to a table with a trained vector column (see [Working with Embeddings](usage_vectors.md)). The default is `on`. |
| `coldfront.vector_nprobe` | Sets how many clusters a similarity search reads, overriding the column's own `nprobe`; a value at or above the column's `nlist` searches every cluster. The default is `0`, which uses the column's value. |
| `duckdb.force_execution` | Sets whether DuckDB runs every query. On a mixed workload, it speeds up `count(distinct)` and similar aggregates but slows index lookups, top-K queries ordered by primary key, and JSON access, so benchmark before you enable it. The default is `off`. |
| `duckdb.temporary_directory` | Sets where DuckDB writes spill files. Each backend writes to its own subdirectory, named after its process ID, so concurrent spills cannot collide; a subdirectory left by a backend that has exited is reclaimed. See [DuckDB: Spill Files Are Not Namespaced per Instance](architecture_guides/index.md#duckdb-spill-files-are-not-namespaced-per-instance). |
| `duckdb.max_temp_directory_size` | Caps the disk space that spill files can use for each connection, not for the whole cluster. For a cluster-wide budget, divide the budget by the number of concurrent sessions, or give the spill directory its own filesystem or quota. The default is 90% of the free space, for each session. |

## Writing ColdFront's Configuration

ColdFront stores its configuration in three places:

- Server-level settings are in `postgresql.conf`.
- The configuration of each managed table is a row in
  `coldfront.partition_config`.
- The object store credential is in `coldfront.storage_secret`.

You can write the table configuration and the credential with two commands,
or with one import of a deployment YAML file.

The examples use the `archiver` command that the `pgedge-coldfront` package
installs. After a build from source, run `./bin/archiver` from the source
directory instead.

### Using Commands

Use the following steps to write the configuration with commands:

1. Store the object store credential in `coldfront.storage_secret`. The
   [Configuring your Object Store](object_store.md) guide lists the values
   for each supported backend:

    - `<access-key-id>` is your object store's access key.
    - `<secret-key>` is the matching secret.
    - `<endpoint>` is your object store's endpoint.

    ```sql
    SELECT coldfront.set_storage_secret('<access-key-id>', '<secret-key>', '<endpoint>');
    ```

2. Register each table in `coldfront.partition_config`:

    - `<table>` is the table name.
    - `<period>` is the partition cadence; for example, `monthly`.
    - `<hot-period>` is how long a partition stays hot before the archiver
      moves it to the cold tier.

    ```bash
    archiver register --table <table> \
        --period <period> --hot-period "<hot-period>"
    ```

### Importing a Deployment YAML File

Use the following command to write the same configuration in one step:

```bash
archiver import --config deploy.yaml
```

The `pgedge-coldfront` package installs an example file at
`/usr/share/doc/pgedge-coldfront/examples/config.example.yaml`. Edit a copy of
the example and pass the copy to `import`; no ColdFront tool reads a YAML file
unless `--config` names it. A system set to skip package documentation, as
many container images are, does not install the example. The repository and
each release tarball include the same
[`config.example.yaml`](https://github.com/pgEdge/ColdFront/blob/main/config.example.yaml)
file.

After an import, the server holds the configuration. When a later run is
given a YAML file, it compares the file with the server and refuses to run if
any value differs. The only value such a run takes from the file is
`postgres.dsn`, which it uses to connect when `--dsn` is not set.

The
[Managing Partitioned Tables (CLI)](using_coldfront/index.md#managing-partitioned-tables-cli)
section of the Using ColdFront guide describes the `register`, `import`, and
`export` commands.
