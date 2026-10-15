# pgEdge ColdFront

[![CI](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml/badge.svg)](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml)

## Table of Contents

The ColdFront documentation consists of the following guides:

- [pgEdge ColdFront](docs/index.md)
- [Architecture Guides](docs/architecture_guides/index.md) - Describes the
  shared architecture and core mechanics.
    - [Tiered Operating Mode](docs/architecture_tiered.md) - Describes tiered
      mode (hot PostgreSQL plus cold Iceberg) in depth.
    - [Decoupled (Iceberg-Only) Operating Mode](docs/architecture_decoupled.md) -
      Describes decoupled (Iceberg-only) mode in depth.
    - [Vector Storage Architecture](docs/architecture_vectors.md) - Describes
      vector storage internals: type mapping, routing state, cluster
      assignment, and layout.
- Installing and Configuring ColdFront
    - [Installing ColdFront](docs/installation.md) - Documents installing from
      a package or building from source (Docker or bare-metal), and testing and
      CI.
    - [Configuring ColdFront](docs/configuration.md) - Documents configuring
      PostgreSQL and ColdFront's own configuration.
        - [Configuring Lakekeeper](docs/configure_lakekeeper.md) - Installs,
          configures, and bootstraps Lakekeeper, then installs the extensions
          each database needs.
        - [Configuring your Object Store](docs/object_store.md) - Gets
          ColdFront running end to end, for any of four supported backends:
          S3-compatible, virtual-hosted cloud S3, GCS, or Azure ADLS Gen2.
        - [Configuring a Distributed Deployment](docs/distributed_setup.md) -
          Documents running a multi-writer decoupled-mode Spock mesh against
          one shared lake.
- [Using ColdFront](docs/using_coldfront/index.md) - Compares the three
  operating modes, documents the shared SQL surface, and covers dropping an
  Iceberg table and the partition management CLI.
    - [Using ColdFront in Tiered Mode](docs/usage_tiered.md) - Documents
      archiving aging partitions to Iceberg while recent rows stay in the
      PostgreSQL heap.
    - [Using ColdFront in Decoupled Mode](docs/usage_decoupled.md) - Documents
      tables that live entirely in Iceberg from the first row, including
      adopting a table from the catalog and handing it back.
    - [Using ColdFront in Standalone Partitioned Mode](docs/usage_partitioner.md) -
      Documents managing PostgreSQL partitions with no cold tier at all.
    - [Working with Embeddings](docs/usage_vectors.md) - Documents storing and
      searching embeddings with the pgvector interface.
- [Exploring ColdFront Modes](docs/exploring_coldfront/index.md) - Sets up the
  demo stack and runs ColdFront hands-on.
    - [Exploring Tiered Storage](docs/walkthrough_tiered.md) - Adds ColdFront
      to an existing database and moves its cold data to object storage.
    - [Exploring Decoupled Mode](docs/walkthrough_decoupled.md) - Stores a
      table in Iceberg from the first row and adopts a table that another
      engine wrote.
    - [Exploring the Standalone Partitioner](docs/walkthrough_partitioner.md) -
      Manages PostgreSQL range partitions without any cold tier.
    - [Exploring Distributed Mode](docs/walkthrough_distributed.md) - Points
      two PostgreSQL nodes at one shared lake.
- [Connecting to ColdFront](docs/connecting.md) - Documents onboarding an
  application role with least privilege.
- Administration
    - [Understanding ColdFront Caveats](docs/caveats.md) - Documents cross-tier
      isolation, mixed transactions, and other edge cases shared between tiered
      and decoupled tables.
    - [Using Vended Credentials](docs/vended_credentials.md) - Documents
      running with no stored object-store credential, for AWS S3 and Azure ADLS
      Gen2.
    - [Supported Column Types](docs/supported_types.md) - Documents the
      PostgreSQL column types, including arrays, that a cold tier supports.
    - [Compacting the Cold Tier](docs/compaction.md) - Documents cold-tier
      table maintenance: compaction, snapshot expiry, and orphan-file removal.
- Developer Resources
    - [Formal Model - ColdFront Decoupled-Mode Bakery (TLA+/PlusCal)](docs/formal/README.md)
- [Release Notes - Changelog](docs/changelog.md)
- [License](docs/LICENSE.md)

