# Configuring Lakekeeper

ColdFront requires three services configured once per deployment:
PostgreSQL with the pg_duckdb and `coldfront` extensions, Lakekeeper, and
any object store (SeaweedFS, MinIO, AWS S3, GCS, or Azure ADLS Gen2).
This guide brings up and bootstraps Lakekeeper, then installs and
configures the PostgreSQL side; do this before creating any table.

Lakekeeper is not part of ColdFront's own build; it is a separate
upstream project ([github.com/lakekeeper/lakekeeper](https://github.com/lakekeeper/lakekeeper)).
Choose how you are running it below.

## With Docker

Bring up the end-user stack first (the example uses SeaweedFS, gated
behind the `local-store` compose profile; host ports are published so
the `localhost` commands below work directly):

```bash
docker compose --profile local-store up -d --build
```

Lakekeeper is now reachable at `localhost:8181` with no further setup.
Continue with [Bootstrapping Lakekeeper](#bootstrapping-lakekeeper), and use
`http://seaweedfs:8333` as the store endpoint.

## Installing Lakekeeper

On bare metal, how you get the `lakekeeper` binary in place depends on
your installation path; continue with Preparing and Starting Lakekeeper
below either way.

### Performing a Package Installation

The `pgedge-lakekeeper` package installs the `lakekeeper` binary and a
`lakekeeper` systemd service, but it does not enable or start the
service.

### Installing the Upstream Binary

Download the matching upstream prebuilt release directly - there is no
source build; the release ships a single stripped binary (glibc 2.34 or
later required):

```bash
ARCH=$(uname -m)   # x86_64 or aarch64
LAKEKEEPER_VERSION=0.13.1
curl -LO "https://github.com/lakekeeper/lakekeeper/releases/download/v${LAKEKEEPER_VERSION}/lakekeeper-${ARCH}-unknown-linux-gnu.tar.gz"
tar xzf "lakekeeper-${ARCH}-unknown-linux-gnu.tar.gz"
sudo install -m 0755 lakekeeper /usr/bin/lakekeeper
```

Create the system user the steps below run as:

```bash
sudo groupadd -r lakekeeper
sudo useradd -r -g lakekeeper -d /var/lib/lakekeeper -s /sbin/nologin \
  -c "Lakekeeper Iceberg REST Catalog" lakekeeper
```

This repository's own packaging templates make convenient starting
points for the environment file and systemd unit, since you already
have the repo cloned to build the `coldfront` extension:
`packaging/lakekeeper/common/lakekeeper.env` and
`packaging/lakekeeper/common/lakekeeper.service`. Copy them into place, with
the environment file readable only by root and the `lakekeeper` group, as the
package installs it:

```bash
sudo install -D -m 0640 -g lakekeeper packaging/lakekeeper/common/lakekeeper.env \
  /etc/lakekeeper/lakekeeper.env
sudo install -m 0644 packaging/lakekeeper/common/lakekeeper.service \
  /etc/systemd/system/lakekeeper.service
sudo systemctl daemon-reload
```

## Preparing and Starting Lakekeeper

Lakekeeper stores its catalog in a PostgreSQL 15 or later database and
reads its settings from `/etc/lakekeeper/lakekeeper.env`. The
following steps prepare and start the service, whichever way you
installed it:

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

3. Run the one-time database migration as the `lakekeeper` user. The
    command reads the environment file as that user, because the file is not
    readable by other accounts:

    ```bash
    sudo -u lakekeeper sh -c \
      'set -a; . /etc/lakekeeper/lakekeeper.env; set +a; exec /usr/bin/lakekeeper migrate'
    ```

4. Enable and start the service:

    ```bash
    sudo systemctl enable --now lakekeeper
    ```

Lakekeeper listens on port 8181 on every address by default. Without an
authorization backend in `lakekeeper.env`, the catalog accepts every request,
so configure authentication and authorization before you expose the service
beyond a trusted network.

## Bootstrapping Lakekeeper

Bootstrap Lakekeeper, create the warehouse, and pre-create the Iceberg
namespace. In the warehouse command, replace `<store-endpoint>` with the
address Lakekeeper uses to reach your store: `http://seaweedfs:8333` for the
SeaweedFS store in the Docker stack, or `http://localhost:8333` for SeaweedFS
running on the same host. For another store, change the `storage-profile` and
`storage-credential` as shown in
[Configuring your Object Store](object_store.md#configuring-lakekeeper).

```bash
# 1. Bootstrap Lakekeeper
curl -X POST http://localhost:8181/management/v1/bootstrap \
  -H "Content-Type: application/json" -d '{"accept-terms-of-use":true}'

# 2. Create the warehouse and save its ID (replace <store-endpoint> as
#    described above)
WID=$(curl -s -X POST http://localhost:8181/management/v1/warehouse \
  -H "Content-Type: application/json" -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "s3", "bucket": "iceberg", "region": "us-east-1",
      "endpoint": "<store-endpoint>", "path-style-access": true,
      "flavor": "s3-compat", "sts-enabled": false,
      "remote-signing-enabled": false
    },
    "storage-credential": {
      "type": "s3", "credential-type": "access-key",
      "aws-access-key-id": "admin", "aws-secret-access-key": "adminsecret"
    }
  }' \
  | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)

# 3. Create the Iceberg namespace in the new warehouse.
#    REQUIRED for decoupled (iceberg-only) mode: the Iceberg CREATE SCHEMA is
#    deferred to transaction COMMIT but the CREATE TABLE POST is sent
#    immediately, so coldfront.create_iceberg_table - which runs both in one
#    transaction - would fail with HTTP 404 against a cold warehouse.
#    Pre-creating the namespace here (its own committed REST call) makes the
#    function's in-txn CREATE SCHEMA IF NOT EXISTS a no-op so the table create
#    succeeds. The archiver (tiered mode) creates the namespace itself and does
#    not need this.
curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H "Content-Type: application/json" -d '{"namespace":["public"]}'
```

## Configuring PostgreSQL for Lakekeeper

When Lakekeeper is bootstrapped, install the extensions and set the
cold-tier credentials, once per database. Replace `<store-endpoint>` with the
store's address as PostgreSQL reaches it, without the `http://` prefix:
`seaweedfs:8333` in the Docker stack, or `localhost:8333` for SeaweedFS on the
same host:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SELECT coldfront.set_storage_secret('admin', 'adminsecret', '<store-endpoint>');
```

The secret is stored in the `coldfront.storage_secret` table (excluded from
`pg_dump`; in a Spock mesh it replicates by value once added to the default
repset - one-time mesh setup step 4) and materialized as a DuckDB PERSISTENT
SECRET that loads at instance init. There is **no per-session setup**: the
Iceberg catalog `ice` attaches **lazily** by the coldfront C hook on the first
query that touches a tiered/decoupled view (read or write).

Every `set_storage_secret()` argument after the secret is optional.
`p_endpoint` defaults to `NULL`, `p_region` to `'us-east-1'`, `p_url_style` to
`'path'` (the other value is `'vhost'`), and `p_use_ssl` to `false`.
`p_url_style` and `p_use_ssl` apply only when an endpoint is given. A TLS
endpoint such as GCS's needs `p_use_ssl => true`, and AWS S3 omits the endpoint
and sets `p_region` to the bucket's Region.

The image writes the server settings ColdFront needs into `postgresql.conf`
when it initializes a new data directory. A server installed from packages or
built another way sets them itself, as the
[package](configuration.md#configuring-postgresql) and
[bare-metal](installation.md#building-coldfront-on-bare-metal) sections of
installation.md show:

- `shared_preload_libraries = 'pg_duckdb,coldfront'` loads both extensions at
  server start. coldfront refuses to load any other way: `CREATE EXTENSION
  coldfront` fails on a server that does not preload it, with an error that
  names the setting.
- `coldfront.warehouse` and `coldfront.lakekeeper_endpoint` name the Lakekeeper
  warehouse and its catalog endpoint, which the Iceberg catalog `ice` attaches
  to. Only a superuser can set them, and while either is empty the catalog does
  not attach.
- `coldfront.local_pg_dsn` is the connection string DuckDB uses to read
  PostgreSQL tables from this server, which a decoupled table's
  `INSERT … SELECT` from a PostgreSQL table needs, as does a cold write to a
  table with a clustered vector column. A tiered `INSERT` streams its cold
  rows through it, and renders them row by row when it is not set. Only a
  superuser can set or read it.
  Set it before calling `set_storage_secret()`, which installs the DuckDB
  `postgres` extension this path loads only when the setting is present.

An application that connects as a non-superuser needs its role granted access
with `coldfront.grant_app_access()`, which takes an existing role. Replace
`<role_name>` with the name of the role your application connects as:

```sql
SELECT coldfront.grant_app_access('<role_name>');
```

`coldfront.grant_app_access()` derives the grants from the registry when it
runs, so run it again after you create or adopt a table, or tier one for the
first time. The call fails while `duckdb.postgres_role` is unset, because only
superusers can then run DuckDB.
[Connecting to ColdFront](connecting.md#least-privilege-application-roles)
lists what it grants.

For a real cloud-S3 setup, see
[Configuring your Object Store](object_store.md).
