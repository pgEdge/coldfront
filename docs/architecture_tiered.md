# ColdFront - Tiered Operating Mode

Tiered mode keeps recent rows in the PostgreSQL heap and archives older rows to
Apache Iceberg, presenting both as one table through a `UNION ALL` view. An
archiver moves rows hot→cold on a cron.

This document covers the **tiered-specific** design. The shared mechanics -
pg_duckdb Iceberg I/O, the rewrite hook, the bakery protocol, the registry, DDL
handling, infrastructure - live in [architecture.md](architecture.md); the
all-Iceberg alternative is
[architecture_decoupled.md](architecture_decoupled.md).

## Data Flow

The following diagram shows how data moves between PostgreSQL, the Iceberg
catalog, the object store, and the archiver:

```text
┌──────────────────────────────────────────────────────────┐
│  PostgreSQL 16/17/18 + pg_duckdb + coldfront extensions   │
│                                                           │
│  _events (renamed partitioned table, hot data)            │
│  ├── p_2026_03  (hot, native heap)                        │
│  ├── p_2026_04  (hot, native heap)                        │
│  └── ...                                                  │
│                                                           │
│  events VIEW (replaces original table - hot + cold)       │
│  + archive_watermark table (cutoff boundary)              │
│  + coldfront.tiered_views (catalog of rewrite targets)    │
│                                                           │
│  coldfront extension: post_parse_analyze_hook             │
│  ├── INSERT: splits hot/cold by partition_col vs cutoff;  │
│  │     hot side is plain set-based PG INSERT into _events,│
│  │     cold side is the cold sink, batched DuckDB INSERTs │
│  │     under one claim (the _cold_sink aggregate)         │
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
│  Backed by its own dedicated PostgreSQL instance          │
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

A single Go binary runs via cron. The binary converts an existing partitioned
table into a tiered table on first run, then manages the ongoing lifecycle. The
archiver is a thin SQL orchestrator - no DuckDB/Iceberg/Arrow Go libraries; all
Iceberg I/O goes through `pg_duckdb` (see
[architecture.md → Core Mechanics](architecture.md#core-mechanics-pg_duckdb)).

### Prerequisites

The archiver requires the following before its first run:

- PostgreSQL 16+ with pg_duckdb.
- Lakekeeper, bootstrapped with a warehouse.
- a configured storage secret (see
  [architecture.md → Session Setup](architecture.md#session-setup)).
- static `s3:` or `azure:` credentials in the archiver config, unless the cold
  store uses vended credentials.
- an existing range-partitioned table.

### First Run: Conversion

The archiver auto-detects the partition column from `pg_get_partkeydef()` and
column types from `pg_attribute` via `format_type()`.

A run that finds partitions past the hot window (older than `hot_period`)
starts with an idempotent bootstrap, executed once before the per-partition
loop: rename the source table, recreate the unified view, and register the view
in `coldfront.tiered_views`. Until the first cutover sets a watermark, the view
reads the hot table alone; after it, the view is a UNION with the watermark as
its cutoff, and both branches cast every column to its view type (`jsonb` to
`json`):

```sql
ALTER TABLE events RENAME TO _events;

CREATE OR REPLACE VIEW events AS
  SELECT "id"::bigint, "ts"::timestamptz, "status"::text, "data"::json FROM _events
  WHERE "ts" >= '2026-03-01'::timestamptz
  UNION ALL
  SELECT r['id']::bigint, r['ts']::timestamptz, r['status']::text, r['data']::json
  FROM iceberg_scan('ice.public.events') r
  WHERE r['ts'] < '2026-03-01'::timestamptz;
