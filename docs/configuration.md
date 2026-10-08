# Configuring ColdFront

This guide covers configuring PostgreSQL, Lakekeeper, and ColdFront
itself, regardless of which installation path you used.

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

The three `duckdb.*` settings make pg_duckdb load ColdFront's patched DuckDB
extensions from the directory where `pgedge-coldfront-duckdb-extensions`
installs them. Without these settings, pg_duckdb downloads the unpatched
upstream extensions, and concurrent cold writes can then fail with HTTP 409.
The patched extensions are unsigned, so `duckdb.allow_unsigned_extensions` must
be on. Keeping `duckdb.autoinstall_known_extensions` off stops DuckDB from
downloading an unpatched upstream copy when an extension file is missing.

The two `coldfront.iceberg_*` settings take effect only on a Spock mesh, where
a node then uploads Parquet files outside the bakery claim and serializes only
the catalog commit. The packaged duckdb-iceberg includes the patch that this
ordering requires, and the
[Distributed Setup](usage.md#distributed-setup-3-node-mesh-decoupled-mode)
section of the Using ColdFront guide describes the mesh settings.

The [One-Time Setup](usage.md#one-time-setup) section of the Using ColdFront
guide describes the `coldfront.*` settings. Follow that section from the
Lakekeeper bootstrap onward to create the warehouse, the extensions, and the
cold-store credential.

## Setting Up Lakekeeper

The `pgedge-lakekeeper` package installs the `lakekeeper` binary and a
`lakekeeper` systemd service, but it does not enable or start the service.
Lakekeeper stores its catalog in a PostgreSQL 15 or later database and reads
its settings from `/etc/lakekeeper/lakekeeper.env`. The following steps
prepare and start the service:

1. Create a role and a database for the catalog:

    ```sql
    CREATE ROLE lakekeeper LOGIN PASSWORD 'change-me';
    CREATE DATABASE lakekeeper OWNER lakekeeper;
    ```

    The migration in step 3 creates the `uuid-ossp`, `pgcrypto`, `pg_trgm`,
    `btree_gin`, and `btree_gist` extensions, so either the role must be
    allowed to run `CREATE EXTENSION` or a superuser must create them first.

2. In `/etc/lakekeeper/lakekeeper.env`, set
    `LAKEKEEPER__PG_DATABASE_URL_WRITE` to the database's connection string and
    `LAKEKEEPER__PG_ENCRYPTION_KEY` to a random secret, such as the output of
    `openssl rand -base64 32`. Lakekeeper encrypts stored credentials with the
    key, so keep the key stable and backed up. Every node that shares the
    catalog needs the same key.

3. Run the one-time database migration as the `lakekeeper` user:

    ```bash
    set -a; . /etc/lakekeeper/lakekeeper.env; set +a
    sudo -E -u lakekeeper /usr/bin/lakekeeper migrate
    ```

4. Enable and start the service:

    ```bash
    sudo systemctl enable --now lakekeeper
    ```

Lakekeeper listens on port 8181 on every address by default. Without an
authorization backend in `lakekeeper.env`, the catalog accepts every request,
so configure authentication and authorization before you expose the service
beyond a trusted network.

## Writing ColdFront's Configuration

ColdFront has no configuration file, because the database holds its
configuration. The server settings are the `postgresql.conf` lines above, each
managed table is a row in `coldfront.partition_config`, and the cold-store
credential is in `coldfront.storage_secret`. The archiver, partitioner, and
compactor connect the way psql does, from the libpq environment (`PGHOST`,
`PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSERVICE`) or `--dsn`, and read every
other setting from the server.

You write that configuration with `coldfront.set_storage_secret()` and the
`register` command, or in one step by importing a deployment YAML:

```bash
archiver import --config deploy.yaml
```

The `pgedge-coldfront` package installs an example deployment YAML at
`/etc/pgedge/coldfront/config.yaml`. That file is only an example to edit and
pass to `import`, and no ColdFront tool reads it unless `--config` names it.
After an import, the server holds the configuration. A later run that is given
a YAML checks the file against the server and refuses to run if any value
differs. The only value such a run takes from the file is `postgres.dsn`, which
connects when `--dsn` is unset. The
[Managing Partitioned Tables (CLI)](usage.md#managing-partitioned-tables-cli)
section of the Using ColdFront guide describes `register`, `import`, and
`export`.
