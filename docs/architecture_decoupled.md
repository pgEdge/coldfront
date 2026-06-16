# Decoupled (iceberg-only) operating mode

This document describes an alternate operating mode of the coldfront
project where a table lives entirely in Iceberg — no PG-native heap,
no hot tier, no archiver. PostgreSQL becomes a stateless compute
front-end; storage is owned by Lakekeeper + the underlying S3-compatible
object store.

It shares the same codebase, docker stack and extension as tiered mode. The
shared mechanics — pg_duckdb Iceberg I/O, the rewrite hook, the bakery
protocol, the registry — are in [architecture.md](architecture.md); tiered
mode is in [architecture_tiered.md](architecture_tiered.md). This document
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
| Required at runtime | `pg_duckdb`, `coldfront`, Lakekeeper, S3 | `pg_duckdb`, `coldfront` (for lazy catalog ATTACH only), Lakekeeper, S3 |

The coldfront extension provides the lazy catalog-attach glue: the C
extension hook intercepts the first query that touches a tiered view
(read or write) and, if the Iceberg catalog `ice` is not yet attached
in this session, issues
`duckdb.raw_query('ATTACH IF NOT EXISTS ''wh'' AS ice (TYPE ICEBERG,
ENDPOINT ...)')` against the GUCs `coldfront.warehouse` and
`coldfront.lakekeeper_endpoint`. There is no connect-time setup — the
attach happens on demand, transparently, the first time a session
actually queries Iceberg.

