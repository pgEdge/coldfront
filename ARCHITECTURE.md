# pgEdge ColdFront — Architecture

ColdFront supports two operating modes that share the same extension, the
same docker stack, and the same SQL surface for applications. They differ
in where the data lives and what runs:

- **Tiered (this document)** — recent rows in PG heap (`_events`), older
  rows archived to Iceberg on a watermark, unified by a `UNION ALL` view.
  An archiver moves rows hot → cold on a cron.
- **Decoupled / iceberg-only** — the table lives entirely in Iceberg; PG
  holds only a wrapper view + INSTEAD OF trigger + a registry row. No
  archiver, no PG storage, no watermark. See
  [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md) for that mode's
  design, ACID model and distributed scaling story.

Both modes coexist per database, picked per relation at creation time,
distinguished by the `is_iceberg_only` flag on `coldfront.tiered_views`
and short-circuited in the C hook's `classify_tier()`. The rest of this
document describes the tiered path.

The transparent UPDATE/DELETE rewriter (`emit_cold` / `emit_hot` /
`emit_dual_cte` in `extension/coldfront/src/coldfront.c`) is the same
code in both modes — decoupled mode just always classifies as
`TIER_COLD` and never reaches `emit_hot`.

Live tiered data flows like this:

## System Overview

```
┌──────────────────────────────────────────────────────────┐
│  PostgreSQL 17/18 + pg_duckdb + coldfront extensions      │
│                                                           │
│  _events (renamed partitioned table, hot data)            │
│  ├── p_2026_03  (hot, native heap)                        │
│  ├── p_2026_04  (hot, native heap)                        │
│  └── ...                                                  │
│                                                           │
│  events VIEW (replaces original table — hot + cold)       │
│  + INSTEAD OF INSERT trigger (fallback when hook isn't    │
│                                loaded; bypassed otherwise)│
│  + archive_watermark table (cutoff boundary)              │
│  + coldfront.tiered_views (catalog of rewrite targets)    │
│                                                           │
│  coldfront extension: post_parse_analyze_hook             │
│  ├── INSERT: splits hot/cold by partition_col vs cutoff;  │
│  │     hot side is plain set-based PG INSERT into _events,│
│  │     cold side is one duckdb.raw_query (or plpgsql      │
│  │     cursor loop when an IDENTITY column is omitted)    │
│  ├── UPDATE/DELETE: classifies WHERE against the watermark│
│  │     and rewrites to target one tier or both            │
│  └── errors on ambiguous predicates in strict mode        │
│                                                           │
│  pg_duckdb: DuckDB runs in-process inside PostgreSQL      │
│  ├── view reads cold data via iceberg_scan()              │
│  └── Archiver + coldfront write via duckdb.raw_query()    │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│  Lakekeeper (Rust binary, REST catalog on :8181)          │
│  Backed by same PostgreSQL instance                       │
│  Manages Iceberg metadata, snapshots, concurrency         │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│  S3-compatible object store (AWS S3, SeaweedFS, MinIO, etc.)│
│  Stores Parquet data files + Iceberg metadata files       │
└──────────────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│  Archiver (Go binary, invoked by cron)                    │
│  Executes SQL against PG.                                 │
└──────────────────────────────────────────────────────────┘
```

| Component | Role | License |
|-----------|------|---------|
| PostgreSQL 17+ | Partitioning, PARTITION BY RANGE | PostgreSQL |
| pg_duckdb | DuckDB in-process. Iceberg read + write. Analytics. Stock upstream `pgduckdb/pgduckdb:18-v1.1.1`, no patches. | MIT |
| coldfront | PGXS C extension. `post_parse_analyze_hook` rewrites INSERT/UPDATE/DELETE on registered tiered views: INSERT splits hot/cold by partition_col vs the watermark and emits one set-based PG INSERT for the hot side plus one bulk `duckdb.raw_query` for the cold side; UPDATE/DELETE target one tier or both based on the WHERE clause. | PostgreSQL |
| Lakekeeper | Iceberg REST catalog. Single Rust binary. | Apache 2.0 |
| S3-compatible store | Any: AWS S3, SeaweedFS, MinIO, GCS, Azure Blob, etc. | Varies |
| Archiver | Go binary, invoked by cron. | PostgreSQL |

## Core Mechanics: pg_duckdb

All Iceberg I/O goes through SQL executed against PostgreSQL. No Go
DuckDB/Iceberg/Arrow libraries. DuckDB Iceberg writes require a REST
catalog — Lakekeeper fills this role.

### Session setup