ColdFront keeps tables in PostgreSQL and cold data in Apache Iceberg (Parquet
on S3-compatible, Azure, or GCS storage). The cold tier is both readable and
writable through the same SQL, with no application changes. The application
queries every table as an ordinary PostgreSQL relation, with standard
`SELECT`, `INSERT`, `UPDATE`, and `DELETE`, and `MERGE` on PostgreSQL 17 and
later.

> [!WARNING]
> ColdFront is beta software under active development. Do not use it in
> production. Interfaces, on-disk formats, and behavior may change without
> notice, and data loss is possible.

ColdFront provides three operating modes:

- Tiered mode keeps recent data in native PostgreSQL partitions and archives
  older data to Iceberg on a watermark; the application reads a single unified
  view, and the archiver moves rows from hot to cold on a schedule.
- Decoupled mode stores the table entirely in Iceberg from the first row;
  PostgreSQL holds a thin wrapper view and a registry row, and the `coldfront`
  extension handles every data-modifying statement on that view.
- Standalone partitioned mode manages time- or id-based PostgreSQL range
  partitions with no cold tier; the `partitioner` binary creates upcoming
  partitions and detaches and drops partitions past retention, on stock
  PostgreSQL with no DuckDB or Iceberg.

Tables in different modes can share one database, and you choose the mode for
each table: tiered when you register an existing partitioned table with a hot
period, standalone partitioned when you register one without a hot period,
and decoupled when you create or adopt an Iceberg table.

