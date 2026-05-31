# Decoupled (iceberg-only) operating mode

This document describes an alternate operating mode of the coldfront
project where a table lives entirely in Iceberg — no PG-native heap,
no hot tier, no archiver. PostgreSQL becomes a stateless compute
front-end; storage is owned by Lakekeeper + the underlying S3-compatible
object store.

It shares the same codebase, docker stack and extension as tiered mode. The
shared mechanics — pg_duckdb Iceberg I/O, the rewrite hook, the bakery
protocol, the registry — are in [ARCHITECTURE.md](ARCHITECTURE.md); tiered
mode is in [ARCHITECTURE_TIERED.md](ARCHITECTURE_TIERED.md). This document
covers what is specific to decoupled mode.

## What "decoupled" means

| Concern | Tiered mode (existing) | Decoupled mode (this doc) |
|---|---|---|
| Hot rows | PG heap (`_events` partitioned) | — (no hot rows) |
| Cold rows | Iceberg via Lakekeeper | All rows in Iceberg |
| Unified view | `events` UNION-ALLs hot + cold | — (user queries Iceberg directly) |
| INSTEAD-OF trigger | Bypassed when coldfront is preloaded; remains as fallback when it isn't | — (none) |
| `post_parse_analyze_hook` | Rewrites INSERT/UPDATE/DELETE per tier | Rewrites every INSERT/UPDATE/DELETE on the wrapper view to a single `duckdb.raw_query(...)` against the Iceberg ref |
| Archiver | Moves rows hot → cold on cron | — (nothing to archive) |
| `coldfront.tiered_views` row | Required per managed table | — (table is not "managed" in tiered sense) |
| Required at runtime | `pg_duckdb`, `coldfront`, Lakekeeper, S3 | `pg_duckdb`, `coldfront` (for auto-ATTACH only), Lakekeeper, S3 |

The coldfront extension stays loaded purely because it provides the
session-bootstrap glue: the `coldfront_login_session_init` event
trigger, on every new connection, calls `coldfront.ensure_attached()`,
which issues `duckdb.raw_query('ATTACH IF NOT EXISTS ''wh'' AS ice
(TYPE ICEBERG, ENDPOINT ...)')` against the GUCs `coldfront.warehouse`
and `coldfront.lakekeeper_endpoint`. Without this, every new psql
session would have to ATTACH the catalog manually before queries work.

For tables registered as iceberg-only via `coldfront.create_iceberg_table()`,
the parse-analyze rewriter is the **primary** dispatch path: it
intercepts every INSERT/UPDATE/DELETE on the wrapper view and emits one
`SELECT duckdb.raw_query('…')` that targets the Iceberg ref directly —
single Iceberg snapshot per statement, no INSTEAD OF trigger involved.
Tables that don't appear in `coldfront.tiered_views` are invisible to
the hook (`lookup_tiered_view` returns null → fast path-out).

## Bootstrap sequence

```sql
-- (postgresql.conf or per-database config)
coldfront.warehouse = 'wh'
coldfront.lakekeeper_endpoint = 'http://lakekeeper:8181/catalog'

-- one-time, per database:
CREATE EXTENSION pg_duckdb;
CREATE EXTENSION coldfront;
SELECT duckdb.create_simple_secret(...);   -- S3 creds
SELECT coldfront.arm_login_attach();       -- enable login-time ATTACH
```

After that, every new connection has `ice.default.*` available.

## Interface

With the coldfront extension loaded and `arm_login_attach()` armed, the
wrapper view supports:

### What works

