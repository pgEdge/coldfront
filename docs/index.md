# pgEdge ColdFront

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
  ([formal/Bakery_v2.tla](formal/Bakery_v2.tla)).

Both modes coexist per-database, picked per-table at creation time. SQL
surface is identical for both: standard SELECT/INSERT/UPDATE/DELETE on
the named relation.

User-level setup and DML examples for both modes:
**[USAGE.md](usage.md)**.

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

## Quickstart

Build the image and bring up the stack, then create a decoupled table
in psql:

```bash
# Build the image (see INSTALL.md), then bring up the stack (Postgres + Lakekeeper):
docker compose up -d --build
```

Bootstrap Lakekeeper and create a warehouse - see
[USAGE.md → One-time setup](usage.md#one-time-setup) - then, in psql:

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
**[USAGE.md](usage.md)**. For a real cloud-S3 cold tier end-to-end, see
**[S3_HOWTO.md](object_store.md)**.

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
the TLA+ model (`formal/`). Least privilege therefore holds for writes
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

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Installation](installation.md) guide covers building ColdFront
  and bringing up the stack.
- The [Using ColdFront](usage.md) guide covers both modes, the
  standalone partition manager, supported types, and tuning.
- The [Object Store Setup](object_store.md) guide takes you from an
  empty bucket to a working cold tier on cloud S3.
- The [Architecture](architecture.md) overview explains the shared
  mechanics and links to the per-mode deep dives.
