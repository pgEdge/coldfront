# ColdFront — Tiered operating mode

Tiered mode keeps recent rows in the PostgreSQL heap and archives older rows
to Apache Iceberg, presenting both as one table through a `UNION ALL` view.
An archiver moves rows hot→cold on a cron.

This document covers the **tiered-specific** design. The shared mechanics —
pg_duckdb Iceberg I/O, the rewrite hook, the bakery protocol, the registry,
DDL handling, infrastructure — live in [ARCHITECTURE.md](ARCHITECTURE.md);
the all-Iceberg alternative is
[ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md).

## Contents

- [Data flow](#data-flow)
- [Archiver Workflow](#archiver-workflow)
- [Transparent INSERT](#transparent-insert)
- [Transparent UPDATE/DELETE](#transparent-updatedelete)
- [Write modes: strict vs permissive](#write-modes-strict-vs-permissive-allow_mixed_writes)
- [Tiered tables in a Spock mesh](#tiered-tables-in-a-spock-mesh)
- [Partition Scheme Compatibility](#partition-scheme-compatibility)
- [Tiered-specific limitations](#tiered-specific-limitations)

## Data flow

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
│  S3-compatible object store (SeaweedFS, MinIO, GCS, etc.)   │
│  Stores Parquet data files + Iceberg metadata files       │
└──────────────────────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│  Archiver (Go binary, invoked by cron)                    │
│  Executes SQL against PG.                                 │
└──────────────────────────────────────────────────────────┘
```

## Archiver Workflow

Single Go binary, runs via cron. Converts an existing partitioned table
into a tiered table on first run, then manages ongoing lifecycle. The
archiver is a thin SQL orchestrator — no DuckDB/Iceberg/Arrow Go libraries;
all Iceberg I/O goes through `pg_duckdb` (see
[ARCHITECTURE.md → Core Mechanics](ARCHITECTURE.md#core-mechanics-pg_duckdb)).

### Prerequisites

1. PostgreSQL 17+ with pg_duckdb, Lakekeeper bootstrapped with a warehouse
2. Persistent S3 secret configured (see
   [ARCHITECTURE.md → Session setup](ARCHITECTURE.md#session-setup))
3. An existing range-partitioned table

### First run: conversion

The archiver auto-detects the partition column from `pg_get_partkeydef()`
and column types from `information_schema.columns`.

For each expired partition (older than `retention_period`):

**1. Export to Iceberg** — using the temp table bridge (see
[ARCHITECTURE.md → Temp table bridge](ARCHITECTURE.md#temp-table-bridge-pg--iceberg)).
On the very first export, creates the Iceberg namespace and table. Catalog
conflicts from concurrent writes are retried with linear backoff (1s, 2s, 3s).

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

## Transparent INSERT

The `post_parse_analyze_hook` (see
[ARCHITECTURE.md → Application Interface](ARCHITECTURE.md#application-interface))
intercepts INSERT on a registered tiered view and rewrites it into a single
statement that splits the input by the partition-column watermark:

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
RETURNING would need per-tier projection at runtime, which the rewrite
does not implement.

## Transparent UPDATE/DELETE

The hook inspects every UPDATE/DELETE whose target is a registered tiered
view.  It looks at the WHERE clause and the archive watermark, classifies
the predicate into one of three tiers, and rewrites the Query accordingly:

| Predicate shape | Tier | Rewrite |
|---|---|---|
| WHERE proves all matching rows have `ts >= cutoff` (equality, `>=`, `>`, BETWEEN, IN, OR all in hot range) | HOT | `UPDATE _events SET ... WHERE ...` — plain PG DML, preserves RETURNING |
| WHERE proves all matching rows have `ts <  cutoff` | COLD | `SELECT duckdb.raw_query('UPDATE ice.default.events SET ... WHERE ...')` — DuckDB DML wrapped as a standard SQL literal (via `quote_literal_cstr`); the SELECT envelope keeps it off PG's command-ID counter so there's no mixed-write tripwire |
| WHERE cannot be proven to target one tier | AMBIGUOUS | depends on `coldfront.allow_mixed_writes` — see next section |

The classifier understands `Var <op> Const` (both operand orders), AND of
those, OR of those when all arms prove the same tier, BETWEEN (via its
desugaring to AND), and `ts IN (...)` (ScalarArrayOpExpr).  Subqueries,
UDF calls, and expressions on the partition column are AMBIGUOUS.

## Write modes: strict vs permissive (`allow_mixed_writes`)

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

## Tiered tables in a Spock mesh

The bakery protocol that serialises cold writes cluster-wide is described in
[ARCHITECTURE.md → Concurrency](ARCHITECTURE.md#concurrency-and-pgedge-spock-deployments).
This section covers what is specific to a *tiered* table across a mesh.

A tiered table provisioned on one node becomes usable on every peer, but
the pieces arrive by different routes:

| Capability on a peer | How it gets there |
|---|---|
| **Read** (hot + cold, via the `UNION ALL` view) | The view is created by replicated DDL; hot rows arrive via normal Spock DML replication; cold rows are read from the **shared Lakekeeper catalog** that every node attaches. |
| **INSERT** through the view | The `INSTEAD OF INSERT` trigger is part of the replicated view definition, so it fires on the peer with no registry lookup. |
| **UPDATE / DELETE** and **DDL-blocking** | Need the `coldfront.tiered_views` row present on the peer — the hook resolves the target view through it. |
| **Hot/cold write routing** | Needs the `coldfront.archive_watermark` row (name-keyed) so the peer's write hook knows the cutoff. |

So alongside the bakery substrate (`coldfront.claims` /
`coldfront.claim_acks`), **both `coldfront.tiered_views` and
`coldfront.archive_watermark` are added to the Spock replication set** when a
mesh runs in tiered mode. This is verified necessary, not cosmetic: with
`tiered_views` absent from the replication set, peers still read and INSERT,
but the registry row is missing there and UPDATE/DELETE/DDL-blocking stop
recognising the view (the archiver runs on one node, so a peer never registers
the view itself — it only gets the row by replication).

Both tables are **name-keyed** — `tiered_views` by `(schema_name, relname)`,
`archive_watermark` by `table_name` — so the replication set copies each row
**verbatim and correct on every node**: a name is node-independent, unlike an
OID. There is no per-node re-resolution and no OID divergence to reason about;
the row a peer receives is exactly the row its hook needs. See
[ARCHITECTURE.md → Registry keying](ARCHITECTURE.md#registry-keying-by-name-not-oid).

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

## Tiered-specific limitations

These are specific to the dual-tier model. Cross-cutting limitations (the
planner-level takeover, jsonb-as-json, single-node execution, S3
compatibility, login arming) are in
[ARCHITECTURE.md → Known Limitations](ARCHITECTURE.md#known-limitations).

1. **Cold RETURNING** — any write that touches the cold tier (a cold-only
   UPDATE/DELETE, a permissive dual-tier UPDATE/DELETE, or a watermark-split
   INSERT) **rejects `RETURNING` with a clear error** rather than returning a
   partial result.  The cold tier genuinely cannot return affected rows:
   duckdb-iceberg's binder refuses `RETURNING` on Iceberg writes (*"not yet
   supported for updates of a Iceberg table"*) and pg_duckdb's row-returning
   entry point is SELECT-only.  Hot-only DML keeps `RETURNING` (it is plain PG
   DML).  Revisit when duckdb-iceberg adds write-`RETURNING` upstream.

2. **Command tag** — an ambiguous dual-tier UPDATE returns `SELECT n`
   rather than `UPDATE n`, because the rewrite produces a SELECT wrapper
   around a DML CTE.  The row count reflects hot rows only.

3. **Self-join / multiple references** — an UPDATE/DELETE that references
   the same tiered view more than once — a self-join (`UPDATE events ... FROM
   events e2`), `DELETE ... USING events`, or a sub-select (`... WHERE id IN
   (SELECT ... FROM events)`) — is rejected with a clear error.  The rewrite
   swaps only the leading result-relation reference, so a second one cannot be
   retargeted; reference the view once.

4. **Crash-safety of permissive writes** — DuckDB's transaction is tied to
   PG's via `XactCallback`, so `ROLLBACK` undoes both tiers.  If the
   backend *crashes* mid-commit, the Iceberg write may have produced S3
   objects referenced by a snapshot that was never committed; Iceberg
   housekeeping (orphan-file expiry) reclaims them.  Strict mode avoids
   this path entirely.

5. **Partitioned tables only** — the source table must already be partitioned
   by range. Unpartitioned table conversion is not yet supported.

6. **No Iceberg partition spec on the cold tier** — Iceberg tables
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
   partition-write — see
   [ARCHITECTURE.md → Upstream Requests](ARCHITECTURE.md#upstream-requests).

6. **Cutover blocked by autovacuum on freshly-loaded partitions** —
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