```

The rename is conditional, so it converts the table on the first run and no-ops
afterwards; the `CREATE OR REPLACE VIEW` keeps the view's OID across runs. The
C hook rewrites an INSERT on the view by the watermark cutoff, into a hot
INSERT of the at/after-cutoff rows into `_events` and the cold sink for the
older rows, and the utility hook feeds a `COPY FROM` into the same rewrite in
batches. An `INSERT` nested in a `WITH` entry is rewritten in place. The view
has no INSTEAD OF trigger, so a write the hook does not handle, such as
`MERGE`, fails in PostgreSQL.

### The Archive Pipeline

Candidates are tiered oldest first, ordered by partition **bound**. The order
is a correctness contract: each cutover advances the watermark to its
partition's upper bound, so chronological order is what guarantees every
partition is exported while the watermark still sits below its range. A
partition's place in time is its range; the name is a label the user chose and
is free to sort against the calendar.

A partition already below the watermark when the cycle begins was tiered by an
earlier cycle, leaving only its stale PostgreSQL partition to remove. That drop
requires the partition to be **empty**. Phase 4 detaches atomically with the
watermark advance, so a partition the pipeline archived is never a candidate
again, and rows found in one here are in neither tier: an out-of-band write to
the heap, or a mesh peer writing hot against a stale cutoff. Those rows are the
only copy, so the archiver refuses the drop and exits non-zero, skipping the
remaining tables.

Each remaining partition past the hot window then moves to Iceberg through a
six-phase pipeline:

0. The idempotent Iceberg-range wipe deletes any Iceberg rows already in the
   partition's range (a previous cycle may have exported without cutting over),
   so the re-export cannot duplicate rows.

1. Capture installation (`install_archive_capture`) adds a capture trigger and
   an UNLOGGED delta table to the partition, so writes that land during the
   export are recorded for replay.

2. The bulk export copies the partition PG → Iceberg under a captured snapshot,
   using the temp table bridge (see
   [architecture.md → Temp Table Bridge](architecture.md#temp-table-bridge-pg-iceberg))
   and a single bakery-claimed Iceberg INSERT. Each cycle has already created
   the Iceberg namespace and table, if missing, before the per-partition loop.

3. Delta replay (`replay_archive_delta`) applies the delta rows the export
   snapshot did not see to Iceberg in batched commits, with no lock on the
   partition - concurrent writers keep going and keep adding to the delta.

4. The atomic cutover (`cutover_archive`) is a single transaction that updates
   `coldfront.archive_watermark` to the partition's upper bound (derived from
   `pg_catalog`, not `MAX(ts)`), takes the bakery claim on the Iceberg table,
   takes `ACCESS EXCLUSIVE` on the parent and the partition under a 100 ms
   `lock_timeout`, re-issues the view DDL with the new cutoff, and detaches the
   partition with a plain transactional `DETACH PARTITION` - all of it commits
   atomically or rolls back whole. On a lock timeout, phases 3-4 are retried
   (10 attempts, exponential backoff from 100 ms to 51.2 s); any other error
   fails the cycle immediately.

5. Cleanup (`cutover_cleanup`) drains stragglers that landed between phase 3's
   last commit and phase 4's lock, then drops the detached partition, the
   capture trigger, and the delta table.

### Subsequent Runs

Every run executes the same cycle - the conversion above is the first cycle's
bootstrap actually renaming the table. Each run performs the following steps in
order:

1. Create future partitions (default: 3) and self-heal the partition covering
   now.
2. Run the bootstrap, then the six-phase pipeline for each partition past the
   hot window.
3. Delete cold rows older than `retention_period` (when configured).

A run with nothing past the hot window and no `retention_period` set only
creates future partitions and self-heals the current one.

Premake provisions a **range**, not a name. Each period premake provisions is
first checked against the parent's existing partition bounds, so a period
another partition already covers is left alone whatever that partition is
called - the generated `events_p_YYYY_MM` names are ColdFront's own convention,
not a requirement on tables you bring yourself. A partition covering only part
of a period is reported as such, naming both ranges, since PostgreSQL cannot
create the partition that completes it.

### Crash Recovery

The watermark is the single source of truth, and phase 4 is the only step that
changes it - the watermark, view, and DETACH commit together or not at all, so
no intermediate state between them can exist. The following table shows how the
archiver recovers from a crash at each point in the pipeline:

| Crash point | Recovery |
|---|---|
| During phases 0-3 (wipe, capture, export, replay) | The watermark is unchanged and the partition is still attached. The next cycle re-runs the pipeline, and because the phase-0 range wipe and the delta replay are idempotent, no duplicates result. |
| During phase 4 (cutover) | The transaction rolls back whole: the watermark and view are unchanged, and the partition is still attached. Lock timeouts are retried in the same run; any other error leaves the trigger and delta table for the next cycle to retry. |
| Between phase 4 and phase 5 | The cutover is already committed (the watermark, view, and DETACH are all in place). The detached partition, its capture trigger, and the delta table are left behind, and the delta can still hold rows that landed after phase 3's last commit. Run `CALL coldfront.cutover_cleanup(schema, partition, NULL, iceberg_ref)` to replay the delta into Iceberg and drop the leftovers; dropping them by hand loses those rows. |

## Two-Level (LIST → RANGE) Tiering

A `LIST (key) → RANGE (ts)` table is tiered as **one** relation. The LIST key
is an ordinary column in the cold tier, so every LIST value's rows land in a
single Iceberg table, under a single watermark and a single `UNION ALL` view.
The `LIST` level partitions PostgreSQL storage; it does not partition the cold
tier.

Provisioning is driven by the sub-partition block's `values_source` query,
re-run each cycle: every value it returns gets a LIST child and a RANGE
sub-tree beneath it, so a newly appearing value is provisioned automatically on
the next pass.

### Period-Major Ordering

Because the watermark is shared, the cycle is **period-major across LIST
values**, not value-major. Past-hot leaves are grouped by their `ts` period,
the groups run oldest first, and within a group two passes run strictly in
sequence:

1. Export every LIST value's leaf for that period. This pass detaches nothing
   and leaves the watermark unchanged.
2. Cut them all over. The first cutover advances the watermark to the period's
   upper bound; the rest re-set it to the same value and detach their
   now-excluded leaf.

Both the group order and the split into two passes are correctness
requirements. The watermark advance makes a period cold for the **whole table**
at once, and the view reads a below-cutoff row only from the cold tier, so
every LIST value's rows for a period must already be in Iceberg before the
cutoff crosses that period. Exporting the entire group first is what
establishes that, and running the groups oldest first keeps the cutoff moving
in one direction.

### Scoped Range Wipe

Phase 0 deletes existing Iceberg rows in the range about to be exported. The
cold tier is shared, so that delete is scoped by the LIST column and value: it
reaches only the rows of the leaf being exported, leaving its siblings'
already-cold rows in the same `ts` range untouched.

Scoping also makes re-export idempotent, so this path exports every past-hot
leaf it finds without consulting the watermark. A leaf interrupted between the
two passes is exported again on the next cycle. The stale-partition branch
described under [The Archive Pipeline](#the-archive-pipeline) is specific to
the flat path.

`id` mode is not available here: the cold tier is keyed by time.

## Transparent INSERT

The `post_parse_analyze_hook` (see
[architecture.md → Application Interface](architecture.md#application-interface))
intercepts INSERT on a registered tiered view and rewrites it into a single
statement that splits the input by the partition-column watermark:

```sql
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM staging;