**Persistent S3 secret** (created once per cluster, auto-loads every session
via pg_duckdb's `FOREIGN SERVER` + `USER MAPPING` machinery):

```sql
SELECT duckdb.create_simple_secret('s3', 'key', 'secret', '',
  'us-east-1', 'path', '', 'seaweedfs:8333', '', '', 'false');
```

**Iceberg catalog ATTACH** (session-scoped: each DuckDB cached connection
needs its own `ATTACH`). The operator runs this **once per database** after
the Lakekeeper warehouse is bootstrapped:

```sql
SELECT coldfront.arm_login_attach();
```

That helper flips one row in `coldfront.runtime_config` (a plain UPDATE,
grantable per-role; no superuser / `ALTER SYSTEM` / `ALTER DATABASE`
required). From that point, the `coldfront_login_session_init` LOGIN event
trigger fires on every new backend, calls `coldfront.ensure_attached()`,
and issues `ATTACH IF NOT EXISTS` against Lakekeeper using the cluster's
`coldfront.warehouse` and `coldfront.lakekeeper_endpoint` GUCs — both
reads (`iceberg_scan`) and writes (`duckdb.raw_query`) work on fresh psql
sessions with no boilerplate in application code. Gating on the flag
keeps pre-bootstrap connections from failing when Lakekeeper isn't up
yet. `coldfront.disarm_login_attach()` is the symmetric toggle for
debugging or maintenance windows.

### Temp table bridge: PG → Iceberg

`duckdb.raw_query()` cannot see PG tables directly. The bridge is a
DuckDB temp table:

```sql
CREATE TEMP TABLE duck_stage USING duckdb AS
  SELECT * FROM public.p_2026_01;
SELECT duckdb.raw_query($$INSERT INTO ice.default.events
  SELECT * FROM pg_temp.duck_stage$$);
DROP TABLE duck_stage;
```

### Cold-side column references

`iceberg_scan()` requires `r['col']::type` syntax:

```sql
SELECT r['id']::bigint, r['ts']::timestamptz, r['status']::text
FROM iceberg_scan('ice.default.events') r
WHERE r['ts'] < '2026-03-01'::timestamptz;
```

## Archiver Workflow

Single Go binary, runs via cron. Converts an existing partitioned table
into a tiered table on first run, then manages ongoing lifecycle.

### Prerequisites

1. PostgreSQL 17+ with pg_duckdb, Lakekeeper bootstrapped with a warehouse
2. Persistent S3 secret configured (see Session setup above)
3. An existing range-partitioned table

### First run: conversion

The archiver auto-detects the partition column from `pg_get_partkeydef()`
and column types from `information_schema.columns`.

For each expired partition (older than `retention_period`):

**1. Export to Iceberg** — using the temp table bridge (see above). On the
very first export, creates the Iceberg namespace and table. Catalog conflicts
from concurrent writes are retried with linear backoff (1s, 2s, 3s).

**2. Update watermark** — upserts `coldfront.archive_watermark` with the
partition's upper bound (derived from `pg_catalog`, not `MAX(ts)`).

**3. Table swap (first run only)** — atomically renames the source table
and creates the unified view:

```sql
ALTER TABLE events RENAME TO _events;

CREATE OR REPLACE VIEW events AS
  SELECT "id", "ts", "status", "data"::text FROM _events
  WHERE "ts" >= '2026-03-01'::timestamptz
  UNION ALL
  SELECT r['id']::bigint, r['ts']::timestamptz, r['status']::text, r['data']::text
  FROM iceberg_scan('ice.default.events') r
  WHERE r['ts'] < '2026-03-01'::timestamptz;
```

An INSTEAD OF INSERT trigger is also installed as a defensive fallback —
when coldfront is preloaded the C hook intercepts every INSERT on the
view before view-rewrite kicks in, so the trigger never fires; only when
the extension is *not* loaded (e.g. on a recovery instance or a node
without `shared_preload_libraries=coldfront`) does PG fall back to
running the trigger, which routes per-row to `_events` (hot) or
`duckdb.raw_query` (cold). The hook path is the production path.
On subsequent runs, the view and trigger are recreated with the updated cutoff.

**4. Detach and drop** — `ALTER TABLE _events DETACH PARTITION ... CONCURRENTLY`
then `DROP TABLE`.

The archiver also creates future partitions (default: 3) on every run, before
checking for expired partitions.

### Subsequent runs

1. Create future partitions
2. Export newly expired partitions to Iceberg
3. Update watermark and view cutoff
4. Detach and drop archived partitions

If no partitions are expired, it's a no-op.

### Crash recovery

The watermark is the single source of truth:

| Crash point | Recovery |
|---|---|
| After Iceberg write, before watermark update | Next run re-exports (idempotent) |
| After watermark update, before view recreate | Next run recreates view |
| After view recreate, before detach | Partition excluded by cutoff, next run detaches |
| After detach, before drop | Next run drops orphaned table |

## Application Interface

After conversion, applications use:

| Operation | Interface | Routed via |
|---|---|---|
| SELECT (all data) | `SELECT FROM events` | pg_duckdb UNION ALL |
| INSERT | `INSERT INTO events ...` | coldfront hook (see "Transparent INSERT" below) |
| UPDATE | `UPDATE events ... WHERE ...` | coldfront hook (see "Transparent UPDATE/DELETE" below) |
| DELETE | `DELETE FROM events WHERE ...` | coldfront hook (see "Transparent UPDATE/DELETE" below) |
| DDL (ALTER/RENAME) | `ALTER TABLE _events ADD COLUMN ...` | coldfront `ProcessUtility_hook` (see "Transparent DDL" below) |
| DROP / TRUNCATE | `DROP TABLE _events` | blocked by the hook (see "Transparent DDL" below) |

With `duckdb.force_execution = true`, hot-side queries are also accelerated
by DuckDB's vectorized columnar engine (10-100x faster for analytics).

### Transparent INSERT via coldfront

The same `post_parse_analyze_hook` intercepts INSERT on a registered
tiered view and rewrites it into a single statement that splits the
input by the partition-column watermark:

```sql
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM staging;

-- Rewritten by the hook to (schematically):
WITH hot_ins AS MATERIALIZED (
  INSERT INTO _events (ts, status, data)
  SELECT ts, status, data FROM (<source>) AS s(ts, status, data)
  WHERE ts >= '<cutoff>'::timestamptz
  RETURNING 1
),
cold_call AS MATERIALIZED (
  SELECT duckdb.raw_query(
    'INSERT INTO ice.default.events
     SELECT id, ts, status, data FROM (<source-pglocal-prefixed>) ...
     WHERE ts < ''<cutoff>'''
  )
)
SELECT (SELECT count(*) FROM hot_ins) AS hot_rows,
       (SELECT count(*) FROM cold_call) AS cold_rows;
```

| Cold side | When | Cost |
|---|---|---|
| **Bulk pglocal stream** (single `raw_query`, source streamed via libpq through DuckDB's postgres extension into the Iceberg writer in one pipeline) | Default. Used whenever the user's INSERT either (a) has no IDENTITY column on `_events`, or (b) supplies an explicit value for the IDENTITY column. DEFAULT clauses on omitted columns are inlined into the cold SELECT so DuckDB evaluates them per row. | Same as iceberg-only INSERT — one Iceberg snapshot for the whole cold subset, no per-row PG/DuckDB round-trip. |
| **plpgsql cold-loop** (`coldfront._tiered_insert_cold` — a PG cursor over the cold subset, calls `nextval()` on the IDENTITY sequence per row, accumulates VALUES, flushes one `raw_query` per 1000 rows) | Fallback. Only triggered when the table has an IDENTITY column AND the user's INSERT omits it — the only case that requires PG-side `nextval()` per row to keep cold ids coherent with hot. | Bounded by plpgsql per-row iteration speed (~10–50k rows/s). For very large mostly-cold seeds, prefer iceberg-only mode where ids come from the source data. |

The hot half is always plain set-based `INSERT INTO _events` — IDENTITY auto-allocates server-side, full PG speed regardless of row count.

INSERT-with-RETURNING is not preserved through the rewrite; the
rewritten statement reports `(hot_rows, cold_rows)` instead. Hot
RETURNING would need per-tier projection at runtime, which v0.1
doesn't implement.

### Transparent UPDATE/DELETE via coldfront

`coldfront` installs a `post_parse_analyze_hook` that inspects every
UPDATE/DELETE whose target is a registered tiered view.  It looks at the
WHERE clause and the archive watermark, classifies the predicate into one
of three tiers, and rewrites the Query accordingly:

| Predicate shape | Tier | Rewrite |
|---|---|---|
| WHERE proves all matching rows have `ts >= cutoff` (equality, `>=`, `>`, BETWEEN, IN, OR all in hot range) | HOT | `UPDATE _events SET ... WHERE ...` — plain PG DML, preserves RETURNING |
| WHERE proves all matching rows have `ts <  cutoff` | COLD | `SELECT duckdb.raw_query('UPDATE ice.default.events SET ... WHERE ...')` — DuckDB DML wrapped as a standard SQL literal (via `quote_literal_cstr`); the SELECT envelope keeps it off PG's command-ID counter so there's no mixed-write tripwire |
| WHERE cannot be proven to target one tier | AMBIGUOUS | depends on `coldfront.allow_mixed_writes` — see next section |

The classifier understands `Var <op> Const` (both operand orders), AND of
those, OR of those when all arms prove the same tier, BETWEEN (via its
desugaring to AND), and `ts IN (...)` (ScalarArrayOpExpr).  Subqueries,
UDF calls, and expressions on the partition column are AMBIGUOUS.

### The two modes: `coldfront.allow_mixed_writes`

When the predicate is AMBIGUOUS the hook picks one of two behaviours from
the `coldfront.allow_mixed_writes` GUC (USERSET, default `on`).

**Permissive (`on`, default).** The hook emits a dual-tier CTE:

```sql
WITH hot AS (UPDATE _events SET ... WHERE ... RETURNING *)
   , cold AS (SELECT duckdb.raw_query('UPDATE ice.default.events SET ... WHERE ...'))
SELECT h.* FROM hot h CROSS JOIN cold c;
```

The CROSS JOIN forces PG to execute the cold CTE (a pure-SELECT CTE that
isn't otherwise referenced would be pruned even with MATERIALIZED).  The
hook also sets `duckdb.unsafe_allow_mixed_transactions = on` LOCAL for the
current transaction to clear pg_duckdb's pre-commit mixed-write check.
pg_duckdb's `XactCallback` ties DuckDB's transaction to PG's, so
`ROLLBACK` undoes both tiers — but the path is **not crash-safe**: a
backend crash between the Iceberg upload and the PG commit can leave
orphaned object-storage files referenced by an uncommitted snapshot.
Iceberg housekeeping (orphan-file expiry) reclaims them.  Strict mode
avoids this path entirely.

**Strict (`off`).** The hook raises an error with a hint pointing at the
partition column and the accepted predicate shapes; nothing is written.
Use strict mode to guarantee every write is unambiguously attributable to
one tier, at the cost of requiring applications to supply a
tier-deterministic WHERE clause.

## Concurrency and pgEdge Spock Deployments

- The archiver runs on **one node only** (via cron). Catalog conflicts
  are auto-retried (up to 3 attempts).
- Hot writes are replicated by Spock normally (standard PG DML).
- Cold writes via `duckdb.raw_query()` from multiple nodes are
  serialised PG-side by the **bakery protocol** in the coldfront
  extension — every iceberg-only INSERT/UPDATE/DELETE wraps in
  `coldfront._exec_iceberg_with_claim`, which holds a globally-ordered
  snowflake ticket via the Spock-replicated `coldfront.claims` table
  and waits for its turn before issuing the iceberg commit. No 409s,
  no app-level retry. See
  [ARCHITECTURE_DECOUPLED.md → Concurrency](ARCHITECTURE_DECOUPLED.md#concurrency--horizontal-scaling--the-bakery-protocol)
  for the full design and benchmarks.

### Transparent DDL via coldfront

A `ProcessUtility_hook` in the coldfront extension intercepts DDL that
targets a registered tiered table's hot heap (matched by resolving the
DDL target relation to an OID and comparing against the OID of the
registry's `hot_table` — never by string, so it is schema-agnostic):

| DDL | Behaviour |
|---|---|
| `ALTER TABLE _t ADD COLUMN` | Mirror `ADD COLUMN` to the Iceberg table, rebuild the transparent view + INSERT trigger from the post-DDL catalog. |
| `ALTER TABLE _t DROP COLUMN` | Drop the dependent view first (PG forbids dropping a column a view depends on), run the DROP, mirror to Iceberg, rebuild the view. |
| `ALTER TABLE _t ALTER COLUMN ... TYPE` | Same pre-drop dance; mirror the new type to Iceberg (DuckDB enforces Iceberg's type-evolution rules). |
| `ALTER TABLE _t RENAME COLUMN` | Mirror the rename to Iceberg; if the partition column was renamed, update `tiered_views.partition_col`; rebuild the view. |
| `ALTER TABLE _t RENAME TO ...` | Update `tiered_views.hot_table`, rebuild the view. |
| `ALTER VIEW v RENAME TO ...` | Migrate the name-keyed `archive_watermark` row to the new view name, then rebuild (otherwise the cutoff lookup misses and the cold UNION branch silently disappears). |
| `DROP TABLE _t` / `DROP VIEW v` | **Blocked by design** — would orphan the Iceberg cold tier. Dismantling tiering is a deliberate operator action (unregister + drop each tier explicitly), never a one-shot call. |
| `TRUNCATE _t` | **Blocked by design** — cold-tier rows would remain visible through the view. The operator truncates each tier explicitly. |

The view rebuild always does `DROP VIEW` + `CREATE VIEW` (not
`CREATE OR REPLACE VIEW`, which PG only allows for appending columns at
the end), then re-points the registry's `view_oid` to the freshly-created
view. The Iceberg mirror only runs when `coldfront.warehouse` is set; with
it empty (single-node / tests) the PG-side view rebuild still happens.
Concurrent schema changes are serialised by the same bakery as cold DML.

**Active-active.** The hook is OID-and-registry-local by design:
`coldfront.tiered_views` is **not** Spock-replicated and OIDs differ per
node. Spock 5.0.8 replicates only the top-level `ALTER TABLE` (the
hook's SPI-issued view-rebuild DDL runs at non-top-level context, which
Spock's `autoddl_can_proceed()` filters out). A peer applies the
replicated `ALTER TABLE` with `IsLogicalWorker() == true`; the hook then
rebuilds **that peer's own** local view and re-points **that peer's own**
registry, but skips the Iceberg mirror (the originator already wrote the
shared Lakekeeper catalog). DROP/TRUNCATE are blocked on every node.

## Known Limitations

1. **Cold RETURNING** — the dual-tier rewrite's cold CTE does not support
   RETURNING, so `UPDATE events ... RETURNING *` on an ambiguous predicate
   shows only the hot rows.  v0.1.

2. **Command tag** — an ambiguous dual-tier UPDATE returns `SELECT n`
   rather than `UPDATE n`, because the rewrite produces a SELECT wrapper
   around a DML CTE.  The row count reflects hot rows only.  v0.1.

3. **Crash-safety of permissive writes** — DuckDB's transaction is tied to
   PG's via `XactCallback`, so `ROLLBACK` undoes both tiers.  If the
   backend *crashes* mid-commit, the Iceberg write may have produced S3
   objects referenced by a snapshot that was never committed; Iceberg
   housekeeping (orphan-file expiry) reclaims them.  Strict mode avoids
   this path entirely.

4. **One-time arming after warehouse bootstrap** — the LOGIN event trigger
   that auto-attaches Iceberg per session is gated on
   `coldfront.runtime_config.attach_on_login` (default `false`). An operator
   must call `SELECT coldfront.arm_login_attach()` once per database after
   Lakekeeper is provisioned. This is a deliberate opt-in so pre-bootstrap
   connections can't be blocked by a missing warehouse; once armed every
   subsequent session auto-attaches without boilerplate.

5. **`jsonb` surfaces as `json` through the view** — DuckDB has no
   native `jsonb`, and pg_duckdb takes over any query that references
   `iceberg_scan` (all-or-nothing plan takeover), so the cold branch
   can't produce a PG `jsonb` directly. The view generator casts
   `jsonb` columns to DuckDB-safe `json` on both sides: hot emits
   `"col"::json`, cold emits `r['col']::json`, the UNION unifies on
   `json`. Standard JSON access (`->>`, `->`, `#>`) works without any
   caller-side cast; jsonb-only operators (`?`, `@>`, containment,
   de-dup) need an explicit `data::jsonb` in the caller's query.
   Storage in Iceberg remains VARCHAR (Iceberg has no JSON type
   either). The INSTEAD OF trigger's cold path still casts the
   incoming value to `text` before sending it to `duckdb.raw_query`.

6. **Partitioned tables only** — the source table must already be partitioned
   by range. Unpartitioned table conversion is not yet supported.

7. **S3 compatibility** — Lakekeeper remote signing may not work with all
   S3-compatible stores. Workaround: `ACCESS_DELEGATION_MODE NONE` with
   direct DuckDB S3 secret.

8. **Planner-level interception, no per-query decision engine** —
   `pg_duckdb` decides whether to take over a query by inspecting the
   parse tree for signals (references to `iceberg_scan`, the
   `duckdb.force_execution` GUC, DuckDB-only functions).  Once it
   takes over, the whole statement runs in DuckDB; there is no
   cost-based hot-vs-cold split per predicate.  EDB PGAA's
   DirectScan / CompatScan pair adds a decision engine that picks
   full offload vs hybrid per query — more sophisticated, at the
   cost of the Arrow Flight round-trip per query.  The ColdFront
   position is that hot-only queries should target `_events`
   directly (native PG, no `pg_duckdb` roundtrip) and queries that
   need cross-tier semantics go through the view; users or
   application layers make the choice, not a planner heuristic.

9. **Single-node query execution** — a query runs on the PG backend
   it landed on.  `pg_duckdb` does not distribute the DuckDB plan
   across nodes.  Replication (single- or multi-master via pgEdge
   Spock) is supported on the hot tier and transparent to the
   application; scaling read throughput requires more replicas
   rather than parallelising one query.

10. **Iceberg only** — no Delta Lake support.  Adding Delta would
    require either a second writer path in `pg_duckdb`'s Iceberg
    extension or a different analytical engine.  Not on the v0.1
    roadmap.

11. **No Iceberg partition spec on the cold tier** — Iceberg tables
    are created without a `partition-spec` (`partition-specs[0].fields = []`).
    Cold-tier predicate pruning therefore relies on **per-file manifest
    min/max statistics**, which DuckDB-iceberg uses to skip data files
    whose range doesn't intersect a query's WHERE clause.

    This works correctly **as long as the archiver writes one Iceberg
    snapshot per source partition** — the existing flow does, because
    each `archivePartition` call performs a single bulk INSERT
    (one snapshot, tight `min(ts)/max(ts)` per file) followed by
    batched delta replay via `coldfront._apply_delta_batch` (each
    batch is one Iceberg snapshot streamed from a scratch table over
    pglocal, also tight).

    Anyone modifying [archivePartition](cmd/archiver/main.go) must
    preserve the one-snapshot-per-source-partition invariant. If a
    future change interleaves rows across snapshots (e.g. coalescing
    multiple PG partitions into one Iceberg INSERT), file-level min/max
    widens, files stop being prune-skippable, cold reads degrade toward
    full-scan.

    Setting a real partition spec via Lakekeeper REST is feasible
    (verified empirically), but DuckDB-iceberg v1.4.x then refuses every
    INSERT with `Not implemented Error: INSERT into a partitioned table
    is not supported yet`. So the spec stays empty until upstream ships
    partition-write — see Upstream Requests.

12. **Cutover blocked by autovacuum on freshly-loaded partitions** —
    Phase 4 of `archivePartition` takes `ACCESS EXCLUSIVE` on the
    partition under a 100 ms `lock_timeout` circuit breaker. PostgreSQL's
    autovacuum (`VACUUM ANALYZE`) holds `SHARE UPDATE EXCLUSIVE` on the
    partition for the duration of the vacuum, which conflicts with our
    request and is throttled by `autovacuum_vacuum_cost_delay` /
    `autovacuum_vacuum_cost_limit` to take *minutes per gigabyte* on
    default settings. On a freshly-loaded 30 GB partition the autovac
    run can run for an hour. The cutover's 10-attempt exponential
    backoff (~102 s total budget) cannot squeeze through; the archive
    cycle fails cleanly with `ERROR: canceling statement due to lock
    timeout` and leaves the trigger + delta in place for the next
    cycle to retry.

    This isn't a bug in the cutover — `lock_timeout` did its job:
    refusing to queue behind a multi-minute lock holder. But it does
    mean the **archive cycle should not race a recently-completed bulk
    load** of the partition being archived.

    Mitigations for operators:

    - **Disable autovacuum on the soon-to-be-archived partition** before
      running the archiver:
      `ALTER TABLE <part> SET (autovacuum_enabled = false);`. After the
      cycle the partition is detached and dropped; the setting goes with
      it. For predictable production scheduling, leave autovacuum on but
      time the archive cycle so partitions have already settled.
    - **Or wait for autovacuum to finish** before invoking the archiver.
      Check `pg_stat_activity` for active autovacuum workers on any
      managed partition; defer until clear.
    - **Tuning autovacuum to be faster** (`autovacuum_vacuum_cost_delay
      = 0`, `autovacuum_vacuum_cost_limit = 10000`) helps if the
      installation can absorb the I/O cost during normal operation.
    - **The archiver's failure mode is safe**: no partial cutover, no
      data loss, the next cycle picks up the same partition once locks
      clear.

## Partition Scheme Compatibility

The archiver supports single-column RANGE partitioning on a time-like
column.  Other shapes are rejected at archiver startup.

### Supported: single-column RANGE

```sql
CREATE TABLE events (id bigint GENERATED ALWAYS AS IDENTITY,
                     ts timestamptz NOT NULL, ...)
  PARTITION BY RANGE (ts);
CREATE TABLE p_2026_01 PARTITION OF events
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
```

The partition column, primary-key columns, and any `GENERATED ALWAYS
AS IDENTITY` columns are auto-detected from `pg_catalog` — no
assumptions about naming or arity.

### Not supported: composite partition keys

`PARTITION BY RANGE (tenant_id, ts)` and similar.  The archiver uses a
single scalar watermark per table; a composite key would need one
watermark per non-time dimension value.

### Not supported: multi-level (sub-partitioned) tables at the top level

```sql
CREATE TABLE events (...) PARTITION BY LIST (branch_id);
CREATE TABLE events_branch_1 PARTITION OF events
  FOR VALUES IN (1) PARTITION BY RANGE (ts);
```

A multi-level top table cannot be archived directly.  The workaround is
to tier each sub-partition independently:

```yaml
archiver:
  tables:
    - source_table: events_branch_1
      partition_period: monthly
      retention_period: "3 months"
    - source_table: events_branch_2
      partition_period: monthly
      retention_period: "3 months"
```

Each `events_branch_N` is a valid single-level range-partitioned table
and is tiered independently.  After conversion, each becomes a view;
applications query the branch views directly rather than the top-level
`events`.

### Performance note: partition pruning after the swap

Native PG partition pruning still works on `_events` (the renamed hot
table), but the query routes through pg_duckdb's takeover path:

1. PG rewriter expands the `events` view and pushes the user's
   predicate through the UNION ALL into both branches.
2. Because `iceberg_scan` is present, pg_duckdb intercepts and
   converts the whole query to DuckDB SQL.
3. DuckDB issues a `postgres_scan` on `_events` for the hot branch —
   which is itself a regular PG query, and PG applies partition
   pruning natively when planning it.
4. DuckDB's optimizer may prune the cold branch at plan time when the
   predicate is provably unsatisfiable (version-dependent).

Pruning works, but hot-only queries pay pg_duckdb's roundtrip
overhead. Users who know their query hits only hot data can query
`_events` directly — fully native PG, no pg_duckdb involvement,
identical performance to pre-tiering:

```sql
-- Transparent (hot + cold via pg_duckdb):
SELECT * FROM events WHERE ts = '2026-04-15';

-- Zero-overhead hot-only (native PG partition pruning only):
SELECT * FROM _events WHERE ts = '2026-04-15';
```

This is a read-path detail; writes are unaffected.

## Infrastructure (Docker)

Three services: PG+pg_duckdb+coldfront, Lakekeeper, and any
S3-compatible store.  Both extensions must be in
`shared_preload_libraries` — `coldfront` installs its hook in
`_PG_init`, which fires at backend start.

```yaml
services:
  db:
    # Base image is stock upstream pgduckdb/pgduckdb:18-v1.1.1, with
    # coldfront built on top (see docker/coldfront.Dockerfile).
    build:
      context: .
      dockerfile: docker/coldfront.Dockerfile
    command: -c shared_preload_libraries=pg_duckdb,coldfront
  lakekeeper:
    image: quay.io/lakekeeper/catalog:latest
    command: serve
  seaweedfs:
    image: chrislusf/seaweedfs:latest
    command: "server -s3 -dir=/data -s3.config=/etc/seaweedfs/s3.json"
```

Lakekeeper needs: bootstrap (`POST /management/v1/bootstrap`) then
warehouse creation (`POST /management/v1/warehouse`) with S3 credentials
and `sts-enabled: false`, `remote-signing-enabled: false`.

## Upstream Requests

Things we'd like upstream projects to expose so we can be even thinner.
Listed with the workaround we use today and the rough shape of the API
that would let us drop it.

### pg_duckdb: native PG-reader → Iceberg streaming (no libpq round-trip)

pg_duckdb already has a fully-native, in-process Postgres-table reader —
that's how it does analytics on PG heap data. When you `SELECT count(*)
FROM pg_table` and pg_duckdb takes over the plan, rows come straight from
PG's heap via the project's own access-method integration, fed as vectors
to DuckDB's executor. No libpq, no extra connection.

That same machinery is **not currently reachable** from the write path
into an attached Iceberg catalog. The four direct attempts:

| Form | Failure |
|---|---|
| `INSERT INTO ice.default.x SELECT * FROM pg_table` (plain SQL) | PG parser rejects `ice.default.x` as cross-database before pg_duckdb's planner hook sees it. |
| `INSERT INTO <wrapper-view> SELECT FROM pg_table` (planner-level) | pg_duckdb's planner doesn't take over the INSERT; only the SELECT side. ColdFront sidesteps this with a `post_parse_analyze_hook` that rewrites the INSERT into one `duckdb.raw_query` reading from `pglocal.<schema>.<table>` (option 2 below) — set-based, single Iceberg snapshot per statement. The pg_duckdb-native form would be more efficient but isn't reachable from raw_query. |
| `CREATE TABLE x (...) USING duckdb` against an Iceberg-attached catalog | Gated to MotherDuck/TEMP only: *"Only TEMP tables are supported in DuckDB if MotherDuck support is not enabled"* (`src/pgduckdb_ddl.cpp` on origin/main). |
| `SELECT * FROM duckdb.query('INSERT …')` | `duckdb.query` table function rejects non-SELECT input. |

**Working workarounds today**, both shipped in pg_duckdb v1.1.1 — neither
uses the native in-process reader:

1. **Staging-temp via `USING duckdb`** (the archiver's pattern in
   [`exportPartition`](cmd/archiver/main.go)): `CREATE TEMP TABLE
   duck_stage USING duckdb AS SELECT * FROM <pg_partition>; INSERT INTO
   ice.… SELECT * FROM duck_stage`. Materialises rows into DuckDB local
   storage first, then re-reads to write Iceberg. **Bounded by available
   local DuckDB temp-disk** — a ~5 TB load needs ~5 TB scratch. Suitable
   per-partition in tiered mode; not for arbitrary-size single inserts.

2. **DuckDB `postgres` extension + ATTACH** (verified on the running
   stack — both `ATTACH '<dsn>' AS pglocal (TYPE postgres)` and
   `postgres_scan('<dsn>', '<schema>', '<table>')` work fine in current
   pg_duckdb, despite earlier reports of a libpq-linkage clash that no
   longer reproduces). With this loaded:
   ```sql
   SELECT duckdb.raw_query($$
     INSERT INTO ice.default.events
     SELECT * FROM pglocal.public.source
   $$);
   ```
   Pipelines source rows over libpq (loopback TCP to the same PG
   instance) → DuckDB executor → Iceberg writer → S3, single pass, **no
   local materialisation**. ColdFront uses this for INSERT-into-
   iceberg-only views, the cold side of tiered INSERTs (when no
   IDENTITY column is omitted), and delta replay
   ([`coldfront._apply_delta_batch`](extension/coldfront/coldfront--0.1.sql)
   stages eligible delta rows into a scratch table that pglocal then
   reads, replacing the previous per-row `_apply_delta_row` flow).

The cost of (2) is the libpq round-trip per row batch. Sub-millisecond
on loopback, but real, and dwarfed by the Iceberg commit work for any
realistic batch — but still wasteful given pg_duckdb already has the
in-process reader.

**Requested API.** Either:

```sql
-- (a) function form: pg_duckdb takes over the whole INSERT,
--     reuses its native PG reader, no libpq
SELECT duckdb.copy_to_iceberg(
  $$SELECT * FROM public.events_partition$$,
  'ice.default.events'
);

-- (b) COPY form
COPY (SELECT * FROM public.events_partition)
  TO ICEBERG 'ice.default.events';
```

Either makes pg_duckdb the only place in the data path that touches
the rows: PG executor (heap reader) → pg_duckdb vector format → Iceberg
writer, **one pass, in-process**. No libpq loopback, no temp-disk.

**Status.** Not yet filed upstream. When we do file it, it goes here:
`https://github.com/duckdb/pg_duckdb/issues`. Until then the
`pglocal` ATTACH path covers the streaming case adequately for our
sizes; the in-process path would shave the libpq overhead off and is
the right end state.

### duckdb-iceberg: secret visibility under fresh transactions

**Workaround today.** A LOGIN event trigger
([coldfront.\_login\_session\_init](extension/coldfront/coldfront--0.1.sql))
runs `coldfront.ensure_attached()` once per session — gated on the
operator having armed the database via `coldfront.arm_login_attach()`.
The trigger's `ATTACH IF NOT EXISTS` is itself a DuckDB statement that
forces the session's first DuckDB transaction to commit, which is what
the bug actually needs (see Mechanism below). After it runs the rest of
the session sees secrets as expected.

**Symptom.** Without the warmup, a fresh PG backend's first cold-tier
write fails with HTTP 403 against any non-AWS S3-compatible endpoint
(SeaweedFS, MinIO, path-style GCS, on-prem S3). DuckDB's httpfs falls
through to AWS virtual-hosted-style defaults
(`<bucket>.s3.amazonaws.com`) because `SecretManager::LookupSecret` returns
empty.

**Mechanism (verified by reading
[duckdb-iceberg/src/storage/irc_transaction.cpp:317](https://github.com/duckdb/duckdb-iceberg/blob/ebe0dfaf/src/storage/irc_transaction.cpp#L317)
and the DuckDB v1.4.3 catalog\_set / secret\_manager source).**
`IRCTransaction::Commit` opens a fresh `Connection` and `BeginTransaction`
to do its commit-time I/O. That fresh transaction has its own
`transaction_id`/`start_time` and cannot see `SecretManager` `CatalogEntry`
items registered by the caller's still-active transaction —
[`CatalogSet::UseTimestamp`](https://github.com/duckdb/duckdb/blob/v1.4.3/src/catalog/catalog_set.cpp#L503)'s
visibility rules require either same-tx (`timestamp == transaction_id`)
or already-committed (`timestamp < start_time`). Neither holds for the
caller's still-uncommitted secret. After any prior DuckDB
`MetaTransaction::Commit` in the backend, the secret entry's timestamp
flips to a committed value (< `TRANSACTION_ID_START`) and every
subsequent fresh transaction satisfies the second rule. That's why "any
prior DuckDB statement first" is an observable fix — and why our LOGIN
trigger's `ATTACH IF NOT EXISTS` qualifies.

**Reproducer (no coldfront required).**

```sql
-- FRESH DuckDB process; warehouse pre-provisioned at minio:9000
CREATE SECRET s (TYPE s3, endpoint 'minio:9000', key_id 'admin',
                 secret 'password', url_style 'path', use_ssl false);
ATTACH 'wh' AS ice (TYPE ICEBERG, ENDPOINT 'http://lakekeeper:8181/catalog',
                    AUTHORIZATION_TYPE NONE, ACCESS_DELEGATION_MODE NONE);
INSERT INTO ice.default.t VALUES (...);
-- → commit-time HTTPException, HTTP GET 403 against <bucket>.s3.amazonaws.com

-- FRESH DuckDB process, with one prior committed transaction
SELECT 1;
CREATE SECRET s (TYPE s3, endpoint 'minio:9000', ...);
ATTACH 'wh' AS ice (TYPE ICEBERG, ENDPOINT 'http://...', ...);
INSERT INTO ice.default.t VALUES (...);
-- → commits cleanly via the secret's endpoint
```

**Requested fix.** Either of:

1. `IRCTransaction::Commit` should run commit-time I/O under the caller's
   `ClientContext` (passed through from `ICTransactionManager::CommitTransaction`),
   not a freshly-opened Connection. ~3 file change in duckdb-iceberg;
   removes the visibility miss entirely.
2. Defensively, register `pg_duckdb` (and any extension that synthesises
   `CREATE SECRET` from external state) so it commits the synthesising
   transaction explicitly, ensuring secrets are at committed timestamps
   before any consumer's fresh tx looks them up.

Either obviates the LOGIN-trigger warmup. Until then, the warmup costs
~1ms per session and is invisible to applications.

**Status.** Filing target: `https://github.com/duckdb/duckdb-iceberg/issues`
for option 1; the issue body needs only the Mechanism + Reproducer
quoted above. Not yet filed.

### duckdb-iceberg: INSERT into a table with a partition spec

**Workaround today.** None. Iceberg tables created by coldfront have an
empty partition spec; cold-tier pruning relies on per-file manifest
min/max stats. See Known Limitations §11.

**Why we want the API.** Setting `month(ts)` (or whatever transform
mirrors the hot-tier partition period) at the Iceberg level makes
predicate pruning structural rather than statistical. Files live under
`ts_month=2026-01/` directories; the reader skips entire directories
without consulting per-file stats. Robust against any future archiver
change that might break the one-snapshot-per-partition invariant.

**Why it doesn't work today.** Verified empirically against
`duckdb-iceberg` at commit `ebe0dfaf` (v1.4.3):

```
1. CREATE TABLE ice."default".x (id BIGINT, ts TIMESTAMPTZ) — succeeds, empty spec
2. POST /catalog/v1/{prefix}/namespaces/default/tables/x with body
   {requirements:[{type:"assert-table-uuid",uuid:...}],
    updates:[{action:"add-spec",spec:{...,fields:[{name:"ts_month",
              source-id:2,field-id:1000,transform:"month"}]}},
             {action:"set-default-spec",spec-id:1}]}
   — Lakekeeper accepts, GET confirms default-spec-id flips to 1
3. INSERT INTO ice."default".x VALUES (...) from a fresh session
   — ERROR: Not implemented Error: INSERT into a partitioned table
     is not supported yet
```

So setting the spec via the catalog is what *causes* the writer to
refuse. The writer code path checks for non-empty default spec and bails.

**Requested API.** INSERT/MERGE into a partitioned Iceberg table —
DuckDB writes data files into the appropriate partition directories
based on the catalog's current spec. No new SQL surface required;
existing `INSERT INTO ice.x VALUES ...` should just route the rows
through the partition transform.

**Status.** Not yet filed upstream. Goes to
`https://github.com/duckdb/duckdb-iceberg/issues`. Reproducer in
the verified-empirically block above is enough for the issue body.
Cutover when shipped: ~30 lines in [archivePartition](cmd/archiver/main.go)
to issue the `add-spec` + `set-default-spec` POST to Lakekeeper after
the `CREATE TABLE IF NOT EXISTS`.

