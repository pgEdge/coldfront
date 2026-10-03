# pgEdge ColdFront

[![CI](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml/badge.svg)](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml)

## Table of Contents

The ColdFront documentation consists of the following guides:

- [Introduction](docs/index.md)
- Getting Started
    - [Running the Walkthrough](docs/walkthrough.md)
    - [Exploring the Walkthrough Demos](docs/walkthrough_demos.md)
    - [Building ColdFront from Source](docs/installation.md)
    - [Setting Up an Object Store](docs/object_store.md)
- Architecture
    - [Architecture Overview](docs/architecture.md)
    - [Tiered Mode](docs/architecture_tiered.md)
    - [Decoupled Mode](docs/architecture_decoupled.md)
    - [Vector Storage](docs/architecture_vectors.md)
- [Using ColdFront](docs/usage.md)
- [Storing and Searching Embeddings](docs/usage_vectors.md)
- [Compacting the Cold Tier](docs/compaction.md)
- Developer Resources
    - [Verifying the Bakery Protocol](docs/formal/README.md)
- [Release Notes](docs/changelog.md)

ColdFront keeps tables in PostgreSQL and cold data in Apache Iceberg (Parquet
on S3-compatible, Azure, or GCS storage), and the cold tier is both readable
and writable through the same SQL with no application changes. The application
queries every table as an ordinary PostgreSQL relation, and both operating
modes present the same standard SQL surface.

> [!WARNING]
> ColdFront is beta software under active development. Do not use it in
> production. Interfaces, on-disk formats, and behavior may change without
> notice, and data loss is possible.

ColdFront provides two operating modes:

- Tiered mode keeps recent data in native PostgreSQL partitions and archives
  older data to Iceberg on a watermark; the application reads a single unified
  view, and the archiver moves rows from hot to cold on a schedule.
- Decoupled mode stores the table entirely in Iceberg from the first row;
  PostgreSQL holds a thin wrapper view and a registry row, and the coldfront
  extension handles every data-modifying statement on that view.

Both modes coexist within one database, and you choose the mode per table at
creation time. The SQL surface is identical for both modes: standard `SELECT`,
`INSERT`, `UPDATE`, and `DELETE` against the relation, and `MERGE` on
PostgreSQL 17 and later.

Decoupled mode scales out horizontally across many PostgreSQL nodes that share
one Lakekeeper catalog and one object store. The bakery protocol in the
coldfront extension serializes Iceberg commits on the PostgreSQL side using
Spock-replicated Snowflake tickets, so concurrent writers never collide at the
catalog. The protocol implements Lamport mutual exclusion with the
Ricart-Agrawala deferred-reply optimization, and the
[formal model](docs/formal/README.md) verifies its safety with TLA+.

## How It Works

ColdFront runs inside PostgreSQL and rewrites each statement to the correct
tier, so the application sees one relation:

```text
                       Application
                            │
              SELECT / INSERT / UPDATE / DELETE
              against one relation: "events"
                            │
                 PostgreSQL 16 / 17 / 18
           events VIEW: reads union hot + cold
       coldfront extension: routes writes by tier
              ┌─────────────┴───────────────┐
              │                             │
          hot tier                      cold tier
      _events: native PostgreSQL    pg_duckdb: in-process DuckDB
      range partitions              Iceberg reads + writes
              │                             │
              │                     Lakekeeper (Iceberg REST catalog)
              │                             │
              │                     object store, S3 / Azure / GCS
              │                     (Parquet data + Iceberg metadata)
              │                             ▲
              └──── Archiver (Go, cron) ────┘
                    moves partitions past the hot window: hot → cold
```

## Installation

If you are new to ColdFront, run the [guided walkthrough](docs/walkthrough.md)
to see all three modes in action with copy-pasteable commands.