-- Rewritten by the hook to (schematically):
WITH coldfront_source AS MATERIALIZED (
  SELECT ts::timestamptz AS ts, status::text AS status, data::jsonb AS data
  FROM (<source>) AS s(ts, status, data)
),
coldfront_hot AS MATERIALIZED (
  INSERT INTO _events (ts, status, data)
  SELECT ts, status, data FROM coldfront_source
  WHERE ts >= '<cutoff>'::timestamptz
  RETURNING 1
),
coldfront_cold AS MATERIALIZED (
  SELECT coldfront._cold_sink('public', 'events', to_jsonb(r)) AS n
  FROM (SELECT nextval('_events_id_seq') AS id, ts, status, data
        FROM coldfront_source WHERE ts < '<cutoff>'::timestamptz) AS r
)
SELECT (SELECT count(*) FROM coldfront_hot) AS hot_rows,
       (SELECT n FROM coldfront_cold) AS cold_rows;
```

The source runs once, into the `coldfront_source` tuplestore, and both halves
read it, so a volatile source lands every row exactly once and a row the
transaction wrote before the `INSERT` reaches the cold tier. Each column of
`coldfront_source` is cast to the hot table's type, which restates the
coercions PostgreSQL applied when it analyzed the statement (an untyped literal
against a `jsonb` column keeps that type), and `OVERRIDING SYSTEM VALUE` stays
on the hot `INSERT`.

The hot half is plain set-based `INSERT INTO _events`: IDENTITY and DEFAULT
columns fill server-side at full PG speed. The cold half projects each row to
the hot table's full column list, with `nextval()` on the hot table's sequence
for an omitted IDENTITY column and the DEFAULT expression for an omitted column
that has one, both evaluated by PostgreSQL per row, and hands it to
`coldfront._cold_sink`. That aggregate renders each row as a DuckDB `VALUES`
tuple and flushes every `coldfront.cold_write_batch_size` rows (default 10000)
as one `INSERT` under the table's claim, taken once per table per transaction;
its final step flushes the rest. Throughput is bounded by the per-row rendering
in plpgsql, so for very large mostly-cold seeds, prefer iceberg-only mode where
ids come from the source data.

A `WITH` clause on the `INSERT` keeps its entries at the top of the rewritten
statement, ahead of the three above, so an entry that modifies data (`WITH
moved AS (DELETE FROM staging RETURNING …) INSERT INTO events SELECT … FROM
moved`) stays where PostgreSQL allows one. An `INSERT` nested in a `WITH`
entry (`WITH i AS (INSERT INTO events …) SELECT …`) is rewritten in place: the
hot `INSERT` becomes the entry's body, and `coldfront_source` and
`coldfront_cold`, the latter as a data-modifying entry so that it always runs,
are lifted into the statement's `WITH` list just before it. With a watermark a
row may go cold, so `RETURNING` on such an entry is refused as on a top-level
`INSERT`; without one every row is hot and `RETURNING` works. A statement may
write a tiered view once, and a nested `UPDATE` or `DELETE` is not rewritten,
so PostgreSQL refuses it.

`COPY <view> FROM` takes the same path. The utility hook reads the rows with
PostgreSQL's COPY reader (`BeginCopyFrom`, `NextCopyFrom`), collects
`cold_write_batch_size` of them, and runs one
`INSERT INTO <view> (<COPY's columns>) OVERRIDING SYSTEM VALUE VALUES (…), (…)`
per batch, every value a literal in its type's text form, so the statement is
the one an application would write and the same rewrite handles it, for a
decoupled view too. `OVERRIDING SYSTEM VALUE` gives the INSERT the rule `COPY`
has for a `GENERATED ALWAYS` identity column: a supplied value is kept. `WHERE`
and the options that act after a row is read (`FREEZE`, `ON_ERROR`,
`REJECT_LIMIT`, `DEFAULT`) are refused.

A watermark-split INSERT cannot use `RETURNING` - see Cold RETURNING under
[Tiered-Specific Limitations](#tiered-specific-limitations).

## Transparent UPDATE/DELETE

The hook inspects every UPDATE/DELETE whose target is a registered tiered view.
The hook looks at the WHERE clause and the archive watermark, classifies the
predicate into one of three tiers, and rewrites the Query accordingly. The
following table maps each predicate shape to its tier and rewrite:

| Predicate shape | Tier | Rewrite |
|---|---|---|
| The WHERE clause proves that all matching rows have `ts >= cutoff` (equality, `>=`, `>`, BETWEEN, IN, or OR, all in the hot range). | HOT | The statement becomes `UPDATE _events SET ... WHERE ...`, plain PG DML that preserves RETURNING. |
| The WHERE clause proves that all matching rows have `ts <  cutoff`. | COLD | The statement becomes `SELECT coldfront._exec_iceberg_with_claim('ice.public.events', 'UPDATE ice.public.events SET ... WHERE ...')`, with the DuckDB DML as a standard SQL literal (via `quote_literal_cstr`), or as a `format()` call when bound parameters are present. The SELECT envelope keeps the DML off PG's command-ID counter, so pg_duckdb's mixed-write guard does not fire. |
| The WHERE clause cannot be proven to target one tier. | AMBIGUOUS | The rewrite depends on `coldfront.allow_mixed_writes` (see the next section). |

The classifier understands `Var <op> bound` (both operand orders), AND of
those, OR of those when all arms prove the same tier, BETWEEN (via its
desugaring to AND), and `ts IN (...)` (ScalarArrayOpExpr). The bound must be
`timestamptz`-typed: a literal, or a non-volatile expression such as
`now() - interval '1 hour'` (a STABLE function call counts); IN-list elements
must be `timestamptz` literals. A `date` or `timestamp` literal, a volatile
call, a subquery, or an expression on the partition column classifies as
AMBIGUOUS.

The tier classification above applies to the WHERE clause. The SET clause has a
separate rule for the partition column itself, because changing it can move a
row across the cutoff. An in-place per-tier rewrite would leave such a row in
its old tier where the view's tier predicate then hides it, so the hook handles
a partition-column SET separately by the `coldfront.allow_mixed_writes` GUC:

- When the GUC is on (permissive, the default), the hook rewrites the UPDATE to
  `SELECT coldfront._cross_tier_move(...)`, which RELOCATES each matched row
  between tiers. The function first checks that every hot landing target has a
  covering partition, then captures the affected rows and applies four disjoint
  cases by current tier and new value: stay-hot (in-place heap UPDATE),
  stay-cold (re-add to Iceberg with the new value), hot to cold (heap DELETE
  plus Iceberg INSERT), and cold to hot (heap INSERT plus Iceberg DELETE). The
  hot side is plain PG; the cold side is one `duckdb.raw_query` (DELETE plus
  INSERT, one Iceberg snapshot) under one bakery claim. A target value with no
  covering hot partition is rejected naming the view; the move is not supported
  inside a function or DO block, with bound parameters, with a VOLATILE new
  value, with a bare NULL new value, with a new value referencing other
  columns, alongside a SET of other columns, with `RETURNING`, with a WHERE
  that references other tables or sub-queries (`UPDATE … FROM`, a sub-select),
  or on a hot table without a primary key.
- When the GUC is off (strict), the hook rejects the partition-column SET. To
  change the partition column, delete the row and re-insert it with the new
  value.

Before anything is archived (no cutoff) every row is hot, so a partition-column
UPDATE is a plain hot UPDATE in either mode.

## Write Modes: Strict vs Permissive (`allow_mixed_writes`)

When the predicate is AMBIGUOUS the hook picks one of two behaviors from the
`coldfront.allow_mixed_writes` GUC (USERSET, default `on`).

### Permissive (`on`, Default)

The hook emits a dual-tier CTE:

```sql
WITH hot AS (UPDATE _events SET ... WHERE ... RETURNING *)
   , cold AS (SELECT coldfront._exec_iceberg_with_claim('ice.public.events',
                       'UPDATE ice.public.events SET ... WHERE ...'))
SELECT h.* FROM hot h CROSS JOIN cold c;
```

The CROSS JOIN forces PG to execute the cold CTE (a pure-SELECT CTE that is not
otherwise referenced would be pruned even with MATERIALIZED). The hook also
sets `duckdb.unsafe_allow_mixed_transactions = on` LOCAL for the current
transaction to clear pg_duckdb's pre-commit mixed-write check. pg_duckdb's
`XactCallback` ties DuckDB's transaction to PG's, so `ROLLBACK` undoes both
tiers - but the path is **not crash-safe**: a backend crash between the Iceberg
upload and the PG commit can leave orphaned object-storage files referenced by
an uncommitted snapshot. Iceberg housekeeping (orphan-file expiry) reclaims
them. Strict mode avoids this path entirely.

### Strict (`off`)

The hook raises an error with a hint pointing at the partition column and the
accepted predicate shapes; nothing is written. Use strict mode to guarantee
every write is unambiguously attributable to one tier, at the cost of requiring
applications to supply a tier-deterministic WHERE clause.

## Tiered Tables in a Spock Mesh

The bakery protocol that serializes cold writes cluster-wide is described in
[architecture.md → Concurrency](architecture.md#concurrency-and-pgedge-spock-deployments).
This section covers what is specific to a *tiered* table across a mesh.

A tiered table provisioned on one node becomes usable on every peer, but the
pieces arrive by different routes. The following table shows how each
capability reaches a peer:

| Capability on a peer | How it gets there |
|---|---|
| Read (hot and cold, via the `UNION ALL` view) | The view is created by replicated DDL; hot rows arrive via normal Spock DML replication; cold rows are read from the shared Lakekeeper catalog, which a node attaches only for a view that has a `coldfront.tiered_views` row, so reads need that row too. |
| INSERT, UPDATE and DELETE through the view, and DDL blocking | These need the `coldfront.tiered_views` row present on the peer, because the hook resolves the target view through that row. Without it the statement is not rewritten, and once the view has its cold branch PostgreSQL refuses it ("cannot insert into view"). |
| Hot/cold write routing | Routing needs the `coldfront.archive_watermark` row (name-keyed) so the peer's write hook knows the cutoff. |

So alongside the bakery substrate (`coldfront.claims` /
`coldfront.claim_acks`), **both `coldfront.tiered_views` and
`coldfront.archive_watermark` are added to the Spock replication set** when a
mesh runs in tiered mode. The archiver runs on one node, so a peer only gets
these rows by replication; without `tiered_views` a peer cannot read the cold
tier, and INSERT/UPDATE/DELETE/DDL-blocking stop recognizing the view.

Both tables are **name-keyed** - `tiered_views` by `(schema_name, relname)`,
`archive_watermark` by `table_name` - so each row replicates verbatim and
correct on every node, with no OID divergence to reason about. See
[architecture.md → Registry Keying](architecture.md#registry-keying-by-name-not-oid).

## Partition Scheme Compatibility

The archiver tiers two partition shapes: a flat table partitioned by RANGE on a
single time-like column, and a two-level `LIST → RANGE` tree registered with a
sub-partition block. Anything else is rejected at archiver startup.

### Supported: Single-Column RANGE

The archiver accepts a single-column RANGE-partitioned table such as the
following:

```sql
CREATE TABLE events (id bigint GENERATED ALWAYS AS IDENTITY,
                     ts timestamptz NOT NULL, ...)
  PARTITION BY RANGE (ts);
CREATE TABLE p_2026_01 PARTITION OF events
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
```

The partition column, primary-key columns, and any
`GENERATED ALWAYS AS IDENTITY` columns are auto-detected from `pg_catalog` - no
assumptions about naming or arity.

### Not Supported: Composite Partition Keys

The archiver rejects composite partition keys such as
`PARTITION BY RANGE (tenant_id, ts)` and similar. The archiver uses a single
scalar watermark per table; a composite key would need one watermark per
non-time dimension value.

### Supported: Two-Level LIST → RANGE, with a Sub-Partition Block

A table whose top level is `LIST` and whose children are themselves
`RANGE`-partitioned by time is tiered as one relation:

```sql
CREATE TABLE events (...) PARTITION BY LIST (branch_id);
CREATE TABLE events_branch_1 PARTITION OF events
  FOR VALUES IN (1) PARTITION BY RANGE (ts);
```

Registering such a table requires a sub-partition block naming the query that
yields the current LIST values, and an explicit `partition_column` for the
RANGE (time) key, since on a first run there is no LIST child to detect it
from:

```sh
archiver register --config cf.yaml --table events --period monthly \
    --column ts --hot-period "1 month" \
    --sub-values-source "SELECT branch_id FROM branches"
```

The design is in
[Two-level (LIST → RANGE) tiering](#two-level-list-range-tiering).

Registered **without** a sub-partition block, a table with any sub-partitioned
child is rejected at startup: the flat path has no way to enumerate the LIST
children or to coordinate one watermark across them. The alternative to a
sub-partition block is to register each `events_branch_N` as its own flat
table, tiered independently. Each then becomes its own view, and applications
query those rather than the top-level `events`.

### Performance Note: Partition Pruning After the Swap

A query through the `events` view routes via pg_duckdb's takeover path
(`iceberg_scan` is present, so pg_duckdb converts the whole query to DuckDB
SQL, which issues a `postgres_scan` on `_events` where PG applies partition
pruning natively). A single-table read whose WHERE proves it hot
(`ts >= cutoff`) is rerouted to `_events` automatically and runs in plain
PostgreSQL. Other queries through the view, such as joins or reads that span
the cutoff, pay pg_duckdb's roundtrip overhead; users who know such a query
hits only hot data can query `_events` directly for fully native PG with no
pg_duckdb involvement:

```sql
-- Through the view: a provably hot single-table read is rerouted to _events.
SELECT * FROM events WHERE ts = '2026-04-15';

-- Directly on the hot table (native PG partition pruning only):
SELECT * FROM _events WHERE ts = '2026-04-15';
```

This is a read-path detail; writes are unaffected.

## Cold-Tier Partitioning

The archiver creates the Iceberg table partitioned the way the hot table is:
`month(ts)` or `day(ts)` on the time column, following `partition_period`, and
for a two-level LIST→RANGE table the LIST column first, so `regional` becomes
`PARTITIONED BY (region, month(ts))`. The spec is set at
`CREATE TABLE IF NOT EXISTS` and stays with the table. Each export then writes
exactly one partition, the Phase-0 wipe of a leaf covers exactly one, and a
predicate on `ts` or on the LIST column skips whole manifests before any data
file is opened: the manifest list records each manifest's partition-value
bounds, and duckdb-iceberg applies the transform to the predicate's constant to
compare them. The comparison is by month, so an upper bound that falls exactly
on a month's start keeps that month's manifests (`ts < '2026-07-01'` reads as
"up to and including July"); the files inside them are still skipped on their
own statistics. The `month` or `day` of a `timestamptz` is its UTC month or
day, on write and on read, whatever the session's time zone. Data files sit
under `data/month_ts_<n>=<months since 1970>/`, or
`data/identity_region_<n>=<value>/month_ts_<n>=…/` for a two-level table
(beside a transform, the engine names the identity term by its spec field
rather than the bare column); the path is opaque to readers, and iceberg-go's
rewrites use the same field name with its own value format. Within a partition,
each file's `min(ts)/max(ts)` statistics prune as well. Retention DELETEs and
the wipe are position deletes, so partitioning makes reads skip months; it does
not make deletes less expensive.

## Tiered-Specific Limitations

These are specific to the dual-tier model. Cross-cutting limitations (the
planner-level takeover, jsonb-as-json, single-node execution, S3 compatibility,
one-time secret setup) are in
[architecture.md → Known Limitations](architecture.md#known-limitations).

The dual-tier model has the following limitations:

- Any write that touches the cold tier (a cold-only UPDATE/DELETE, a permissive
  dual-tier UPDATE/DELETE, or a watermark-split INSERT) **rejects `RETURNING`
  with a clear error** rather than returning a partial result. The cold tier
  genuinely cannot return affected rows: duckdb-iceberg's binder refuses
  `RETURNING` on Iceberg writes and pg_duckdb's row-returning entry point is
  SELECT-only. Hot-only DML keeps `RETURNING` (it is plain PG DML).

- An ambiguous dual-tier UPDATE returns the command tag `SELECT n` rather than
  `UPDATE n`, because the rewrite produces a SELECT wrapper around a DML CTE.
  The row count reflects hot rows only. Other rewritten writes report
  `SELECT 1`: a top-level cold-only UPDATE/DELETE, a watermark-split INSERT
  (which returns one `(hot_rows, cold_rows)` row), and a cross-tier move.
  Inside PL/pgSQL, a cold-only write reports `UPDATE 0`, so `FOUND` is false.

- An UPDATE/DELETE that references the same tiered view more than once - a
  self-join (`UPDATE events ... FROM events e2`), `DELETE ... USING events`, or
  a sub-select (`... WHERE id IN (SELECT ... FROM events)`) - is rejected with
  a clear error. The rewrite swaps only the leading result-relation reference,
  so a second one cannot be retargeted; reference the view once.

- A backend crash in the middle of a permissive write's commit can leave
  orphaned S3 objects; see
  [Write Modes](#write-modes-strict-vs-permissive-allow_mixed_writes).

- The source table must already be range-partitioned.

- Autovacuum on a freshly-loaded partition can block the cutover: Phase 4 of
  `archivePartition` takes `ACCESS EXCLUSIVE` on the partition under a 100 ms
  `lock_timeout`. Autovacuum's `SHARE UPDATE EXCLUSIVE` on the partition
  conflicts with that request, so while a vacuum runs, each attempt times out
  with `ERROR: canceling statement due to lock timeout`. The archiver retries
  up to 10 times in the same run, with backoff from 100 ms to 51.2 s; only then
  does the cutover fail, leaving the trigger and delta in place for the next
  cycle.

    To mitigate this, disable autovacuum on the soon-to-be-archived partition
    (`ALTER TABLE <part> SET (autovacuum_enabled = false);` - the setting goes
    with the partition when it is detached and dropped), or schedule the
    archive cycle so partitions have already settled.

## Next Steps

To go further with ColdFront, consult the following documents:

- The [Architecture](architecture.md) overview describes the mechanics both
  modes share.
- The [Decoupled Mode](architecture_decoupled.md) deep dive describes the
  bakery protocol that serializes cold writes.
- The [Using ColdFront](usage.md) guide covers tiering a table and managing it
  with the partition CLI.