| Operation | Path | Notes |
|---|---|---|
| Auto-ATTACH on session start | login event trigger → `ensure_attached()` | One round-trip on connect |
| CREATE TABLE | `SELECT duckdb.raw_query('CREATE TABLE ice.<ns>.<name> (...)')` | DuckDB SQL, attached-catalog syntax |
| INSERT | `INSERT INTO <view> [VALUES (…) | SELECT … FROM <pg_table> | SELECT … FROM generate_series(…)]` — the C hook rewrites this to one `SELECT duckdb.raw_query('INSERT INTO ice.<ns>.<name> …')`. Source-table refs get prefixed with `pglocal.<schema>.<table>` so DuckDB's postgres extension streams the source via libpq into the Iceberg writer | Single Iceberg snapshot per INSERT, regardless of row count |
| UPDATE | `UPDATE <view> SET … WHERE …` — hook → `SELECT duckdb.raw_query('UPDATE ice.<ns>.<name> SET ... WHERE ...')` | Iceberg merge-on-read |
| DELETE | `DELETE FROM <view> WHERE …` — hook → `SELECT duckdb.raw_query('DELETE FROM ice.<ns>.<name> WHERE ...')` | Iceberg position-delete files |
| SELECT (function-call form) | `SELECT … FROM iceberg_scan('ice.<ns>.<name>') r WHERE r['col'] = …` | Columns must use `r['col']` accessor |
| SELECT (raw-query form) | `SELECT duckdb.raw_query('SELECT ... FROM ice.<ns>.<name> WHERE ...')` | Returns scalar/text result via pg_duckdb's NOTICE channel |
| ROLLBACK of writes | `BEGIN; raw_query(...); ROLLBACK;` | pg_duckdb's `XactCallback` ties DuckDB↔PG tx — verified |
| DROP TABLE | `SELECT duckdb.raw_query('DROP TABLE ice.<ns>.<name>')` | |

### What does not work

| Attempt | Failure |
|---|---|
| `SELECT * FROM ice.default.events` | PG parser rejects: `cross-database references are not implemented`. PG sees the 3-part name as `database.schema.table` and refuses. There is no "ice is an attached duckdb catalog" handling at the PG parser level. |
| `INSERT INTO ice.default.events VALUES (...)` (PG-native DML on the 3-part name) | Same parser rejection. |
| Bare-column predicates on `iceberg_scan(...)` | `iceberg_scan` returns a single-column row of struct; columns must be accessed via `r['col']`. Bare `WHERE col = …` fails with "column does not exist". |

The net effect: every read or write of an Iceberg-only table either
goes through the `iceberg_scan(...)` table-function (with `r['col']`
accessor) or through `duckdb.raw_query('… DuckDB SQL …')`. Neither is
as ergonomic as a normal PG table. This is the fundamental ergonomics
gap of decoupled mode without a PG-side wrapper view.

## Supported column types

Decoupled mode is not vanilla PostgreSQL — it is a service that
PostgreSQL fronts. The supported column types are exactly the set
that already round-trips cleanly between PG and Iceberg in the
existing tiered mode (see `pgFormatTypeToDuckDB` in
[cmd/archiver/main.go](cmd/archiver/main.go)). Anything outside this
list is rejected at table-creation time.

| PG type | Iceberg/Parquet storage | Round-trip surface |
|---|---|---|
| `bigint` / `integer` / `smallint` | `BIGINT` / `INTEGER` / `SMALLINT` | identical |
| `real` / `double precision` | `REAL` / `DOUBLE` | identical |
| `boolean` | `BOOLEAN` | identical |
| `timestamp with time zone` | `TIMESTAMPTZ` | identical |
| `timestamp without time zone` | `TIMESTAMP` | identical |
| `date` / `time without time zone` | `DATE` / `TIME` | identical |
| `uuid` | `UUID` | identical |
| `bytea` | `BLOB` | identical |
| `oid` | `BIGINT` (signed-safe widen) | identical |
| `text` / `varchar(N)` / `char(N)` | `VARCHAR` | unbounded; declared length not enforced |
| `numeric(P,S)` (P ≤ 38) | `DECIMAL(P,S)` | identical |
| `jsonb` / `json` | `VARCHAR` | view-cast back to `json` (not `jsonb` — Iceberg has no JSON primitive) |
| `interval` | `VARCHAR` | view-cast back to `interval` |

Rejected (rather than silently downgraded to `VARCHAR` and losing
precision/identity):

