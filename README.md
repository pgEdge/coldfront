# pgEdge MultiTier

Tables in PostgreSQL, storage in Apache Iceberg (Parquet on S3-compatible
storage). Two operating modes, both queried as ordinary PG relations:

- **Tiered (hot + cold)** — recent data in native PG partitions, old data
  archived to Iceberg on a watermark; the application sees a unified view.
  The archiver moves rows hot → cold on a cron.
- **Decoupled (iceberg-only)** — the table lives entirely in Iceberg from
  row 1; PG holds a thin wrapper view and a registry row that arms the
  multitier hook to handle every DML on the view. No archiver, no PG
  storage for the data, no watermark. Scales out horizontally to N PG
  nodes pointing at one Lakekeeper + S3; the **bakery protocol** in
  the multitier extension serializes iceberg commits PG-side via
  Spock-replicated snowflake tickets so concurrent writers never
  collide at the catalog. Implementation is Lamport-1978 + Ricart–
  Agrawala over Spock's per-origin FIFO apply; safety properties are
  TLC-checked in [docs/formal/Bakery_v2.tla](docs/formal/Bakery_v2.tla).

Both modes coexist per-database, picked per-table at creation time. SQL
surface is identical for both: standard SELECT/INSERT/UPDATE/DELETE on
the named relation.

User-level setup and DML examples for both modes: **[USAGE.md](USAGE.md)**.

**See it in action:** [`demo/DEMO.txt`](demo/DEMO.txt) (plain-text transcript) or
`asciinema play demo/demo.cast` for the paced replay.  Walks through a plain
partitioned table, installing the extensions, running the archiver, and
using the tiered `events` table transparently for every DML verb.

## How It Works

```
Application
  │
  ├── SELECT * FROM events             ← reads hot + cold transparently
  ├── INSERT INTO events ...            ← multitier rewrites: hot via PG, cold via raw_query
  ├── UPDATE events SET ... WHERE ...   ← multitier rewrites to the right tier
  └── DELETE FROM events WHERE ...      ← multitier rewrites to the right tier
         │
┌────────▼──────────────────────────────────────────────────┐
│  PostgreSQL 17/18 + pg_duckdb + multitier extensions       │
│                                                            │
│  _events (renamed partitioned table, hot data)             │
│  ├── p_2026_04  (hot, native PG)                           │
│  ├── p_2026_05  (hot, native PG)                           │
│  └── ...                                                   │
│                                                            │
│  events  VIEW (replaces original table — hot + cold)       │
│  + INSTEAD OF INSERT trigger (fallback only — bypassed     │
│    when multitier is preloaded)                            │
│  + archive_watermark table (cutoff boundary)               │
│  + multitier.tiered_views catalog                          │
│                                                            │
│  multitier extension: rewrites INSERT / UPDATE / DELETE    │
│  on tiered views — hot side stays plain set-based PG,      │
│  cold side becomes one duckdb.raw_query (or a plpgsql      │
│  cursor loop when an IDENTITY column is omitted)           │
│                                                            │
│  pg_duckdb: intercepts iceberg_scan() queries,             │
│  handles Iceberg reads via DuckDB engine in-process        │
└────────┬──────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  Lakekeeper (Iceberg REST catalog, single Rust binary)     │
│  Backed by same PostgreSQL instance                        │
└────────┬──────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  S3-compatible object store (AWS S3, SeaweedFS, MinIO, etc.) │
│  Parquet data files + Iceberg metadata                     │
└───────────────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  Archiver (~9 MB static Go binary, no CGO, runs via cron)  │
│  Moves expired PG partitions → Iceberg, updates watermark  │
└───────────────────────────────────────────────────────────┘
```

## Quickstart

