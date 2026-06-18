# pgEdge ColdFront

> [!WARNING]
> ColdFront is pre-release beta software under active development. Do
> not use it in production. Interfaces, on-disk formats, and behaviour
> may change without notice, and data loss is possible.

[![CI](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml/badge.svg)](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml)

ColdFront keeps tables in PostgreSQL and cold data in Apache Iceberg
(Parquet on S3-compatible, Azure, or GCS storage), and the cold tier is
both readable and writable through the same SQL with no application
changes. The application queries every table as an ordinary PostgreSQL
relation, and both operating modes present the same standard SQL
surface.

ColdFront provides two operating modes:

- Tiered mode keeps recent data in native PostgreSQL partitions and
  archives older data to Iceberg on a watermark; the application reads a
  single unified view, and the archiver moves rows from hot to cold on a
  schedule.
- Decoupled mode stores the table entirely in Iceberg from the first
  row; PostgreSQL holds a thin wrapper view and a registry row, and the
  coldfront extension handles every data-modifying statement on that
  view.

Both modes coexist within one database, and you choose the mode per
table at creation time. The SQL surface is identical for both modes:
standard SELECT, INSERT, UPDATE, and DELETE against the relation.

Decoupled mode scales out horizontally across many PostgreSQL nodes that
share one Lakekeeper catalog and one object store. The bakery protocol
in the coldfront extension serializes Iceberg commits on the PostgreSQL
side using Spock-replicated Snowflake tickets, so concurrent writers
never collide at the catalog. The protocol implements Lamport mutual
exclusion with the Ricart-Agrawala deferred-reply optimization, and the
[formal model](docs/formal/README.md) verifies its safety with TLA+.

## How It Works

ColdFront runs inside PostgreSQL and rewrites each statement to the
correct tier, so the application sees one relation:

```text
Application
  |
  |-- SELECT * FROM events            reads hot + cold transparently
  |-- INSERT INTO events ...          hot via PG, cold via raw_query
  |-- UPDATE events SET ... WHERE ... rewritten to the right tier
  |-- DELETE FROM events WHERE ...    rewritten to the right tier
         |
  PostgreSQL 16/17/18 + pg_duckdb + coldfront
    _events (partitioned hot data, native PG)
    events  VIEW (hot + cold, replaces the original table)
    coldfront extension (rewrites DML to the right tier)
    pg_duckdb (Iceberg reads + writes via DuckDB, in-process)
         |
  Lakekeeper (Iceberg REST catalog)
         |
  S3-compatible object store (Parquet data + Iceberg metadata)
         |
  Archiver (Go binary, cron) moves expired PG partitions to Iceberg
```

## Installation

ColdFront is open source under the PostgreSQL License and runs on stock
PostgreSQL 16, 17, and 18. The full build workflow lives in
**[INSTALL.md](docs/installation.md)**: build the DuckDB 1.5.x base and the
coldfront layer with one `docker build`, or install bare-metal. Then
continue with the Quickstart below.

**Setting up on cloud S3?** Once the image is built, the
**[S3 setup guide](docs/object_store.md)** takes you from an empty bucket to
a working cold tier end-to-end.

## Quickstart

Build the image (see the [Installation](docs/installation.md) guide) and
bring up the stack:

```bash
docker compose up -d --build
```

Bootstrap Lakekeeper and create a warehouse (see the one-time setup in
the [Using ColdFront](docs/usage.md) guide), then create a table in psql:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');