- `inet` / `cidr` — pg_duckdb cannot process PG `inet` (Oid 869) in any query it plans, and every Iceberg-backed read is planned by pg_duckdb. No cast makes them readable; store IP data as `text`.
- `numeric` without explicit `(P,S)` — Iceberg requires bounded decimals.
- Custom enums, `xml`, `tsvector`/`tsquery`, range types, multirange types.
- Composite types and arrays. (Arrays would map to Parquet `LIST<…>` only if the element type is itself supported; not yet implemented for decoupled mode.)
- Any type not enumerated above.

The narrowing is deliberate: a type that cannot round-trip exactly is
worse than no support, because the data appears to be stored but
silently changes shape on read. The single source of truth for what
coldfront accepts is the function above; both decoupled mode and
tiered mode share it.

## Wrapper helper: `coldfront.create_iceberg_table()`

Raw_query / iceberg_scan are functional but ergonomically poor — every read needs `r['col']` accessor, every write needs a `duckdb.raw_query('… DuckDB SQL …')` envelope. To close that gap, coldfront ships a single helper that provisions an Iceberg-only table together with a PG-side wrapper view and a registry row that arms the C hook to handle every DML on the view. After that, applications use **plain PG syntax** against the named relation:

```sql
SELECT coldfront.create_iceberg_table(
    'public', 'events',
    '[
      {"name":"id",     "type":"bigint"},
      {"name":"ts",     "type":"timestamptz"},
      {"name":"status", "type":"text"},
      {"name":"data",   "type":"jsonb"}
    ]'::jsonb
);

INSERT INTO events VALUES (1, now(), 'ok', '{"k":1}');
SELECT id, status, data->>'k' FROM events WHERE id = 1;
UPDATE events SET status = 'done' WHERE id = 1;
DELETE FROM events WHERE id = 1;
```

What the helper does:

