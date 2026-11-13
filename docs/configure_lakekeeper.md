# Configuring Lakekeeper

ColdFront needs three services, each configured once per deployment:

- PostgreSQL with the pg_duckdb and `coldfront` extensions.
- Lakekeeper, the Iceberg REST catalog.
- An object store, such as SeaweedFS, MinIO, AWS S3, GCS, or Azure ADLS Gen2.

This guide starts and bootstraps Lakekeeper, then installs and configures the
extensions in PostgreSQL. Complete this step before you create any table.

[Lakekeeper](https://github.com/lakekeeper/lakekeeper) is a separate upstream
project, not part of the ColdFront build. Perform the steps in the section that
matches how you install Lakekeeper:
[with packages](#installing-and-configuring-lakekeeper-with-packages),
[on bare metal](#installing-and-configuring-lakekeeper-on-bare-metal), or
[on Docker](#installing-and-configuring-lakekeeper-on-docker).

## Installing and Configuring Lakekeeper with Packages

The `pgedge-lakekeeper` package installs the `lakekeeper` binary, a
`lakekeeper` system user, and a `lakekeeper` systemd service, but it does not
configure, enable, or start the service. Lakekeeper stores its catalog in a
PostgreSQL 15 or later database and reads its settings from
`/etc/lakekeeper/lakekeeper.env`.

Use the following steps to install, configure, and start Lakekeeper:

1. If you did not install the `pgedge-lakekeeper` package with the
    [ColdFront packages](installation.md), install it now from the pgEdge
    repository.

    On RHEL, Rocky Linux, or AlmaLinux:

    ```bash
    sudo dnf install -y pgedge-lakekeeper
    ```

    On Ubuntu or Debian:

    ```bash
    sudo apt install -y pgedge-lakekeeper
    ```

2. Connect as a PostgreSQL superuser, such as `postgres` (for example, with
    `sudo -u postgres psql`), and create a role and a database for the catalog.
    Replace `<password>` with a generated password, such as the output of
    `openssl rand -hex 32`; a hex value needs no escaping in the connection
    string in step 3:

    ```sql
    CREATE ROLE lakekeeper LOGIN PASSWORD '<password>';
    CREATE DATABASE lakekeeper OWNER lakekeeper;
    ```

    !!! hint

        The migration in step 4 creates the `uuid-ossp`, `pgcrypto`,
        `pg_trgm`, `btree_gin`, and `btree_gist` extensions. Either allow the
        `lakekeeper` role to run `CREATE EXTENSION`, or create the extensions
        as a superuser before you run the migration.

3. In `/etc/lakekeeper/lakekeeper.env`, set the catalog database's
    connection string and an encryption key:

    ```bash
    LAKEKEEPER__PG_DATABASE_URL_WRITE=postgresql://lakekeeper:<password>@127.0.0.1:5432/lakekeeper
    LAKEKEEPER__PG_ENCRYPTION_KEY=<encryption-key>
    ```

    - Replace `<password>` with the password from step 2, and adjust the host
      and port if the catalog database is on another server.
    - Replace `<encryption-key>` with a random secret, such as the output of
      `openssl rand -base64 32`. Lakekeeper encrypts stored credentials with
      the key, so keep the key stable and backed up. Every node that shares
      the catalog needs the same key.

4. Run the one-time database migration as the `lakekeeper` user. The
    command reads the environment file as that user, because the file is not
    readable by other accounts:

    ```bash
    sudo -u lakekeeper sh -c \
      'set -a; . /etc/lakekeeper/lakekeeper.env; set +a; exec /usr/bin/lakekeeper migrate'
    ```

5. Secure the listener before you start the service. By default, Lakekeeper
    listens on port 8181 on every address and, with no authorization backend,
    accepts every request. Do not start it that way:

    - If every client runs on the same host, set the following in
      `/etc/lakekeeper/lakekeeper.env`:

        ```bash
        LAKEKEEPER__BIND_IP=127.0.0.1
        ```

    - If clients connect from other hosts, configure
      [authentication](https://docs.lakekeeper.io/docs/latest/authentication/)
      and an enforcing
      [authorization](https://docs.lakekeeper.io/docs/latest/authorization/)
      backend, and limit access to port 8181 with a firewall.

6. Enable and start the service:

    ```bash
    sudo systemctl enable --now lakekeeper
    ```

Then, bootstrap Lakekeeper as described in
[Bootstrapping Lakekeeper](#bootstrapping-lakekeeper).

## Installing and Configuring Lakekeeper on Bare Metal

Lakekeeper ships a single prebuilt binary that requires glibc 2.34 or later.
Use the following steps to install the binary and its service files:

1. Download the release for your architecture and install the binary:

    ```bash
    ARCH=$(uname -m)   # x86_64 or aarch64
    LAKEKEEPER_VERSION=0.13.1
    curl -LO "https://github.com/lakekeeper/lakekeeper/releases/download/v${LAKEKEEPER_VERSION}/lakekeeper-${ARCH}-unknown-linux-gnu.tar.gz"
    tar xzf "lakekeeper-${ARCH}-unknown-linux-gnu.tar.gz"
    sudo install -m 0755 lakekeeper /usr/bin/lakekeeper
    ```

2. Create the system user that runs Lakekeeper:

    ```bash
    sudo groupadd -r lakekeeper
    sudo useradd -r -g lakekeeper -d /var/lib/lakekeeper -s /sbin/nologin \
      -c "Lakekeeper Iceberg REST Catalog" lakekeeper
    ```

3. From your ColdFront repository clone, copy the environment file and the
    systemd unit that the package uses. The environment file is readable only
    by root and the `lakekeeper` group, as the package installs it:

    ```bash
    sudo install -D -m 0640 -g lakekeeper packaging/lakekeeper/common/lakekeeper.env \
      /etc/lakekeeper/lakekeeper.env
    sudo install -m 0644 packaging/lakekeeper/common/lakekeeper.service \
      /etc/systemd/system/lakekeeper.service
    sudo systemctl daemon-reload
    ```

4. Connect as a PostgreSQL superuser, such as `postgres` (for example, with
    `sudo -u postgres psql`), and create a role and a database for the catalog.
    Replace `<password>` with a generated password, such as the output of
    `openssl rand -hex 32`; a hex value needs no escaping in the connection
    string in step 5:

    ```sql
    CREATE ROLE lakekeeper LOGIN PASSWORD '<password>';
    CREATE DATABASE lakekeeper OWNER lakekeeper;
    ```

    !!! hint

        The migration in step 6 creates the `uuid-ossp`, `pgcrypto`,
        `pg_trgm`, `btree_gin`, and `btree_gist` extensions. Either allow the
        `lakekeeper` role to run `CREATE EXTENSION`, or create the extensions
        as a superuser before you run the migration.

5. In `/etc/lakekeeper/lakekeeper.env`, set the catalog database's
    connection string and an encryption key:

    ```bash
    LAKEKEEPER__PG_DATABASE_URL_WRITE=postgresql://lakekeeper:<password>@127.0.0.1:5432/lakekeeper
    LAKEKEEPER__PG_ENCRYPTION_KEY=<encryption-key>
    ```

    - Replace `<password>` with the password from step 4, and adjust the host
      and port if the catalog database is on another server.
    - Replace `<encryption-key>` with a random secret, such as the output of
      `openssl rand -base64 32`. Lakekeeper encrypts stored credentials with
      the key, so keep the key stable and backed up. Every node that shares
      the catalog needs the same key.

6. Run the one-time database migration as the `lakekeeper` user. The
    command reads the environment file as that user, because the file is not
    readable by other accounts:

    ```bash
    sudo -u lakekeeper sh -c \
      'set -a; . /etc/lakekeeper/lakekeeper.env; set +a; exec /usr/bin/lakekeeper migrate'
    ```

7. Secure the listener before you start the service. By default, Lakekeeper
    listens on port 8181 on every address and, with no authorization backend,
    accepts every request. Do not start it that way:

    - If every client runs on the same host, set the following in
      `/etc/lakekeeper/lakekeeper.env`:

        ```bash
        LAKEKEEPER__BIND_IP=127.0.0.1
        ```

    - If clients connect from other hosts, configure
      [authentication](https://docs.lakekeeper.io/docs/latest/authentication/)
      and an enforcing
      [authorization](https://docs.lakekeeper.io/docs/latest/authorization/)
      backend, and limit access to port 8181 with a firewall.

8. Enable and start the service:

    ```bash
    sudo systemctl enable --now lakekeeper
    ```

Then, bootstrap Lakekeeper as described in
[Bootstrapping Lakekeeper](#bootstrapping-lakekeeper).

## Installing and Configuring Lakekeeper on Docker

!!! warning

    The Docker stack is for development and testing on one host: PostgreSQL
    trusts every connection, and Lakekeeper runs without authentication.
    Before you let other hosts connect, configure authentication and an
    enforcing authorization backend for Lakekeeper, require passwords in
    PostgreSQL's `pg_hba.conf`, and limit access to the ports with a firewall.

The repository's Docker Compose stack runs Lakekeeper alongside PostgreSQL and
the SeaweedFS object store. The stack creates Lakekeeper's catalog database,
runs the migration, and starts the service, so Lakekeeper needs no further
installation or configuration.

If you started the stack while [building ColdFront on Docker](installation.md),
Lakekeeper is already running at `localhost:8181`, and you can continue with
[Bootstrapping Lakekeeper](#bootstrapping-lakekeeper). Otherwise, start the stack
from your ColdFront repository clone. The command publishes each port on the
loopback address only, so other hosts cannot connect:

```bash
COLDFRONT_PG_PORT=127.0.0.1:5432 COLDFRONT_LK_PORT=127.0.0.1:8181 \
COLDFRONT_S3_PORT=127.0.0.1:8333 \
  docker compose --profile local-store up -d --build
```

Then, continue with [Bootstrapping Lakekeeper](#bootstrapping-lakekeeper).
When the stack runs the SeaweedFS store, which it does only with the
`local-store` profile, use `http://seaweedfs:8333` as the store endpoint when
you bootstrap. For any other store, see
[Configuring your Object Store](object_store.md).

## Bootstrapping Lakekeeper

Use the following steps to bootstrap Lakekeeper and, for the SeaweedFS store,
create the warehouse and the Iceberg namespace. For any other store, perform
step 1 only, then create the warehouse, the namespace, and the credential as
described in your backend's section of
[Configuring your Object Store](object_store.md):

1. Bootstrap Lakekeeper:

    ```bash
    curl -X POST http://localhost:8181/management/v1/bootstrap \
      -H "Content-Type: application/json" -d '{"accept-terms-of-use":true}'
    ```

2. For the SeaweedFS store, create the warehouse and save its ID in `WID`. Replace `<store-endpoint>`
    with the address Lakekeeper uses to reach your store:

    - `http://seaweedfs:8333` for the SeaweedFS store in the Docker stack.
    - `http://localhost:8333` for SeaweedFS running on the same host.

    ```bash
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
    ```

3. For the SeaweedFS store, create the `public` namespace in the new
    warehouse. Decoupled mode needs the namespace before you create a table;
    in tiered mode, the archiver creates it itself.

    ```bash
    if [ -z "$WID" ]; then
      echo "No warehouse ID - check that the warehouse create succeeded."
    else
      curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
        -H "Content-Type: application/json" -d '{"namespace":["public"]}'
    fi
    ```

!!! hint

    If you run these commands again after the warehouse exists, the create
    request fails and `WID` is empty. Set `WID` to the `warehouse-id` of the
    `wh` warehouse in the output of
    `curl -s http://localhost:8181/management/v1/warehouse`, then rerun the
    namespace request.

## Configuring PostgreSQL for Lakekeeper

After bootstrapping Lakekeeper, install the extensions and set the cold-tier
credential in each database that uses ColdFront. If you use
`coldfront.local_pg_dsn`, described below, set it before you set the
credential. `set_storage_secret()` installs the DuckDB `postgres` extension
that the setting needs, but only when the setting is already present.

Install the extensions:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
```

For the SeaweedFS store, set the credential. Replace `<store-endpoint>` with
the store's address as PostgreSQL reaches it, without the `http://` prefix:

- `seaweedfs:8333` for the SeaweedFS store in the Docker stack.
- `localhost:8333` for SeaweedFS running on the same host.

```sql
SELECT coldfront.set_storage_secret('admin', 'adminsecret', '<store-endpoint>');
```

For any other store, set the credential as described in your backend's
section of [Configuring your Object Store](object_store.md).

`set_storage_secret()` stores the secret in the `coldfront.storage_secret`
table and creates a DuckDB persistent secret from it, which loads when DuckDB
starts. No per-session setup is needed: ColdFront attaches the Iceberg catalog
`ice` on the first query that reads or writes a tiered or decoupled table.

!!! hint

    `pg_dump` does not include the `coldfront.storage_secret` table. In a
    Spock mesh, the table replicates by value after
    [`coldfront.ensure_replicated()`](distributed_setup.md#what-coldfrontensure_replicated-does)
    adds it to the `default` replication set during the one-time mesh setup.

The arguments after the secret are optional:

| Argument | Description | Default |
|---|---|---|
| `p_endpoint` | The store's address, without the `http://` prefix. Omit it for AWS S3. | `NULL` |
| `p_region` | The store's region. For AWS S3, set it to the bucket's Region. | `'us-east-1'` |
| `p_url_style` | `'path'` or `'vhost'`. Applies only when `p_endpoint` is set. | `'path'` |
| `p_use_ssl` | Whether to connect over TLS. Set it to `true` for a TLS endpoint such as GCS. Applies only when `p_endpoint` is set. | `false` |

The image writes the server settings ColdFront needs into `postgresql.conf`
when it initializes a new data directory. A server installed from packages or
built another way sets them itself, as the
[package](configuration.md#configuring-postgresql) and
[bare-metal](installation.md#building-coldfront-from-source-on-bare-metal) sections of
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
  rows through this connection, and renders them row by row when the setting
  is empty. Only a superuser can set or read `coldfront.local_pg_dsn`.

If your application connects as a role that is not a superuser, grant that
role access to ColdFront. Replace `<role_name>` with the name of the existing
role that your application connects as:

```sql
SELECT coldfront.grant_app_access('<role_name>');
```

`coldfront.grant_app_access()` grants access to the tables that ColdFront
manages when you run it, so run it again after you create or adopt a table,
or tier a table for the first time. The
[Connecting to ColdFront](connecting.md#least-privilege-application-roles)
guide lists the grants.

The call fails when
[`duckdb.postgres_role`](configuration.md#configuring-postgresql) is not set,
because only superusers can run DuckDB without that setting.