-- Decoupled (iceberg-only) table, stored entirely in Iceberg on S3:
SELECT coldfront.create_iceberg_table('public', 'events',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},{"name":"note","type":"text"}]'::jsonb);
INSERT INTO events VALUES (1, now(), 'hello');
SELECT count(*) FROM events;
```

## Documentation

The following table lists the ColdFront guides and what each one covers:

| Doc | Contents |
|---|---|
| **[USAGE.md](docs/usage.md)** | Day-to-day use - both modes plus the standalone partition manager, one-time setup, reading/writing, supported types, the partition CLI, storage backends, distributed (mesh) setup, tuning |
| **[INSTALL.md](docs/installation.md)** | Build from source (Docker or bare-metal); Testing & CI |
| **[S3_HOWTO.md](docs/object_store.md)** | Get ColdFront running on cloud S3 (virtual-hosted), end-to-end |
| **[COMPACTOR.md](docs/compaction.md)** | Cold-tier table maintenance - compaction, snapshot expiry, orphan-file removal |
| **[ARCHITECTURE.md](docs/architecture.md)** | Shared architecture and core mechanics |
| **[ARCHITECTURE_TIERED.md](docs/architecture_tiered.md)** | Tiered (hot PG + cold Iceberg) deep dive |
| **[ARCHITECTURE_DECOUPLED.md](docs/architecture_decoupled.md)** | Decoupled (iceberg-only) deep dive |

## Least-privilege application roles

Application roles need no superuser and no server-file access, yet they
read and write the cold tier through the same transparent view.
Onboarding an application role is a single call:

```sql
SELECT coldfront.grant_app_access('alice');
```

grant_app_access grants only the minimum the cold path needs, all
derived from the registry rather than hardcoded: membership in
duckdb.postgres_role, schema USAGE, SELECT on the registry, DML on every
registered view, and EXECUTE on the runtime cold-path functions. The
call is idempotent and is not executable by PUBLIC, so an application
role can never self-grant. The role is never granted
pg_read_server_files or pg_write_server_files, so it has no host-file
access. CREATE ROLE and GRANT both replicate over Spock, so you onboard
a role once on any node and it propagates across the mesh.

**How a non-superuser reaches Iceberg.** pg_duckdb force-disables DuckDB's
`LocalFileSystem` for non-superusers, which would block the side-loaded
iceberg/postgres DuckDB extensions from loading on `ATTACH`. ColdFront's
attach helpers `coldfront.ensure_attached()` / `ensure_pg_attached()` are
therefore `SECURITY DEFINER` (with a pinned `search_path`): the extension
load + `ATTACH` run elevated once per session, and because the DuckDB
instance is per-backend the attach persists, so every subsequent read
(`iceberg_scan`) and write (`_exec_iceberg_with_claim`) runs as the **app
role** over S3/httpfs - no `LocalFileSystem`, no elevation.

**Hardening.** Because the attach helpers run elevated, the
deployment-config GUCs they consume - `coldfront.warehouse`,
`coldfront.lakekeeper_endpoint`, `coldfront.local_pg_dsn` - are registered
`PGC_SUSET` (superuser-set-only), so a non-superuser cannot redirect the
elevated `ATTACH` at an attacker endpoint; `local_pg_dsn` is additionally
`GUC_SUPERUSER_ONLY` (it may carry credentials). Operators set these in
`postgresql.conf` as before.

**Turnkey.** The image defaults `duckdb.postgres_role = coldfront_duckdb`
and creates that NOLOGIN role at init, so the non-superuser path works out
of the box - `grant_app_access` is the only step. Set
`COLDFRONT_DUCKDB_ROLE=''` to keep pg_duckdb's stock superuser-only
behaviour. Superusers are unaffected either way.

**Spock mesh.** `CREATE ROLE` and `GRANT` both replicate via Spock DDL, so
create the role + run `grant_app_access` **once on any one node** - the role
and every grant propagate to the whole mesh. Don't repeat them per-node (a
repeated `CREATE ROLE` is a harmless local "already exists" error, just
unnecessary). Mesh cold *writes* route through the Ricart-Agrawala bakery,
whose coordination functions (`_claim_iceberg_lock` /
`_release_iceberg_lock`) are `SECURITY DEFINER` so a non-superuser drives the
cross-node serialization (reading `pg_stat_replication` liveness + dblinking
the claim) with the right privilege - verified **protocol-neutral** against
the TLA+ model (`docs/formal/`). Least privilege therefore holds for writes
in a mesh too, not just single-node.

The whole boundary is asserted end-to-end by the journey's
`story_app_privilege` (non-superuser tiered read+write; in a mesh,
cross-node read + a SECURITY DEFINER-bakery cold write from a peer), by
`ci/ops.sh` check 3 (the role cannot redirect the endpoint, cannot
self-grant, and an un-onboarded role is cleanly denied), and at the catalog
level by the `privilege_model` pg_regress test.

## Caveats

Iceberg on Azure ADLS Gen2 requires Blob soft-delete, container
soft-delete, and change feed (blob events) to be OFF on the storage
account. Lakekeeper warehouse creation otherwise fails with HTTP 409
("This endpoint does not support BlobStorageEvents or SoftDelete").
Disable those features on the storage account before using it as a cold
tier.

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
│   ├── view/                   ← unified view + trigger generation
│   └── watermark/              ← archive_watermark table CRUD
├── extension/coldfront/        ← PGXS C extension (DML hooks, bakery, registry, SQL)
├── ci/
│   ├── journey.sh              ← THE canonical user journey (the E2E spec)
│   ├── matrix.sh               ← drives PG×topology×mode×target cells (--quick / --full)
│   ├── ops.sh                  ← operational checks (privilege model, Lakekeeper-down, S3-down)
│   ├── probe-standby.sh        ← risk gate: iceberg_scan on a read-only hot standby
│   ├── lib.sh                  ← shared step/assert/psql helpers
│   ├── topo/                   ← vanilla.sh (1 node) · mesh.sh (3-node Spock)
│   └── runbooks/               ← failover-patroni.md (failover delegated to Patroni)
├── docker/
│   ├── Dockerfile.duckdb15-base ← DuckDB 1.5.x base (pg_duckdb 1.5.3 + patched iceberg)
│   ├── Dockerfile.duckdb15      ← thin coldfront app layer (ARG PG_MAJOR=16|17|18)
│   ├── iceberg-*.patch          ← duckdb-iceberg patches (bakery commit-refresh + strict-reader interop)
│   ├── entrypoint.sh
│   └── seaweedfs-s3.json        ← SeaweedFS S3 auth config (example)
├── docs/                       ← MkDocs site (user docs; mkdocs.yml at repo root)
│   ├── index.md · installation.md · object_store.md · usage.md · compaction.md
│   ├── architecture.md · architecture_tiered.md · architecture_decoupled.md
│   └── formal/                 ← TLA+ model of the bakery protocol (Bakery_v2.tla)
├── docker-compose.yml          ← END-USER single-node stack (ports published)
├── docker-compose.matrix.yml   ← CI only: single-node vanilla matrix
├── docker-compose.mesh.yml     ← CI only: 3-node Spock mesh
├── run-ci-local.sh             ← pre-commit gate (ci/matrix.sh --quick)
├── config.example.yaml · Makefile · mkdocs.yml
├── DUCKDB_1.5_PATCHED.md       ← the patched DuckDB 1.5 base: what's patched + how it's built
└── DUCKDB_1.5_UNPATCHED.md     ← building/running the base unpatched, and the consequences
```

## Dependencies

The following table lists the services and components ColdFront runs
against:

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 16, 17, or 18 | Database with native partitioning (stock upstream; no fork) |
| pg_duckdb | 1.5.3 (PR #1025) | Iceberg reads + writes via DuckDB in-process |
| duckdb-iceberg | `v1.5-variegata` @ `0fad545a`, patched | Iceberg catalog/IO for DuckDB; carries ColdFront's four patches (see [DUCKDB_1.5_PATCHED.md](DUCKDB_1.5_PATCHED.md)) |
| Lakekeeper | latest | Iceberg REST catalog (Rust binary) |
| S3-compatible store | any | SeaweedFS, MinIO, GCS, Azure Blob, etc. |

Building from source needs the Go toolchain (the version is pinned in
[go.mod](go.mod)). The Go module dependencies are the source of truth in
[go.mod](go.mod) / [go.sum](go.sum); the archiver and partitioner build
as static, CGO-free binaries on `pgx/v5`, and the compactor is a separate
module ([cmd/compactor/go.mod](cmd/compactor/go.mod)) built on
`apache/iceberg-go`.

## Author

Created by Jimmy Angelakos.

## License

PostgreSQL License. See [LICENSE.md](LICENSE.md). Redistributed third-party
components and their notices: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