1. `duckdb.raw_query('CREATE SCHEMA IF NOT EXISTS ice."default"')` — idempotent namespace creation against Lakekeeper.
2. `duckdb.raw_query('CREATE TABLE ice.default.<name> (col1 STORAGE_TYPE, …)')` — column types are validated by `coldfront._iceberg_storage_type()`, which mirrors the canonical map in `cmd/archiver/main.go pgFormatTypeToDuckDB`. Anything outside the supported set (see "Supported column types" above) raises before any DDL is issued.
3. `CREATE OR REPLACE VIEW <schema>.<name> AS SELECT r['col']::pg_type AS col, … FROM duckdb.query('SELECT * FROM ice.default.<name>') AS t(r)` — projection wraps the struct accessor so applications see flat columns. View-cast types (`jsonb` → `json`, `interval`) are surfaced via the appropriate cast. The view source is `duckdb.query()` rather than `iceberg_scan()` specifically to make read-your-own-write inside an explicit transaction work; pg_duckdb's planner folds it into the same `ICEBERG_SCAN` plan with identical Parquet predicate pushdown, so there's no perf cost (verified with `EXPLAIN ANALYZE`: both forms hit `Function: ICEBERG_SCAN, Filters: id=N, Total Files Read: 7`, ~14ms warm).
4. Registers the row in `coldfront.tiered_views` with `is_iceberg_only = true`. The C-side `post_parse_analyze_hook` reads this flag and short-circuits `classify_tier()` to `TIER_COLD` for any INSERT/UPDATE/DELETE on the wrapper view, regardless of WHERE clause or watermark — so every write rewrites cleanly into a single `SELECT duckdb.raw_query('INSERT/UPDATE/DELETE ice.default.<name> …')`. INSERT in particular: the hook emits one bulk `raw_query` for the entire statement (VALUES list inlined for VALUES, source-table refs prefixed with `pglocal.<schema>.<table>` for `INSERT … SELECT FROM <pg_table>` so DuckDB's postgres extension streams source rows over libpq into the Iceberg writer in one pipeline). No INSTEAD OF INSERT trigger is created — the hook is the dispatch path.

Write semantics through the wrapper view:

- INSERT → row appears in Iceberg, fresh-session SELECT sees it.
- UPDATE → row updates in Iceberg, fresh-session SELECT sees the new value.
- DELETE → row removed from Iceberg.
- ROLLBACK of an INSERT/UPDATE inside `BEGIN` undoes the Iceberg snapshot; post-tx count matches pre-tx count.
- jsonb column round-trips through Parquet `VARCHAR` storage and surfaces as PG `json` via the wrapper view's cast (`data->>'k'` works).

Limits the helper inherits from the platform:

- **No partition spec at CREATE.** `p_partition_cols` is accepted as a parameter but currently ignored — pg_duckdb v1.1.1 + duckdb-iceberg do not yet expose Iceberg partition specs at CREATE TABLE time. Predicate pushdown still works via Parquet row-group statistics.
- **Cross-session snapshot consistency.** Within one tx, multiple SELECT statements may observe writes from *other* sessions interleaved with their own scans — pg_duckdb has no equivalent of PG's repeatable-read snapshot pin across iceberg_scan invocations. (Read-your-own-write within the same tx *does* work via the duckdb.query() wrapper — see point 3 above.)
- **Mixed-write guard relaxed.** The helper sets `duckdb.unsafe_allow_mixed_transactions = on` LOCAL during provisioning (Iceberg DDL + coldfront registry row both happen). The hook does the same for each rewritten DML so PG-side parse-analyze + DuckDB-side raw_query coexist in one tx. ROLLBACK still works via XactCallback; the flag only bypasses the pre-commit guard.

The helper doesn't add capability over raw_query — it composes the existing primitives into a single call so applications get a normal-looking PG table.

## ACID model

(Summarises material from [ARCHITECTURE.md](ARCHITECTURE.md) §Concurrency
and §Known Limitations applied to the decoupled scenario.)

| Property | Status |
|---|---|
| Atomicity (single statement) | **Yes.** One `duckdb.raw_query('INSERT/UPDATE/DELETE …')` is one DuckDB transaction → one Iceberg snapshot commit. |
| Atomicity (multi-statement tx, graceful) | **Yes.** pg_duckdb's `XactCallback` ties the DuckDB transaction to PG's, so PG `ROLLBACK` undoes pending Iceberg writes. Verified end-to-end (`BEGIN; INSERT; ROLLBACK;` → row count unchanged). |
| Atomicity (multi-statement tx, backend crash) | **Partial.** A backend crash between Iceberg snapshot commit and PG commit can leave S3 objects orphaned. Iceberg housekeeping (orphan-file expiry) reclaims them; not corrupting, but a real failure mode for very-strict ACID requirements. |
| Consistency | **Yes** within a snapshot — Iceberg's serializable model + Lakekeeper optimistic concurrency. |
| Isolation | **Read-your-own-write within a tx works** when the wrapper view uses `duckdb.query('SELECT * FROM ice.…')` as its read path (the helper does this by default). Verified end-to-end: `BEGIN; INSERT (10, …); SELECT WHERE id=10;` returns the row; `BEGIN; UPDATE id=1 SET status='x'; SELECT WHERE id=1;` returns the new status. The plain `iceberg_scan('ice.…')` form is *not* tx-aware (it re-resolves the table from Lakekeeper each call), but pg_duckdb's planner folds `duckdb.query('SELECT * FROM ice.…')` into the same `ICEBERG_SCAN` plan with identical predicate pushdown, so we get tx visibility for free. **Cross-call snapshot consistency is still weaker** than PG-native: a long-running SELECT that touches the table from multiple statements within one tx may observe writes from *other* sessions interleaved with its own scans — pg_duckdb has no equivalent of PG's repeatable-read snapshot pin across iceberg_scan invocations. |
| Durability | **Yes** — Iceberg commits are durable on the object store once Lakekeeper acknowledges. Stronger than PG WAL on local disk for many production setups. |

The headline restriction is the isolation gap. A long-running analytic
read that touches the same Iceberg table multiple times within one PG
transaction may observe writes from other sessions interleaved with
its own scans — behaviour that does not match PG's MVCC for native
heap. Document loudly to applications.

## Concurrency / horizontal scaling — the bakery protocol

Decoupled mode makes the data layer fully shared between any number of
PG nodes pointing at the same Lakekeeper endpoint and S3 bucket.

- **Reads scale out trivially.** Each PG node hits Lakekeeper + S3
  independently. New nodes spin up in seconds; no data sync.

- **Writes are serialized PG-side by the bakery protocol** so they
  never collide at Lakekeeper. The implementation is Lamport's 1978
  distributed mutual exclusion with the Ricart–Agrawala (1981)
  deferred-reply optimisation, riding on Spock's per-origin FIFO
  apply ordering as the message-delivery primitive. Modelled in
  [docs/formal/Bakery_v2.tla](docs/formal/Bakery_v2.tla); the
  TLC-checked safety properties live in `Bakery_v2.cfg`.

  Two tables, both in Spock's `default` repset:

  - `coldfront.claims` — each writer inserts `(iceberg_table, ticket)`
    here; deleted on release.
  - `coldfront.claim_acks` — peers insert `(ticket, ack_from_node,
    iceberg_table)` to acknowledge an originator's claim. Replicates
    back to the originator.

  Locally on every node, `coldfront.deferred_acks` queues acks the
  node has *deferred* because it has its own pending claim with a
  smaller ticket on the same table. Not replicated.

  Per-writer flow:

  1. `snowflake.nextval()` — fresh globally-unique ticket.
  2. Insert `(iceberg_table, ticket)` into `coldfront.claims` via
     dblink (autonomous tx; replicates async via Spock).
  3. **Wait until both** (a) no same-node writer has a smaller
     ticket on this table, and (b) every alive peer has acked the
     ticket (its row appears in `coldfront.claim_acks`).
  4. Issue the iceberg `duckdb.raw_query(...)` write — exactly one
     uncontested commit at Lakekeeper.
  5. Delete the claim by ticket (autonomous dblink). The release
     trigger drains `coldfront.deferred_acks` for that ticket,
     emitting any acks the node had been holding back.

  Peer-side, when Spock applies an incoming claim INSERT, an
  `ENABLE REPLICA` trigger (`coldfront._on_claim_apply`) decides:

  - If the peer has its own pending claim with a *smaller* ticket on
    the same table → defer (queue in `coldfront.deferred_acks` to
    emit later when the smaller claim is released).
  - Otherwise → ack immediately (INSERT into `coldfront.claim_acks`
    via dblink, so the row is tagged with the local node as origin
    and Spock replicates it back to the originator).

  The deferral rule is exactly what makes R-A safe over an
  asymmetric-apply substrate like Spock: an originator only proceeds
  once it has heard from every alive peer, and a peer cannot say
  "go ahead" while it still has an earlier-ticketed claim of its
  own pending — that closes the local-view race the naïve
  `min(ticket)` polling left open.

  The protocol works across **any number of writers per node** —
  each call holds its own unique ticket; release deletes by ticket
  only, so concurrent backends on the same node coexist cleanly.
  Same-node writers serialise on a local read of `coldfront.claims`
  (snowflake tickets are per-node monotonic + timestamped, so a
  smaller ticket means `nextval` was called earlier on this node).

  The wait phase has no explicit timeout. R-A's only failure mode
  is a dead peer (would block forever), and we close it via a
  liveness check on `pg_stat_replication.reply_time`: a peer whose
  walsender has been silent longer than
  `coldfront.peer_alive_window_ms` (default 5000 ms; tune up on
  slow/lossy WAN links) is implicitly treated as already-acked. An
  *alive* peer that hasn't acked is either deferring (R-A's defer
  rule, legitimate) or about to ack — either way, waiting is
  correct. Local same-node backends are trusted; a crashed local
  writer's claim is released by PG's xact rollback via the C
  XactCallback in
  [extension/coldfront/src/coldfront.c](extension/coldfront/src/coldfront.c).

  The mechanics live in [extension/coldfront/coldfront--0.1.sql](extension/coldfront/coldfront--0.1.sql)
  (`_claim_iceberg_lock`, `_release_iceberg_lock`,
  `_on_claim_apply`, `_on_claim_release`, `_exec_iceberg_with_claim`)
  and the C-side rewrite in [extension/coldfront/src/coldfront.c](extension/coldfront/src/coldfront.c)
  (`wrap_cold_in_exec_with_claim`).

  Because every commit is uncontested, the duckdb-iceberg writer
  never has to deal with a 409 — no rebase-retry loop needed at
  all. (Upstream `duckdb-iceberg` does not implement one; the
  bakery sidesteps the requirement.)