For tables registered as iceberg-only via `coldfront.create_iceberg_table()`,
the parse-analyze rewriter is the **primary** dispatch path: it
intercepts every INSERT/UPDATE/DELETE on the wrapper view and emits one
`SELECT duckdb.raw_query('…')` that targets the Iceberg ref directly —
a single Iceberg snapshot per statement.
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
SELECT coldfront.set_storage_secret('<key>', '<secret>', '<endpoint>');  -- cold-tier S3 creds
```

`set_storage_secret` stores the credentials in the
`coldfront.storage_secret` table — an extension-member table (so its
data is excluded from `pg_dump` by default) that is added to the Spock
repset (so it replicates by value to every mesh node) — and
materializes a DuckDB PERSISTENT SECRET, which DuckDB loads at instance
init. It is set once; no per-session arming is needed.

After that, the first query touching a tiered view in any session
lazily attaches the catalog and `ice.default.*` becomes available.

## Interface

With the coldfront extension loaded and the storage secret set, the
wrapper view supports:

### What works

| Operation | Path | Notes |
|---|---|---|
| Lazy catalog ATTACH | C hook → `ensure_attached()` on first query touching a tiered view | One round-trip on first Iceberg query per session |
| CREATE TABLE | `SELECT duckdb.raw_query('CREATE TABLE ice.<ns>.<name> (...)')` | DuckDB SQL, attached-catalog syntax |
| INSERT | `INSERT INTO <view> [VALUES (…) | SELECT … FROM <pg_table> | SELECT … FROM generate_series(…)]` — the C hook rewrites this to one `SELECT duckdb.raw_query('INSERT INTO ice.<ns>.<name> …')`. Source-table refs get prefixed with `pglocal.<schema>.<table>` so DuckDB's postgres extension streams the source via libpq into the Iceberg writer | Single Iceberg snapshot per INSERT, regardless of row count |
| UPDATE | `UPDATE <view> SET … WHERE …` — hook → `SELECT duckdb.raw_query('UPDATE ice.<ns>.<name> SET ... WHERE ...')` | Iceberg merge-on-read |
| DELETE | `DELETE FROM <view> WHERE …` — hook → `SELECT duckdb.raw_query('DELETE FROM ice.<ns>.<name> WHERE ...')` | Iceberg position-delete files |
| SELECT (function-call form) | `SELECT … FROM iceberg_scan('ice.<ns>.<name>') r WHERE r['col'] = …` | Columns must use `r['col']` accessor |
| SELECT (raw-query form) | `SELECT duckdb.raw_query('SELECT ... FROM ice.<ns>.<name> WHERE ...')` | Returns scalar/text result via pg_duckdb's NOTICE channel |
| ROLLBACK of writes | `BEGIN; raw_query(...); ROLLBACK;` | pg_duckdb's `XactCallback` ties DuckDB↔PG tx, so ROLLBACK undoes pending Iceberg writes |
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

The supported column types are exactly the set that already
round-trips cleanly between PG and Iceberg in the existing tiered mode
(see `pgFormatTypeToDuckDB` in
[cmd/archiver/main.go](https://github.com/pgEdge/ColdFront/blob/main/cmd/archiver/main.go)). Anything outside this
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
rejected rather than silently downgraded, because data that appears
stored but changes shape on read is worse than no support.

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
3. `CREATE OR REPLACE VIEW <schema>.<name> AS SELECT r['col']::pg_type AS col, … FROM duckdb.query('SELECT * FROM ice.default.<name>') AS t(r)` — projection wraps the struct accessor so applications see flat columns. View-cast types (`jsonb` → `json`, `interval`) are surfaced via the appropriate cast. The view reads via `duckdb.query()` so read-your-own-write inside an explicit transaction works; pg_duckdb's planner folds it into the same `ICEBERG_SCAN` plan with identical Parquet predicate pushdown, so there's no perf cost.
4. Registers the row in `coldfront.tiered_views` with `is_iceberg_only = true`. The C-side `post_parse_analyze_hook` reads this flag and short-circuits `classify_tier()` to `TIER_COLD` for any INSERT/UPDATE/DELETE on the wrapper view, regardless of WHERE clause or watermark — so every write rewrites cleanly into a single `SELECT duckdb.raw_query('INSERT/UPDATE/DELETE ice.default.<name> …')`. No INSTEAD OF INSERT trigger is created — the hook is the dispatch path.

Write semantics through the wrapper view:

- INSERT → row appears in Iceberg, fresh-session SELECT sees it.
- UPDATE → row updates in Iceberg, fresh-session SELECT sees the new value.
- DELETE → row removed from Iceberg.
- ROLLBACK of an INSERT/UPDATE inside `BEGIN` undoes the Iceberg snapshot; post-tx count matches pre-tx count.
- jsonb column round-trips through Parquet `VARCHAR` storage and surfaces as PG `json` via the wrapper view's cast (`data->>'k'` works).

Limits the helper inherits from the platform:

- **No partition spec at CREATE.** `p_partition_cols` is accepted as a parameter but currently ignored — pg_duckdb and duckdb-iceberg do not expose Iceberg partition specs at CREATE TABLE time. Predicate pushdown still works via Parquet row-group statistics.
- **Mixed-write guard relaxed.** The helper sets `duckdb.unsafe_allow_mixed_transactions = on` LOCAL during provisioning (Iceberg DDL + coldfront registry row both happen). The hook does the same for each rewritten DML so PG-side parse-analyze + DuckDB-side raw_query coexist in one tx. ROLLBACK still works via XactCallback; the flag only bypasses the pre-commit guard.

The helper doesn't add capability over raw_query — it composes the existing primitives into a single call so applications get a normal-looking PG table.

## ACID model

(Summarises material from [architecture.md](architecture.md) §Concurrency
and §Known Limitations applied to the decoupled scenario.)

| Property | Status |
|---|---|
| Atomicity (single statement) | **Yes.** One `duckdb.raw_query('INSERT/UPDATE/DELETE …')` is one DuckDB transaction → one Iceberg snapshot commit. |
| Atomicity (multi-statement tx, graceful) | **Yes.** pg_duckdb's `XactCallback` ties the DuckDB transaction to PG's, so PG `ROLLBACK` undoes pending Iceberg writes. |
| Atomicity (multi-statement tx, backend crash) | **Partial.** A backend crash between Iceberg snapshot commit and PG commit can leave S3 objects orphaned. Iceberg housekeeping (orphan-file expiry) reclaims them; not corrupting, but a real failure mode for very-strict ACID requirements. |
| Consistency | **Yes** within a snapshot — Iceberg's serializable model + Lakekeeper optimistic concurrency. |
| Isolation | **Read-your-own-write within a tx works** when the wrapper view uses `duckdb.query('SELECT * FROM ice.…')` as its read path (the helper does this by default). The plain `iceberg_scan('ice.…')` form is *not* tx-aware (it re-resolves the table from Lakekeeper each call), but pg_duckdb's planner folds `duckdb.query('SELECT * FROM ice.…')` into the same `ICEBERG_SCAN` plan with identical predicate pushdown, so we get tx visibility for free. Cross-call snapshot consistency is weaker than PG-native (see Limitations). |
| Durability | **Yes** — Iceberg commits are durable on the object store once Lakekeeper acknowledges. Stronger than PG WAL on local disk for many production setups. |

## Concurrency / horizontal scaling — the bakery protocol

Decoupled mode makes the data layer fully shared between any number of
PG nodes pointing at the same Lakekeeper endpoint and S3 bucket.

- **Reads scale out trivially.** Each PG node hits Lakekeeper + S3
  independently. New nodes spin up in seconds; no data sync.

- **Writes are serialized PG-side by the bakery protocol** so they
  never collide at Lakekeeper. The implementation is Lamport's 1978
  distributed mutual exclusion with the Ricart-Agrawala (1981)
  deferred-reply optimisation. Claims and acks travel as Spock-replicated
  rows (the two repset tables below); a writer commits only when it holds
  the minimum outstanding ticket and every live peer has acked (a peer
  defers its ack while it holds a smaller ticket). This stays safe under
  Spock's *asymmetric* apply — each node applies peers' rows on its own
  independent queue, so it never assumes a peer has applied its concurrent
  claim; the snowflake-ticket total order and the ack barrier serialize
  commits, not any global apply ordering. Modelled in
  [docs/formal/Bakery_v2.tla](https://github.com/pgEdge/ColdFront/blob/main/docs/formal/Bakery_v2.tla); the safety
  properties are verified via TLA+ (`Bakery_v2.cfg`).

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
  [extension/coldfront/src/coldfront.c](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/src/coldfront.c).

  The mechanics live in [extension/coldfront/coldfront--0.1.sql](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--0.1.sql)
  (`_claim_iceberg_lock`, `_release_iceberg_lock`,
  `_on_claim_apply`, `_on_claim_release`, `_exec_iceberg_with_claim`)
  and the C-side rewrite in [extension/coldfront/src/coldfront.c](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/src/coldfront.c)
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

The commit-rate ceiling sits at Lakekeeper, not at the PG side, so
scale throughput with larger per-INSERT batches or by partitioning the
Iceberg table.

### Required configuration on every PG node

```ini
# postgresql.conf — server-wide
wal_level = logical
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'