The walkthrough below covers **tiered mode**. For **decoupled (iceberg-only)** —
one SQL call provisions a wrapper view over a fresh Iceberg table and
arms the multitier hook to handle every DML on it; no archiver
involved — see [USAGE.md → Mode 2](USAGE.md#mode-2--decoupled-iceberg-only)
and [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md).

### 1. Convert your partitioned table

Point the archiver at your existing partitioned table and run it:

```yaml
# config.yaml
archiver:
  tables:
    - source_table: "events"       # your existing partitioned table
      partition_period: "monthly"
      retention_period: "3 months"
```

```bash
./bin/archiver --config config.yaml
```

The archiver automatically:
- Renames `events` → `_events`
- Creates a unified view named `events` (reads hot + cold transparently)
- Archives expired partitions to Iceberg
- Registers the view with multitier so the C hook handles every DML on it (an INSTEAD OF INSERT trigger is also installed as a defensive fallback)

Your application keeps using `events` — no code changes needed for reads.

### 2. Read data (hot + cold, transparent)

```sql
-- Same queries as before, transparently spans hot and cold:
SELECT * FROM events;
SELECT * FROM events WHERE ts > '2026-01-01';
SELECT count(*) FROM events WHERE status = 'error';
```

- **Hot-only queries**: PG partition pruning, never touches Iceberg
- **Cold-only queries**: DuckDB Iceberg pruning + Parquet row group skipping
- **Cross-tier queries**: seamless UNION ALL
- With `duckdb.force_execution = true`, hot queries also get DuckDB's
  vectorized engine (10-100x faster for analytics)
- **`jsonb` note**: returned as `json` (not `jsonb`) through the view,
  because DuckDB has no native `jsonb` type. Standard access (`->>`,
  `->`, `#>`) works without a cast; jsonb-only operators (`?`, `@>`,
  containment, de-dup) need an explicit `data::jsonb` in the caller's
  query.

### 3. Write data

All four verbs — INSERT, UPDATE, DELETE, SELECT — go through `events`.
No `_events`, no `duckdb.raw_query()` in application code.

| Operation | Syntax | Notes |
|---|---|---|
| **SELECT** | `SELECT FROM events` | pg_duckdb UNION ALL across hot + cold |
| **INSERT** | `INSERT INTO events (...)` | multitier hook splits hot/cold by `ts` vs the watermark; hot rows go set-based to `_events`, cold rows go through one bulk `duckdb.raw_query` (or a plpgsql cursor loop when an IDENTITY column is omitted) |
| **UPDATE** | `UPDATE events SET ... WHERE ...` | multitier rewrites based on the WHERE clause (see below) |
| **DELETE** | `DELETE FROM events WHERE ...` | multitier rewrites based on the WHERE clause (see below) |

```sql
-- Hot rows (ts >= watermark): plain PG UPDATE on _events
UPDATE events SET status = 'fixed' WHERE ts = '2026-04-01 12:00+00';

-- Cold rows (ts < watermark): hook rewrites to SELECT duckdb.raw_query(...)
UPDATE events SET status = 'fixed' WHERE ts = '2026-01-15 01:00+00';

-- IN / BETWEEN / OR all work if every value proves one tier
UPDATE events SET status = 'archived'
  WHERE ts BETWEEN '2026-01-01' AND '2026-02-01';

-- Ambiguous predicate (no ts constraint) — permissive mode writes to both
-- tiers in one statement via a dual-tier CTE:
UPDATE events SET status = 'fixed' WHERE id = 123;
```

#### Strict vs permissive modes

`multitier.allow_mixed_writes` (bool, default `on`) controls what happens
when the WHERE clause can't be proven to target a single tier:

- **Permissive (`on`, default)**: a dual-tier CTE writes to both sides in
  one statement.  `ROLLBACK` undoes both (pg_duckdb ties the DuckDB
  transaction to PG's via XactCallback).  Not crash-safe — a mid-commit
  crash can orphan S3 objects that Iceberg housekeeping later reclaims.
- **Strict (`off`)**: the extension raises an `ERROR` with a hint pointing
  at the partition column and asks the caller to narrow the WHERE clause.
  Recommended when you want every write attributable to exactly one tier.

```sql
SET multitier.allow_mixed_writes = off;
UPDATE events SET status = 'x' WHERE id = 123;
-- ERROR:  UPDATE/DELETE on tiered view "events" must include a
-- WHERE condition on "ts" that targets one tier
-- HINT:  Use "ts >= <value>" for hot-tier writes, "ts < <value>" for
-- cold-tier writes, or set multitier.allow_mixed_writes = on to permit
-- a non-atomic dual-tier rewrite.
```

See [ARCHITECTURE.md](ARCHITECTURE.md) — "Transparent UPDATE/DELETE" section — for
the full rewrite rules, the classifier's predicate coverage, and the
cosmetic regressions (command tag, cold RETURNING) in permissive mode.

#### Troubleshooting: direct access paths

If you hit an edge case the classifier doesn't cover, these paths stay
available:

```sql
-- Direct hot-side DML:
UPDATE _events SET status = 'fixed' WHERE id = 123;

-- Direct cold-side DML (requires an ATTACH; multitier.ensure_attached()
-- handles it when multitier.warehouse / .lakekeeper_endpoint GUCs are set):
SELECT duckdb.raw_query($$UPDATE ice.default.events
  SET status = 'fixed' WHERE id = 99$$);
```

## Archiver

Single static Go binary (~9 MB, CGO_ENABLED=0, no runtime, no daemon). Runs via cron.
Moves expired PG partitions to Iceberg:

1. Creates future partitions
2. Finds partitions older than the retention period
3. Exports each to Iceberg (PG → DuckDB temp table → Iceberg)
4. Updates the watermark
5. Renames source table and replaces with unified view (first run only)
6. Recreates view with new cutoff
7. Detaches and drops the archived partition

```bash
make build               # 9MB static binary
./bin/archiver --config config.yaml
```

### Table Swap

On the first run, the archiver atomically renames the source table
(e.g. `events` → `_events`) and creates a view with the original name.
The view combines hot data from `_events` with cold data via `iceberg_scan()`.
The multitier C hook intercepts every DML on the view and routes it to
the correct tier (an INSTEAD OF INSERT trigger is installed as a
defensive fallback for environments where the extension isn't preloaded).

### Watermark Strategy

The archiver maintains a cutoff timestamp in `multitier.archive_watermark`:
- Data with `ts >= cutoff` lives in PostgreSQL (hot)
- Data with `ts < cutoff` lives in Iceberg (cold)
- Cutoff is derived from the partition's mathematical upper bound
  (from `pg_catalog`), not from `MAX(ts)` — prevents boundary gaps

### Crash Recovery

The watermark is the single source of truth. If the archiver crashes:
- After Iceberg write, before watermark update → next run re-exports (safe)
- After watermark update, before view recreate → next run recreates view
- After view recreate, before partition drop → partition excluded by cutoff

## Configuration

```yaml
postgres:
  dsn: "host=localhost dbname=mydb user=myuser password=mypass sslmode=disable"

iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lakekeeper:8181/catalog"

s3:
  endpoint: "seaweedfs:8333"
  access_key: "admin"
  secret_key: "adminsecret"

archiver:
  tables:
    - source_table: "events"
      partition_period: "monthly"
      retention_period: "3 months"

    - source_table: "logs"
      partition_period: "daily"
      retention_period: "7 days"
```

Only `source_table`, `partition_period`, and `retention_period` are required per table.
`partition_column` is auto-detected from `pg_catalog`. `source_schema` defaults
to `public` (or use `"myschema.events"` syntax). `future_partitions` defaults to 3.

## Infrastructure

Three services: PostgreSQL + pg_duckdb, Lakekeeper, and any S3-compatible
object store (SeaweedFS, MinIO, AWS S3, GCS, etc.).

```bash
# Start the stack (example uses SeaweedFS)
docker compose -f docker-compose.test.yml up -d
```

### One-time setup

```bash
# 1. Bootstrap Lakekeeper
curl -X POST http://localhost:8181/management/v1/bootstrap \
  -H "Content-Type: application/json" -d '{"accept-terms-of-use":true}'

# 2. Create warehouse (adjust endpoint/credentials for your S3 store)
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

### Database setup

```sql
-- Install pg_duckdb extension
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
SELECT duckdb.install_extension('iceberg');

-- Persistent S3 secret (auto-loads every session, survives restarts)
SELECT duckdb.create_simple_secret(
  's3', 'admin', 'adminsecret',
  '', 'us-east-1', 'path', '', 'seaweedfs:8333', '', '', 'false'
);

-- Create your partitioned table
CREATE TABLE events (
    id     bigint GENERATED ALWAYS AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text,
    data   jsonb
) PARTITION BY RANGE (ts);

-- Create initial partitions (archiver will create future ones)
CREATE TABLE p_2026_04 PARTITION OF events
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
```

The archiver automatically creates:
- The `multitier` schema and `archive_watermark` table
- Future partitions
- The unified view (replaces the source table name) and registers it with the multitier hook (plus an INSTEAD OF INSERT trigger as a fallback for non-preloaded environments)

### Per-session setup

**None.** A LOGIN event trigger installed by the `multitier` extension
(`multitier._login_session_init`, PG17+) calls
`multitier.ensure_attached()` automatically at backend start, so both
cold reads (`iceberg_scan` through the unified view) and cold writes
(`duckdb.raw_query` against `ice.default.<table>`) Just Work on a fresh
psql session. No `ATTACH IF NOT EXISTS` needed in application code.

The trigger is gated on a single row in `multitier.runtime_config` so it
does nothing until the operator explicitly opts in — connections are
never blocked if Lakekeeper happens to be down or the warehouse isn't
provisioned yet. After bootstrapping the warehouse, arm the trigger
once per database:

```sql
SELECT multitier.arm_login_attach();
```

That helper is a plain `UPDATE` on `multitier.runtime_config` (no `ALTER
SYSTEM`, no superuser required — just UPDATE privilege on the table).
From that point, every new backend auto-attaches on login.
`multitier.disarm_login_attach()` is the symmetric toggle for ops /
debugging.

The login-time ATTACH also forces pg_duckdb's S3 secret to commit in a
DuckDB MetaTransaction before any user query runs — side-stepping a
latent MVCC-visibility issue in the duckdb-iceberg extension's
commit-time I/O. See
[ARCHITECTURE.md → Upstream Requests → duckdb-iceberg secret visibility](ARCHITECTURE.md#duckdb-iceberg-secret-visibility-under-fresh-transactions)
for the mechanism. Requires PostgreSQL 17+.

## Testing

Two test suites, both self-contained Docker stacks.

**Single-node** — `./run-ci-local.sh`. Default CI path. Brings up one `pgduckdb/pgduckdb:18-v1.1.1` Postgres plus Lakekeeper + SeaweedFS, seeds 280 rows across four monthly partitions, runs the archiver, and asserts hot/cold behavior through the unified view (hot/cold INSERT/UPDATE/DELETE, dual-tier permissive-mode CTE, ROLLBACK). Fast; runs on every commit.

**Distributed (3-node Spock)** — `./run-ci-distributed.sh`. Opt-in. Builds a one-off `multitier-spock:latest` image on `ghcr.io/pgedge/pgedge-postgres:17.9-spock5.0.7-standard` (Rocky 9 PG 17.9 with Spock 5.0.7 pre-installed) and source-builds pg_duckdb v1.1.1 + multitier against it; the builder stage is expensive (~20 min first time, seconds thereafter via Docker layer cache). Brings up 3 PG nodes in a full Spock mesh + shared Lakekeeper + SeaweedFS, mirrors the single-node assertions on db1, and adds:

- cross-node hot visibility (Spock replicates `_events` writes within seconds)
- cross-node cold visibility (all 3 nodes read the shared Iceberg catalog via `iceberg_scan`)
- Lakekeeper optimistic-concurrency characterization: parallel cold UPDATEs from db1 & db2 on disjoint rows of the same Iceberg table; records whether both landed, one aborted with an error, or one was silently dropped (the last is a known pg_duckdb v1.1.1 behavior — see `LK_CONCURRENCY_OUTCOME` in the run output)

The distributed suite does not modify `run-ci-local.sh` or any existing files — it only adds `docker/multitier-spock.Dockerfile`, `docker/multitier-spock-entrypoint.sh`, `docker-compose.distributed.yml`, and the script.

## Project Structure

```
pgedge-multitier/
├── cmd/archiver/
│   ├── main.go                 ← entry point (pure Go, pgx only)
│   └── main_test.go            ← retry, type mapping, interval tests
├── internal/
│   ├── config/                 ← YAML config loading + validation
│   ├── watermark/              ← archive_watermark table CRUD
│   ├── partition/              ← partition create/find/detach/drop
│   └── view/                   ← unified view + trigger generation
├── docker/
│   └── seaweedfs-s3.json       ← SeaweedFS S3 auth config (example)
├── docker-compose.test.yml     ← PG + Lakekeeper + SeaweedFS
├── docker-compose.distributed.yml ← 3 PG + Spock + Lakekeeper + SeaweedFS
├── run-ci-local.sh             ← gofmt, lint, test, build, e2e
├── run-ci-distributed.sh       ← opt-in 3-node Spock compat suite
├── config.example.yaml
├── Makefile
├── USAGE.md                    ← user-level usage guide (both modes)
├── ARCHITECTURE.md             ← tiered architecture
├── ARCHITECTURE_DECOUPLED.md   ← decoupled (iceberg-only) architecture
└── bench.md                    ← OLAP bench: hot heap vs Iceberg/DuckDB
```

## Dependencies

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 16, 17, or 18 | Database with native partitioning (stock upstream; no fork) |
| pg_duckdb | 1.1.1+ | Iceberg reads via DuckDB in-process |
| Lakekeeper | latest | Iceberg REST catalog (Rust binary) |
| S3-compatible store | any | AWS S3, SeaweedFS, MinIO, GCS, Azure Blob, etc. |
| Go | 1.24+ | Archiver binary (pure Go, no CGO) |
| pgx/v5 | 5.8.0 | PostgreSQL driver (only Go dependency) |

## License

PostgreSQL License. See [LICENSE](LICENSE).