- **DDL replication.** Spock's `ddl_sql` repset replicates
  `CREATE/ALTER/DROP` of the wrapper view + `coldfront.tiered_views`
  registry rows, so a `coldfront.create_iceberg_table()` call on one
  node propagates to peers automatically.

### Throughput characterisation

Validated end-to-end on 3-node EC2 + Lakekeeper + S3 (eu-west-2),
matched 90 M-row totals (3 workers × 300 INSERTs × 100 K rows):

| Layout | Wall | Aggregate | Per-writer | Snapshots |
|---|---:|---:|---:|---:|
| 1 PG node, 3 concurrent workers | 119 s | 756 k/s | 252 k/s | 902 |
| 3 PG nodes, 1 worker each | 119 s | 756 k/s | 252 k/s | 902 |

Identical wall time in both layouts confirms the **commit-rate
ceiling sits at Lakekeeper, not at the PG side** — adding writers
(local or distributed) doesn't speed commits beyond that ceiling.
Throughput improves by either using **bigger per-INSERT batches**
(fewer commits move the same rows) or partitioning the Iceberg
table along a dimension that lets writers commit to disjoint table
versions.

### Required configuration on every PG node

```ini
# postgresql.conf — server-wide
wal_level = logical
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'

# Receiver-side: how often a wal receiver sends spontaneous status
# updates to its upstream walsender.  This is what keeps
# pg_stat_replication.reply_time fresh on the sender, which the
# bakery's dead-peer liveness check consults.  PG default is 10 s; the
# bakery's liveness window (coldfront.peer_alive_window_ms, default
# 5 s) would otherwise false-positive every idle peer as "dead" on the
# first claim after a quiet period.  1 s leaves comfortable margin.
wal_receiver_status_interval = 1s

# Sync-rep is NOT required by the bakery — R-A's ack barrier replaces
# it.  You can still enable it cluster-wide for stronger non-bakery
# durability, but it's not load-bearing for iceberg-commit ordering.
```