# Keeps pg_stat_replication.reply_time fresh for the bakery's dead-peer
# liveness check (PG default 10s would false-positive idle peers as dead).
wal_receiver_status_interval = 1s

# Sync-rep is NOT required by the bakery — R-A's ack barrier replaces it.
```

```ini
# postgresql.conf — per-node. snowflake.node MUST equal
# (hashtext(<spock node_name>) & 1023) or the bakery raises at first claim:
# it maps each ticket back to a spock node_name via the same hash for
# dead-peer detection.
snowflake.node = 1     # node1
# snowflake.node = 2   # node2
# snowflake.node = 3   # node3

# DSN for the bakery's autonomous-tx claim/ack dblink calls (unix socket).
coldfront.dblink_self = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_dblink'

# Optional — peer-liveness window for R-A's dead-peer escape; a peer
# whose reply_time is older than this is treated as already-acked.
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
writer — every claim ack-waits to timeout.

`coldfront.create_iceberg_table()` calls `_ensure_claims_replicated()`
on the node it runs on, but that only registers the repset on *that*
node. Peers receive the wrapper-view DDL via Spock's `ddl_sql` repset
but do *not* re-run the helper — so the explicit per-node call above
is mandatory in any multi-node setup.

## When to use decoupled vs tiered

**Decoupled (iceberg-only) is the right choice when:**

- The application's read path is dominated by analytic OLAP queries
  (cold-tier analytic reads run substantially faster than PG heap
  on shape-matched workloads).
- Operational simplicity outweighs ergonomics: no archiver cron, no
  watermark, no autovacuum-vs-cutover lock conflict (see
  architecture_tiered.md → Tiered-specific limitations), no PK rebuild after bulk load, no
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