Decoupled mode scales out horizontally across many PostgreSQL nodes that share
one Lakekeeper catalog and one object store. The bakery protocol in the
`coldfront` extension serializes Iceberg commits on the PostgreSQL side using
Spock-replicated Snowflake tickets, so concurrent writers never collide at the
catalog. The protocol implements
[Lamport mutual exclusion](https://en.wikipedia.org/wiki/Lamport%27s_distributed_mutual_exclusion_algorithm)
with the
[Ricart-Agrawala](https://en.wikipedia.org/wiki/Ricart%E2%80%93Agrawala_algorithm)
deferred-reply optimization, and the
[formal model](docs/formal/README.md) verifies its safety with TLA+.

## How It Works

ColdFront runs inside PostgreSQL and rewrites each statement to the correct
tier, so the application sees one relation:

```text
                            Application
                                │
                SELECT / INSERT / UPDATE / DELETE
                    on one relation: "events"
                                │
   ┌────────────────────────────▼─────────────────────────────┐
   │                 PostgreSQL 16 / 17 / 18                  │
   │                                                          │
   │  events view: reads return hot + cold rows               │
   │  coldfront extension: routes writes by tier.             │
   └───────────┬─────────────────────────────────┬────────────┘
               │                                 │
           HOT TIER                          COLD TIER
    recent rows, local disk         older rows, object storage
               │                                 │
    ┌──────────▼───────────┐        ┌────────────▼────────────┐
    │ _events              │        │ pg_duckdb               │
    │ native PostgreSQL    │        │ in-process DuckDB       │
    │ range partitions     │        │ Iceberg reads + writes  │
    └──────────┬───────────┘        └────────────┬────────────┘
               │                                 │
               │                     ┌───────────▼─────────────┐
               │                     │ Lakekeeper              │
               │                     │ Iceberg REST catalog    │
               │                     └───────────┬─────────────┘
               │                                 │ 
               │                                 │
               │                     ┌───────────▼─────────────────────┐
               │                     │ Object store, S3 / Azure / GCS  │
               │                     │                                 │
               └── Archiver (Go) ───▶│(Parquet data + Iceberg metadata)│
                                     └─────────────────────────────────┘
                   cron job: moves partitions out of the hot window: hot -> cold
```

ColdFront stores its settings in the server and has no configuration file.
Settings live in two places:

- `postgresql.conf` holds the server settings:
    - You must set `shared_preload_libraries`, `coldfront.warehouse`, and
      `coldfront.lakekeeper_endpoint` on each server.
    - `shared_preload_libraries` must include `pg_duckdb` and `coldfront`.
    - You must also set `snowflake.node` and `coldfront.loopback_dsn` on each
      node of a Spock mesh.
- Tables in the `coldfront` schema hold additional parameters:
    - `coldfront.partition_config` holds each table's lifecycle.
    - `coldfront.storage_secret` holds the cold-store credential.

The archiver, partitioner, and compactor connect through the libpq environment
or `--dsn`, and read the settings from the server. To load a deployment YAML
into the server, run `archiver import --config <file>` once. Model the file on
[config.example.yaml](config.example.yaml). A later run checks any YAML you
pass against the server and uses only its `postgres.dsn`.

To review a list of available settings, see:

- The [Configuring Lakekeeper](docs/configure_lakekeeper.md) guide.
- The [Configuring PostgreSQL](docs/configuration.md#configuring-postgresql)
  section of the Configuring ColdFront guide.

## Installing and Configuring ColdFront

ColdFront runs on PostgreSQL 16, 17, and 18. A single node needs only stock
PostgreSQL. Distributed mode needs pgEdge's PostgreSQL build with Spock, which
the Docker image is based on. You can install ColdFront from pgEdge packages or
build it from source in a Docker container or on bare metal.

### Installing and Configuring ColdFront with Packages

ColdFront packages come from the pgEdge package repository. First, configure
the repository for your platform, as described in the
[pgEdge Enterprise Postgres guide](https://docs.pgedge.com/enterprise/). Then,
install the ColdFront extension package for your PostgreSQL major version. The
package manager also installs the pgEdge PostgreSQL server, pg_duckdb, and
ColdFront's DuckDB extensions.

For PostgreSQL 18 on RHEL, Rocky Linux, or AlmaLinux:

```bash
sudo dnf install -y pgedge-coldfront_18
```

For PostgreSQL 18 on Ubuntu or Debian:

```bash
sudo apt update
sudo apt install -y pgedge-postgresql-18-coldfront
```

The extension package does not include the command-line tools or Lakekeeper.
Install `pgedge-coldfront` and `pgedge-lakekeeper` on the hosts that need
them. For repository setup and every package name, see
[Using a Package to Install ColdFront](docs/installation.md#using-a-package-to-install-coldfront).

After installing the packages, use the following steps to configure PostgreSQL
and create the extensions:

1. Add the following settings to `postgresql.conf`:

    ```ini
    shared_preload_libraries = 'pg_duckdb,coldfront'
    duckdb.extension_directory = '/usr/lib/pgedge/coldfront/duckdb-extensions'
    duckdb.allow_unsigned_extensions = true
    duckdb.autoinstall_known_extensions = false
    coldfront.warehouse = '<warehouse-name>'
    coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
    ```

    The three `duckdb.*` settings make pg_duckdb load ColdFront's patched
    DuckDB extensions. Without them, pg_duckdb can fetch the unpatched
    upstream extensions instead.

2. Restart PostgreSQL. `CREATE EXTENSION coldfront` fails on a server that
    does not preload the extension.

3. Connect to the database and create the extensions:

    ```sql
    CREATE EXTENSION pg_duckdb;
    CREATE EXTENSION coldfront;
    ```

### Installing and Configuring ColdFront in a Docker Container

The Docker build adds a thin ColdFront layer to a published base image. The
base image already includes pg_duckdb and the patched duckdb-iceberg
extension. You need Docker and network access. To build the command-line
tools, you also need Go 1.26.5 or later and golangci-lint.

The Docker image writes the server settings into `postgresql.conf` on first
start. It reads the warehouse name and the Lakekeeper endpoint from the
`COLDFRONT_WAREHOUSE` and `COLDFRONT_LAKEKEEPER` environment variables in
`docker-compose.yml`. The defaults, `wh` and `http://lakekeeper:8181/catalog`,
match the warehouse that [Configuring Lakekeeper](docs/configure_lakekeeper.md)
creates.

1. Clone the repository:

    ```bash
    git clone https://github.com/pgEdge/coldfront.git
    cd coldfront
    ```

2. Build the command-line tools. `make build` builds the archiver and the
    partitioner, and `make compactor` builds the compactor:

    ```bash
    make build
    make compactor
    ```

3. Build the ColdFront layer and start the stack. The `local-store` profile
    adds a SeaweedFS object store to the stack. The stack uses PostgreSQL 18
    unless you set `PG_MAJOR`:

    ```bash
    docker compose --profile local-store up -d --build
    ```

4. Connect to the database:

    ```bash
    psql -h localhost -U coldfront -d coldfront
    ```

5. Create the extensions:

    ```sql
    CREATE EXTENSION pg_duckdb;
    CREATE EXTENSION coldfront;
    ```

The deployed image is for development and testing. It trusts every connection
without a password. For information about the image's environment variables
and a smoke test, see
[Building the Image on Docker](docs/installation.md#building-the-image-on-docker).

### Installing and Configuring ColdFront on Bare Metal

Before building ColdFront on bare metal, install the pg_duckdb PostgreSQL
extension (built on DuckDB 1.5.4) and a patched duckdb-iceberg DuckDB
extension. For the prerequisites and the patches, see
[Building ColdFront from Source](docs/installation.md#building-coldfront-from-source).
You also need `pg_config`, the PostgreSQL server development headers, the
libpq headers and library, `make`, `gcc`, Go 1.26.5 or later, and
golangci-lint.

1. Clone the repository:

    ```bash
    git clone https://github.com/pgEdge/coldfront.git
    cd coldfront
    ```

2. Build and install the `coldfront` extension. `pg_config` must be on your
    `PATH`:

    ```bash
    cd extension/coldfront
    make && make install
    ```

3. Build the command-line tools. `make build` builds the archiver and the
    partitioner, and `make compactor` builds the compactor:

    ```bash
    cd ../..
    make build
    make compactor
    ```

4. Copy the DuckDB extensions you built into the directory that pg_duckdb
    loads them from. Copy `iceberg`, `avro`, `azure`, and `postgres_scanner`
    into `$PGDATA/pg_duckdb/extensions/v1.5.4/linux_<arch>/`, where `<arch>` is
    `amd64` or `arm64`.

5. Add the following settings to `postgresql.conf`:

    ```ini
    shared_preload_libraries = 'pg_duckdb,coldfront'
    duckdb.allow_unsigned_extensions = true
    coldfront.warehouse = '<warehouse-name>'
    coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
    ```

    The locally built `iceberg` extension is unsigned, so
    `duckdb.allow_unsigned_extensions` must be on.

6. Restart PostgreSQL. `CREATE EXTENSION coldfront` fails on a server that
    does not preload the extension.

7. Connect to the database and create the extensions:

    ```sql
    CREATE EXTENSION pg_duckdb;
    CREATE EXTENSION coldfront;
    ```

For the full steps, see
[Building ColdFront on Bare Metal](docs/installation.md#building-coldfront-on-bare-metal).

### Connecting ColdFront to Lakekeeper and Object Storage

After configuring the server and creating the extensions, you're ready to
connect ColdFront to Lakekeeper and an object store. ColdFront stores the cold
tier in an object store, through a Lakekeeper warehouse.

ColdFront can store its Iceberg tables in AWS S3, in an S3-compatible store
such as SeaweedFS or MinIO, in Google Cloud Storage, or in Azure ADLS Gen2. You
set up the object store and the Lakekeeper warehouse once for each deployment.
The store's credential is kept in each database, so you repeat the credential
step in every database that uses ColdFront.

#### Connecting a Package or Bare-Metal Installation to Lakekeeper and an Object Store

A package or bare-metal installation runs Lakekeeper and an object store on
the host.

1. Start an object store. If you're walking through this installation to
    evaluate ColdFront, you can use SeaweedFS, a free S3-compatible store, on
    the host. The repository's `seaweedfs-s3.json` sets its credentials to
    `admin` and `adminsecret`:

    ```bash
    weed server -s3 -dir=/var/lib/seaweedfs \
      -s3.config=docker/seaweedfs-s3.json
    ```

    If you would like to evaluate ColdFront on AWS S3, Google Cloud Storage,
    or Azure ADLS Gen2, create a bucket or container there instead. The
    [Configuring your Object Store](docs/object_store.md) guide covers
    configuration of each one, including production stores.

2. Install Lakekeeper. With the pgEdge repository configured, install the
    `pgedge-lakekeeper` package:

    ```bash
    sudo dnf install -y pgedge-lakekeeper        # RHEL, Rocky Linux, AlmaLinux
    sudo apt install -y pgedge-lakekeeper        # Ubuntu, Debian
    ```

    If you're not using the pgEdge repository, install the upstream binary as
    described in
    [Installing Lakekeeper](docs/configure_lakekeeper.md#installing-lakekeeper).
    Then copy the environment file and the systemd unit from the ColdFront
    repository:

    ```bash
    sudo install -D -m 0640 -g lakekeeper \
      packaging/lakekeeper/common/lakekeeper.env /etc/lakekeeper/lakekeeper.env
    sudo install -m 0644 packaging/lakekeeper/common/lakekeeper.service \
      /etc/systemd/system/lakekeeper.service
    sudo systemctl daemon-reload
    ```

3. Create a role and a database for the Lakekeeper catalog:

    ```sql
    CREATE ROLE lakekeeper LOGIN PASSWORD 'change-me';
    CREATE DATABASE lakekeeper OWNER lakekeeper;
    ```

4. In `/etc/lakekeeper/lakekeeper.env`, set the catalog's connection string
    and an encryption key. Keep the key stable and backed up:

    ```bash
    LAKEKEEPER__PG_DATABASE_URL_WRITE=postgresql://lakekeeper:change-me@127.0.0.1:5432/lakekeeper
    LAKEKEEPER__PG_ENCRYPTION_KEY=<output of: openssl rand -base64 32>
    ```

5. Run the one-time migration as the `lakekeeper` user, then start
    Lakekeeper. The migration reads the environment file as that user, because
    the file is not readable by other accounts:

    ```bash
    sudo -u lakekeeper sh -c \
      'set -a; . /etc/lakekeeper/lakekeeper.env; set +a; exec /usr/bin/lakekeeper migrate'
    sudo systemctl enable --now lakekeeper
    ```

6. Bootstrap Lakekeeper, create the `wh` warehouse on the SeaweedFS store, and
    create the `public` namespace; decoupled mode requires this namespace. The
    warehouse name must match `coldfront.warehouse`:

    ```bash
    curl -X POST http://localhost:8181/management/v1/bootstrap \
      -H "Content-Type: application/json" -d '{"accept-terms-of-use":true}'

    curl -X POST http://localhost:8181/management/v1/warehouse \
      -H "Content-Type: application/json" -d '{
        "warehouse-name": "wh",
        "storage-profile": {
          "type": "s3", "bucket": "iceberg", "region": "us-east-1",
          "endpoint": "http://localhost:8333", "path-style-access": true,
          "flavor": "s3-compat", "sts-enabled": false,
          "remote-signing-enabled": false
        },
        "storage-credential": {
          "type": "s3", "credential-type": "access-key",
          "aws-access-key-id": "admin", "aws-secret-access-key": "adminsecret"
        }
      }'

    WID=$(curl -s http://localhost:8181/management/v1/warehouse \
      | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
      -H "Content-Type: application/json" -d '{"namespace":["public"]}'
    ```

    If you're using a different type of object store, change the
    `storage-profile` and `storage-credential` as shown in the store's section
    of [Configuring your Object Store](docs/object_store.md#configuring-lakekeeper).

7. Store the SeaweedFS credential in each database that uses ColdFront:

    ```sql
    SELECT coldfront.set_storage_secret('admin', 'adminsecret',
                                        'localhost:8333');
    ```

    If you use `coldfront.local_pg_dsn`, set it before this call. Another store
    takes its own arguments, and Azure ADLS Gen2 uses
    `coldfront.set_storage_secret_azure()` instead.

#### Connecting a Docker Installation to Lakekeeper and an Object Store

The Docker stack includes a SeaweedFS store, so you can use it as the cold tier
to evaluate ColdFront without a cloud account.

1. Bootstrap Lakekeeper:

    ```bash
    curl -X POST http://localhost:8181/management/v1/bootstrap \
      -H "Content-Type: application/json" -d '{"accept-terms-of-use":true}'
    ```

2. Create the `wh` warehouse on the SeaweedFS store:

    ```bash
    curl -X POST http://localhost:8181/management/v1/warehouse \
      -H "Content-Type: application/json" -d '{
        "warehouse-name": "wh",
        "storage-profile": {
          "type": "s3", "bucket": "iceberg", "region": "us-east-1",
          "endpoint": "http://seaweedfs:8333", "path-style-access": true,
          "flavor": "s3-compat", "sts-enabled": false,
          "remote-signing-enabled": false
        },
        "storage-credential": {
          "type": "s3", "credential-type": "access-key",
          "aws-access-key-id": "admin", "aws-secret-access-key": "adminsecret"
        }
      }'
    ```

3. Create the `public` namespace in the warehouse; decoupled mode requires
    this namespace:

    ```bash
    WID=$(curl -s http://localhost:8181/management/v1/warehouse \
      | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
      -H "Content-Type: application/json" -d '{"namespace":["public"]}'
    ```

4. Store the SeaweedFS credential in each database that uses ColdFront:

    ```sql
    SELECT coldfront.set_storage_secret('admin', 'adminsecret',
                                        'seaweedfs:8333');
    ```

#### Granting Access to Application Roles

After connecting ColdFront to Lakekeeper and an object store, you must grant
access to each application role that connects as a non-superuser. Replace
`<role_name>` with the name of the role:

```sql
SELECT coldfront.grant_app_access('<role_name>');
```

Run this command again after you create, adopt, or first tier a table. The
[Connecting to ColdFront](docs/connecting.md) guide describes the privileges
granted to the role.

## Support & Resources

After you install, configure, and connect ColdFront, use the following
resources to learn more:

- To try each of the three modes with commands you can copy and run, follow
  the [guided walkthrough](docs/exploring_coldfront/index.md).
- For information about using ColdFront, see
  [Using ColdFront](docs/using_coldfront/index.md), which helps you choose a
  mode and create your first table. Each mode has its own guide:
    - [Tiered Mode](docs/usage_tiered.md)
    - [Decoupled Mode](docs/usage_decoupled.md)
    - [Standalone Partitioned Mode](docs/usage_partitioner.md)
- To run ColdFront on more than one node, see
  [Configuring a Distributed Deployment](docs/distributed_setup.md).
- To review ColdFront caveats, see
  [Understanding ColdFront Caveats](docs/caveats.md).

For more information about pgEdge products, visit
[docs.pgedge.com](https://docs.pgedge.com).

To report an issue with the software, visit
[GitHub Issues](https://github.com/pgEdge/ColdFront/issues).

## For Developers

We welcome your contributions to ColdFront. For more information, see
[CONTRIBUTING.md](CONTRIBUTING.md). The following sections describe
ColdFront's dependencies, its version numbers, and the layout of the
repository.

### Author

Jimmy Angelakos created ColdFront.

### Dependencies

The following table lists the services and components ColdFront runs against:

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 16, 17, or 18 | Provides the database with native partitioning; stock PostgreSQL serves a single node, and the Docker image and distributed mode use pgEdge's PostgreSQL build with Spock. |
| pg_duckdb | commit c04e6a2 (PR #1025), on DuckDB 1.5.4 | Runs Iceberg reads and writes through in-process DuckDB. |
| duckdb-iceberg | `v1.5-variegata` @ `5edc45f0`, patched | Provides Iceberg catalog and I/O for DuckDB, with ColdFront's five patches applied (see [docker/Dockerfile.duckdb15-base](docker/Dockerfile.duckdb15-base)). |
| Lakekeeper | latest | Provides the Iceberg REST catalog (a Rust binary). |
| S3-compatible store | any | Stores the cold data; SeaweedFS, MinIO, AWS S3, and GCS all work. |
| Azure ADLS Gen2 | any | Stores the cold data instead of an S3 store, through `set_storage_secret_azure` and an `adls` warehouse. |

Building from source needs the Go toolchain (the version is pinned in
[go.mod](go.mod)). The Go module dependencies are the source of truth in
[go.mod](go.mod) / [go.sum](go.sum); the archiver and partitioner build as
static, CGO-free binaries on `pgx/v5`, and the compactor is a separate module
([cmd/compactor/go.mod](cmd/compactor/go.mod)) built on `apache/iceberg-go`.

### Versioning

ColdFront has two independent version numbers, each following its own
convention:

- Release tags use three-part [Semantic Versioning](https://semver.org)
  (`vMAJOR.MINOR.PATCH`, for example `v1.0.0`); Git tags, GitHub releases,
  container image tags, and the changelog all use this form. Three parts are
  required because ColdFront is a Go module, and the toolchain recognizes only
  full `vX.Y.Z` tags as releases. The patch field keeps a bugfix-only release
  (`v1.0.1`) distinct from a feature release (`v1.1.0`), which matters for a
  data-writing extension, where a release that keeps the same behavior and adds
  one safety fix must be easy to recognize.
- The PostgreSQL extension uses the conventional two-part version in its
  control file (`default_version = '1.0'`) and upgrade-script filenames
  (`coldfront--1.0--1.1.sql`), as is standard for PostgreSQL extensions.

The two map cleanly: extension `1.0` ships inside release `v1.0.0`, and a patch
release may keep the same extension version or bump it with an upgrade script
when the SQL changes.

### Project Structure

The repository is laid out as follows:

```text
pgedge-coldfront/
├── cmd/
│   ├── archiver/               ← tiering daemon: moves expired PG partitions → Iceberg (pure Go, pgx)
│   ├── partitioner/            ← standalone partition-manager CLI (time/id modes, 2-level)
│   └── compactor/              ← cold-tier maintenance: compaction, snapshot expiry, orphan removal (iceberg-go)
├── internal/
│   ├── config/                 ← YAML config loading + validation
│   ├── partcfg/                ← in-DB, Spock-replicated per-table lifecycle config
│   ├── partition/              ← partition create/find/detach/drop (time + id modes)
│   ├── sqlutil/                ← shared SQL helpers
│   ├── view/                   ← unified view generation
│   └── watermark/              ← archive_watermark table CRUD
├── extension/coldfront/        ← PGXS C extension (DML hooks, bakery, registry, SQL)
├── ci/
│   ├── journey.sh              ← THE canonical user journey (the E2E spec)
│   ├── matrix.sh               ← drives PG×topology×mode×target cells (--quick / --full)
│   ├── ops.sh                  ← operational checks (privilege model, Lakekeeper-down, S3-down)
│   ├── probe-standby.sh        ← risk gate: iceberg_scan on a read-only hot standby
│   ├── probe-snowflake.sh      ← risk gate: snowflake id↔epoch math vs the live extension
│   ├── lib.sh                  ← shared step/assert/psql helpers
│   ├── topo/                   ← vanilla.sh (1 node) · mesh.sh (3-node Spock)
│   └── runbooks/               ← failover-patroni.md (failover delegated to Patroni)
├── docker/
│   ├── Dockerfile.duckdb15-base ← DuckDB 1.5.x base (pg_duckdb on DuckDB 1.5.4 + patched iceberg)
│   ├── Dockerfile.duckdb15      ← thin coldfront app layer (ARG PG_MAJOR=16|17|18)
│   ├── iceberg-*.patch          ← duckdb-iceberg patches (bakery commit-refresh + strict-reader interop)
│   ├── iceberg-azure-extension-config-v15.cmake ← Azure ADLS extension build config
│   ├── entrypoint.sh
│   └── seaweedfs-s3.json        ← SeaweedFS S3 auth config (example)
├── docs/                       ← MkDocs site (user docs; mkdocs.yml at repo root)
│   ├── index.md · installation.md · configuration.md
│   ├── configure_lakekeeper.md · object_store.md · distributed_setup.md
│   ├── usage_tiered.md · usage_decoupled.md · usage_partitioner.md
│   ├── usage_vectors.md · connecting.md · caveats.md
│   ├── vended_credentials.md · supported_types.md · compaction.md
│   ├── walkthrough_tiered.md · walkthrough_decoupled.md
│   ├── walkthrough_partitioner.md · walkthrough_distributed.md
│   ├── architecture_tiered.md · architecture_decoupled.md
│   ├── architecture_vectors.md · changelog.md · LICENSE.md
│   ├── architecture_guides/    ← Architecture Guides landing page (index.md)
│   ├── exploring_coldfront/    ← Exploring ColdFront Modes landing page (index.md)
│   ├── using_coldfront/        ← Using ColdFront landing page (index.md)
│   └── formal/                 ← TLA+ model of the bakery protocol (Bakery.tla)
├── examples/walkthrough/       ← interactive walkthrough (guide.sh, its compose stack and configs)
├── docker-compose.yml          ← END-USER single-node stack (ports published)
├── docker-compose.matrix.yml   ← CI only: single-node vanilla matrix
├── docker-compose.matrix-azure.yml ← CI only: vanilla matrix on Azure ADLS
├── docker-compose.mesh.yml     ← CI only: 3-node Spock mesh
├── docker-compose.mesh-azure.yml ← CI only: 3-node Spock mesh on Azure ADLS
├── run-ci-local.sh             ← pre-commit gate (ci/matrix.sh --quick)
├── config.example.yaml · Makefile · mkdocs.yml
├── DUCKDB_1.5_PATCHED.md       ← the patched DuckDB 1.5 base: what's patched + how it's built
└── DUCKDB_1.5_UNPATCHED.md     ← building/running the base unpatched, and the consequences
```

## License

ColdFront is open source, licensed under the
[PostgreSQL License](LICENSE.md). The redistributed third-party components and
their notices are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