```ini
# postgresql.conf — per-node.  snowflake.node MUST equal
# (hashtext(<spock node_name>) & 1023) — the bakery raises at first
# claim if these disagree (it maps peers' tickets back to a spock
# node_name via the same hash for dead-peer detection).
snowflake.node = 1     # db1
# snowflake.node = 2   # db2
# snowflake.node = 3   # db3

# DSN used for the bakery's autonomous-tx claim/ack dblink calls.
# Unix socket avoids TCP overhead; `event_triggers=off` bypasses the
# coldfront login trigger so the dblink session never enters DuckDB
# territory. application_name=coldfront_dblink is a marker for logs.
coldfront.dblink_self = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_dblink options=-cevent_triggers=off'

# Optional — peer-liveness window for R-A's dead-peer escape
# (default 5000 ms, matches spock's default heartbeat cadence).
# A peer whose pg_stat_replication.reply_time is older than this is
# treated as already-acked. Raise on slow/lossy WAN links.
coldfront.peer_alive_window_ms = 5000
```

The bakery has no peer-ack timeout knob. Dead peers are caught by
the `pg_stat_replication.reply_time` liveness check inside the
wait-loop (a stale walsender is treated as already-acked); alive
peers that haven't acked are either deferring legitimately or
about to ack.

**Per-node bootstrap** — after spock mesh setup, register the bakery
tables in each node's default repset. Required because
`spock.repset_add_table` needs the local spock node to exist
(can't run at `CREATE EXTENSION` time):

```sql
-- run on every node, after spock.node_create + spock.sub_create:
SELECT coldfront._ensure_claims_replicated();
```

The helper is idempotent. Without it on a peer, that peer's ack
INSERTs are local-only and never replicate back to the originating
writer — every claim ack-waits to timeout. CI verifies this via the
sentinel-claims-in-all-6-directions probe before any iceberg write
(see `run-ci-distributed.sh` step 12b).

`coldfront.create_iceberg_table()` calls `_ensure_claims_replicated()`
on the node it runs on, but that only registers the repset on *that*
node. Peers receive the wrapper-view DDL via Spock's `ddl_sql` repset
but do *not* re-run the helper — so the explicit per-node call above
is mandatory in any multi-node setup.

## Interaction with the tiered-mode archiver (and why decoupled
sidesteps a known pg_duckdb libpq linker bug)