ColdFront is open source under the PostgreSQL License and runs on PostgreSQL
16, 17, and 18: stock PostgreSQL for a single node, and pgEdge's PostgreSQL
build with Spock, which the Docker image is based on, for distributed mode. The
full build workflow lives in the
**[Installation guide](docs/installation.md)**: build the thin ColdFront layer
on top of the published DuckDB 1.5.x base image (or build the base yourself),
or install bare-metal. Then continue with the Quickstart below.

### Setting Up on Cloud S3?

Once the image is built, the **[S3 setup guide](docs/object_store.md)** takes
you from an empty bucket to a working cold tier end-to-end.

## Configuration

ColdFront reads its settings from two places. The server settings live in
`postgresql.conf`: `shared_preload_libraries = 'pg_duckdb,coldfront'`,
`coldfront.warehouse` and `coldfront.lakekeeper_endpoint`, plus
`snowflake.node` and `coldfront.loopback_dsn` on every node of a mesh. The
Docker image writes them on first start. The archiver, partitioner and
compactor connect from the libpq environment or `--dsn` and read everything
else from the server: each table's lifecycle in `coldfront.partition_config`,
the cold-store credential in `coldfront.storage_secret` and the catalog
settings above. A deployment YAML, modeled on
[config.example.yaml](config.example.yaml), is written into the server once
with `import`. For every setting, see the
[One-Time Setup](docs/usage.md#one-time-setup) and
[Tuning Knobs](docs/usage.md#tuning-knobs) sections of the Using ColdFront
guide.

## Quickstart

Build the image (see the [Installation](docs/installation.md) guide) and bring
up the stack:

```bash
docker compose --profile local-store up -d --build
```

Bootstrap Lakekeeper and create a warehouse (see the one-time setup in the
[Using ColdFront](docs/usage.md) guide), then create a table in psql:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');

-- Decoupled (iceberg-only) table, stored entirely in Iceberg on S3:
SELECT coldfront.create_iceberg_table('public', 'events',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},{"name":"note","type":"text"}]'::jsonb,
  '{month(ts)}');
