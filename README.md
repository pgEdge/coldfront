<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/img/pgedge-labs-dark.png">
    <img alt="pgEdge Labs" src="docs/img/pgedge-labs-light.png" width="320">
  </picture>
</div>

# pgEdge ColdFront

[![CI](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml/badge.svg)](https://github.com/pgEdge/ColdFront/actions/workflows/ci.yml)

Tables in PostgreSQL, cold data in Apache Iceberg (Parquet on
S3-compatible, Azure, or GCS storage), all **readable and writable
through the same SQL** with no application changes. Two operating modes,
both queried as ordinary PG relations:

- **Tiered (hot + cold)** - recent data in native PG partitions, old data
  archived to Iceberg on a watermark; the application sees a unified view.
  The archiver moves rows hot → cold on a cron.
- **Decoupled (iceberg-only)** - the table lives entirely in Iceberg from
  row 1; PG holds a thin wrapper view and a registry row that arms the
  coldfront hook to handle every DML on the view. No archiver, no
  watermark. Scales out horizontally to N PG nodes pointing at one
  Lakekeeper + S3; the **bakery protocol** in the coldfront extension
  serializes iceberg commits PG-side via Spock-replicated snowflake
  tickets so concurrent writers never collide at the catalog -
  Lamport / Ricart-Agrawala mutual exclusion, verified in TLA+
  ([docs/formal/Bakery_v2.tla](docs/formal/Bakery_v2.tla)).

Both modes coexist per-database, picked per-table at creation time. SQL
surface is identical for both: standard SELECT/INSERT/UPDATE/DELETE on
the named relation.

User-level setup and DML examples for both modes:
**[USAGE.md](docs/usage.md)**.

## How It Works

ColdFront runs inside PostgreSQL and rewrites each statement to the
correct tier, so the application sees one relation:

```text
Application
  │
  ├── SELECT * FROM events             ← reads hot + cold transparently
  ├── INSERT INTO events ...            ← coldfront rewrites: hot via PG, cold via raw_query
  ├── UPDATE events SET ... WHERE ...   ← coldfront rewrites to the right tier
  └── DELETE FROM events WHERE ...      ← coldfront rewrites to the right tier
         │
┌────────▼──────────────────────────────────────────────────┐
│  PostgreSQL 16/17/18 + pg_duckdb + coldfront extensions   │
│                                                           │
│  _events (renamed partitioned table, hot data)            │
│  ├── p_2026_04  (hot, native PG)                          │
│  ├── p_2026_05  (hot, native PG)                          │
│  └── ...                                                  │
│                                                           │
│  events  VIEW (replaces original table — hot + cold)      │
│  + INSTEAD OF INSERT trigger (fallback only — bypassed    │
│    when coldfront is preloaded)                           │
│  + archive_watermark table (cutoff boundary)              │
│  + coldfront.tiered_views catalog                         │
│                                                           │
│  coldfront extension: rewrites INSERT / UPDATE / DELETE   │
│  on tiered views — hot side stays plain set-based PG,     │
│  cold side becomes one duckdb.raw_query (or a plpgsql     │
│  cursor loop when an IDENTITY column is omitted)          │
│                                                           │
│  pg_duckdb: intercepts iceberg_scan() queries,            │
│  handles Iceberg reads via DuckDB engine in-process       │
└────────┬──────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  Lakekeeper (Iceberg REST catalog, single Rust binary)    │
│  Backed by same PostgreSQL instance                       │
└────────┬──────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  S3-compatible object store (SeaweedFS, MinIO, GCS, etc.) │
│  Parquet data files + Iceberg metadata                    │
└───────────────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  Archiver (~9 MB static Go binary, no CGO, runs via cron) │
│  Moves expired PG partitions → Iceberg, updates watermark │
└───────────────────────────────────────────────────────────┘
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

Build the image and bring up the stack, then create a decoupled table
in psql:

```bash
# Build the image (see INSTALL.md), then bring up the stack (Postgres + Lakekeeper):
docker compose up -d --build
```

Bootstrap Lakekeeper and create a warehouse - see
[USAGE.md → One-time setup](docs/usage.md#one-time-setup) - then, in psql:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');

-- Decoupled (iceberg-only) table — lives entirely in Iceberg on S3:
SELECT coldfront.create_iceberg_table('public', 'events',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},{"name":"note","type":"text"}]'::jsonb);
INSERT INTO events VALUES (1, now(), 'hello');
SELECT count(*) FROM events;        -- read back through Iceberg
```

Both modes in depth, the partition CLI, supported types, and mesh setup are in
**[USAGE.md](docs/usage.md)**. For a real cloud-S3 cold tier end-to-end, see
**[S3_HOWTO.md](docs/object_store.md)**.

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

## Security - non-superuser app roles

The setup snippets above run as a superuser for brevity, but ColdFront
supports a genuinely **least-privilege** model for enterprise use:
application roles need **no superuser and no server-file access**, yet read
and write the cold tier through the same transparent view. Onboarding is one
call.

```sql
-- As an operator/superuser, once per application role:
SELECT coldfront.grant_app_access('alice');
-- 'alice' (a plain NOSUPERUSER role) can now SELECT/INSERT/UPDATE/DELETE through
-- every registered tiered/decoupled view — hot and cold — exactly as before.
```

`grant_app_access` grants only the minimum the cold path needs - membership
in `duckdb.postgres_role`, `USAGE` on the relevant schemas, `SELECT` on the
registry, DML on every registered view (plus the hot heap and its identity
sequence behind a tiered view, which pg_duckdb's scan touches as the
invoker), and `EXECUTE` on the runtime cold-path functions - all **derived
from the registry**, never hardcoded. It is idempotent (re-run after
registering new tables) and is **not executable by `PUBLIC`** (an app role
can never self-grant). The app role is **not** granted
`pg_read_server_files` / `pg_write_server_files`, so it has no host-file
access.

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

- **Azure ADLS Gen2 cold tier requires Blob soft-delete and change feed to
  be OFF.** Iceberg on Azure is accessed over the ADLS Gen2 (`abfss://` /
  `dfs`) endpoint, which **rejects storage accounts that have Blob
  soft-delete, container soft-delete, or change feed (blob events)
  enabled** - Lakekeeper warehouse creation fails with HTTP 409 *"This
  endpoint does not support BlobStorageEvents or SoftDelete."* Disable those
  features on the storage account before using it as a cold tier. (Plain
  blob access via `az://` is unaffected - it is specifically the ADLS Gen2
  endpoint that Iceberg uses.)

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