Decoupled mode never invokes the archiver. The archiver only exists for
tiered mode, where it moves rows hot → cold on a watermark cutover.
Phase 3 of an archive cycle (delta replay) needs to read PG-side rows
from a capture/scratch table and stream them into Iceberg in one
`duckdb.raw_query`. The fast path uses DuckDB's `postgres` extension
(ATTACH-ed as `pglocal` via [coldfront.ensure_pg_attached()](extension/coldfront/coldfront--0.1.sql)),
which can crash with

```
IO Error: Unable to connect to Postgres at "...":
libpq is incorrectly linked to backend functions
```

depending on how `pg_duckdb` was built. Symbol-rename handling differs
between upstream `pgduckdb/pgduckdb:18-v1.1.1` binaries and
some source-built variants — when DuckDB's libpq tries to open a
loopback connection from inside a PG backend, the linker can resolve a
backend-internal symbol instead of the libpq one and abort. The
single-node CI's archiver race-window test (`run-ci-local.sh` step 8b)
exercises this path and consequently fails on builds that hit the bug.

**Decoupled mode does not call `ensure_pg_attached()` on its write path.**
The bakery (`_claim_iceberg_lock` / `_release_iceberg_lock` /
`_exec_iceberg_with_claim`) coordinates entirely through dblink loopback
(plain libpq) and Spock-replicated `coldfront.claims` rows. Iceberg
writes use `duckdb.raw_query('INSERT/UPDATE/DELETE ice.…')` with
inlined VALUES literals or DuckDB-side-only sources (`generate_series`,
attached Iceberg tables) — never `pglocal.<schema>.<table>`. So
decoupled mode is unaffected by the libpq linker conflict regardless of
how `pg_duckdb` was built.

**Implication for distributed deployments:** if your build of
`pg_duckdb` exhibits the libpq conflict, you can still run
coldfront in decoupled mode at full performance; only tiered mode's
archiver Phase 3 is impacted. The ergonomic-loss-vs-OLTP-needs decision
in the next section is the right framing — the libpq quirk is a
reason to lean **toward** decoupled, not away from it.

## When to use decoupled vs tiered

**Decoupled (iceberg-only) is the right choice when:**

- The application's read path is dominated by analytic OLAP queries
  (the cold-tier numbers in [bench.md](bench.md) Group C show 1.4–22×
  speedups vs PG heap on shape-matched workloads).
- Operational simplicity outweighs ergonomics: no archiver cron, no
  watermark, no autovacuum-vs-cutover lock conflict (see
  ARCHITECTURE_TIERED.md → Tiered-specific limitations), no PK rebuild after bulk load, no
  partition-management script.
- You can tolerate the isolation gap (cross-query snapshot
  consistency) and the verbose `iceberg_scan` / `raw_query` syntax.
- You want true storage/compute decoupling — adding compute = `docker
  run` a new PG node, no data sync.

**Tiered (existing default) remains the right choice when:**

- The workload has a strong recent-row OLTP component that needs
  PG-native point lookups, indexes, and transactional UPDATE/DELETE
  ergonomics.
- The application queries through a stable named relation (`events`)
  and you don't want to refactor every query to use `iceberg_scan(...)`
  or `raw_query(...)`.
- You need full PG ACID isolation across the whole table.

## Limitations

- **Cross-call snapshot pinning.** PG-native isolation across multiple
  `iceberg_scan` calls within one transaction would require either upstream
  support in pg_duckdb (a "freeze the iceberg snapshot at tx-start" knob) or
  a session-level lock; neither is in place, so a long-running transaction
  can observe a newer snapshot on a later scan.