INSERT INTO events VALUES (1, now(), 'hello');
SELECT count(*) FROM events;
```

A table that already exists in the Iceberg catalog is adopted rather than
created: `coldfront.adopt_iceberg_table()` reads its schema from the catalog
and gives it the same wrapper view and registry row, read-only unless writes
are asked for. `coldfront.release_iceberg_table()` hands the table back with
the Iceberg table untouched. See
[Adopting a Table That Already Exists in the Catalog](docs/usage.md#adopting-a-table-that-already-exists-in-the-catalog).

To remove a table again, `coldfront.drop_iceberg_table()` unregisters it and
drops the Iceberg table, deleting the stored objects only when asked to. See
[Dropping an Iceberg Table](docs/usage.md#dropping-an-iceberg-table-both-modes).

For compliance environments that cannot store an object-store credential,
`coldfront.set_storage_secret_vended()` runs with no credential in the
database: Lakekeeper issues short-lived per-table credentials at access time.
See [Vended Credentials](docs/usage.md#vended-credentials).

## Using ColdFront

The Quickstart covers a decoupled table from start to finish. The
[Using ColdFront](docs/usage.md) guide covers both modes in depth, the
standalone partition manager and its CLI, the storage backends, and the
distributed setup; the [walkthrough demos](docs/walkthrough_demos.md) run each
mode on a sample table.

## Documentation

The following table lists the ColdFront guides and what each one covers:

| Doc | Contents |
|---|---|
| [Walkthrough](docs/walkthrough.md) | Sets up the demo stack and runs ColdFront hands-on. |
| [Walkthrough demos](docs/walkthrough_demos.md) | Walks through the tiered, decoupled, partitioner, and distributed demos. |
| [Embeddings](docs/usage_vectors.md) | Covers storing and searching embeddings with the pgvector interface. |
| [Usage](docs/usage.md) | Covers day-to-day use: both modes plus the standalone partition manager, one-time setup, reading and writing, supported types, the partition CLI, storage backends, distributed (mesh) setup, and tuning. |
| [Installation](docs/installation.md) | Covers building from source (Docker or bare-metal), and testing and CI. |
| [Object store setup](docs/object_store.md) | Gets ColdFront running on cloud S3 (virtual-hosted), end to end. |
| [Compaction](docs/compaction.md) | Covers cold-tier table maintenance: compaction, snapshot expiry, and orphan-file removal. |
| [Architecture](docs/architecture.md) | Describes the shared architecture and core mechanics. |
| [Architecture: tiered](docs/architecture_tiered.md) | Describes tiered mode (hot PG plus cold Iceberg) in depth. |
| [Architecture: decoupled](docs/architecture_decoupled.md) | Describes decoupled (iceberg-only) mode in depth. |
| [Architecture: vectors](docs/architecture_vectors.md) | Describes vector storage internals: type mapping, routing state, cluster assignment, and layout. |

## Least-Privilege Application Roles

Application roles need no superuser and no server-file access, yet they read
and write the cold tier through the same transparent view. Onboarding an
application role is a single call:

```sql
SELECT coldfront.grant_app_access('alice');
```

grant_app_access grants only the minimum the cold path needs: membership in
duckdb.postgres_role, SET on the duckdb.unsafe_allow_execution_inside_functions
parameter, schema USAGE, `SELECT` on the registry and the watermark table, DML
on the dual-write anchor table, DML on every registered view and the hot table
behind it, and USAGE and `SELECT` on the hot table's sequences. Those objects
are derived from the registry, not hardcoded, and the call also grants EXECUTE
on a fixed allow-list of runtime cold-path functions. The call is idempotent
and is not executable by PUBLIC, so an application role can never self-grant.
The role is never granted pg_read_server_files or pg_write_server_files, so it
has no host-file access. `CREATE ROLE` and `GRANT` both replicate over Spock,
so you onboard a role once on any node and it propagates across the mesh.

The Docker image sets `duckdb.postgres_role` to `coldfront_duckdb` and creates
that role when it initializes a new data directory. To name a different role,
set the container's `COLDFRONT_DUCKDB_ROLE` environment variable before that
first start. An empty value keeps pg_duckdb's default, under which only
superusers run DuckDB, so grant_app_access then fails with an error.

For how the non-superuser path works - the `SECURITY DEFINER` attach helpers,
the `PGC_SUSET` / `GUC_SUPERUSER_ONLY` config hardening, the
`duckdb.postgres_role` default that the image sets up, and how least privilege
holds across a Spock mesh - see
[Architecture: non-superuser app roles](docs/architecture.md#non-superuser-app-roles-least-privilege).

## Caveats

Iceberg on Azure ADLS Gen2 requires Blob soft-delete, container soft-delete,
and change feed (blob events) to be OFF on the storage account. Lakekeeper
warehouse creation otherwise fails with HTTP 409 ("This endpoint does not
support BlobStorageEvents or SoftDelete"). Disable those features on the
storage account before using it as a cold tier.

## Project Structure

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
│   ├── index.md · walkthrough.md · walkthrough_demos.md · installation.md
│   ├── object_store.md · usage.md · compaction.md
│   ├── architecture.md · architecture_tiered.md · architecture_decoupled.md
│   ├── architecture_vectors.md · usage_vectors.md · changelog.md
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

## Dependencies

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

## Versioning

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

## Support & Resources

For more information about pgEdge products, visit
[docs.pgedge.com](https://docs.pgedge.com).

To report an issue with the software, visit
[GitHub Issues](https://github.com/pgEdge/ColdFront/issues).

## Contributing

We welcome your project contributions; for more information, see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Author

Jimmy Angelakos created ColdFront.

## License

This project is licensed under the [PostgreSQL License](LICENSE.md). The
redistributed third-party components and their notices are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
