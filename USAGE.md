# Using coldfront

Two operating modes. Pick one per table; both can coexist in the same database.

| | Tiered (hot + cold) | Decoupled (iceberg-only) |
|---|---|---|
| **Where rows live** | Hot in PG heap (recent), cold in Iceberg (archived) | Everything in Iceberg |
| **Setup** | Create a partitioned table; let the archiver convert it on first run | One SQL call: `coldfront.create_iceberg_table(...)` |
| **Archiver** | Required (cron, moves old partitions to cold) | Not used |
| **Best when** | Workload has a recent-row OLTP part that benefits from PG indexes + transactional ergonomics | Pure analytic / append-mostly; you want zero PG storage and stateless compute |

Once the table exists, **the SQL surface is identical**: `SELECT`, `INSERT`, `UPDATE`, `DELETE` all work normally against the relation name (e.g. `events`).

## Prerequisites (both modes)

The stack must already be running with PG + pg_duckdb + coldfront + Lakekeeper + S3-compatible storage. See [README.md → Infrastructure](README.md#infrastructure) for the docker-compose recipe and one-time bootstrap (`bootstrap`, `warehouse`, `arm_login_attach`).

## Mode 1 — Tiered (hot + cold)

Create a partitioned table normally:

```sql
CREATE TABLE events (
    id     bigint GENERATED ALWAYS AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text,
    data   jsonb,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

CREATE TABLE p_2026_04 PARTITION OF events
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
```

List it in the archiver config:

```yaml
# config.yaml
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      retention_period: 1 month
```

Run the archiver (typically via cron):

```bash
./bin/archiver --config config.yaml
```

The first run renames `events` → `_events`, creates the unified view `events`, and registers it. From then on every cycle moves expired partitions hot → cold and updates the watermark.

## Mode 2 — Decoupled (iceberg-only)

Single call:

```sql
SELECT coldfront.create_iceberg_table(
    p_schema  => 'public',
    p_table   => 'events',
    p_columns => '[
      {"name":"id",     "type":"bigint"},
      {"name":"ts",     "type":"timestamptz"},
      {"name":"status", "type":"text"},
      {"name":"data",   "type":"jsonb"}
    ]'::jsonb
);
```

That single statement provisions:
- `ice.default.events` on the attached Iceberg catalog
- a PG-side wrapper view `public.events` with proper PG-typed columns
- a `coldfront.tiered_views` registry row — every INSERT, UPDATE, and DELETE on the view is intercepted by the coldfront C hook and rewritten to a single `duckdb.raw_query(...)` against `ice.default.events`

Spock's `ddl_sql` repset replicates the `CREATE VIEW` and the registry row, so the helper only needs to run on one node — peers pick up the wrapper view, the `coldfront.tiered_views` row, and the `coldfront.claims` repset registration automatically.

## Reading + writing (identical for both modes)

```sql
-- Reads — pg_duckdb handles the iceberg side; PG handles the heap side
SELECT count(*) FROM events;
SELECT id, status, data->>'k' FROM events WHERE ts >= '2026-04-01';

-- Inserts, updates, and deletes all go through the coldfront C hook,
-- which rewrites the query into one PG-set-based statement (hot side)
-- + one duckdb.raw_query (cold side). For iceberg-only mode every write
-- goes cold; for tiered mode the hook splits by ts vs the watermark.
INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{"k":1}');
UPDATE events SET status = 'fixed' WHERE id = 123;
DELETE FROM events WHERE ts < '2025-01-01';

-- Bulk INSERT shapes are all set-based — no per-row work:
INSERT INTO events (ts, status, data) VALUES (...), (...), (...);
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM staging;
INSERT INTO events (ts, status, data) SELECT now() + i*'1s'::interval, 'ok', '{}'
                                       FROM generate_series(1, 1000) i;

-- Transactions work; ROLLBACK undoes Iceberg writes too
BEGIN;
  UPDATE events SET status = 'pending' WHERE id = 1;
  SELECT status FROM events WHERE id = 1;   -- sees 'pending' (read-your-own-write)
ROLLBACK;
SELECT status FROM events WHERE id = 1;     -- back to whatever it was
```

## Supported column types

`bigint` · `integer` · `smallint` · `real` · `double precision` · `boolean` · `timestamp with time zone` · `timestamp without time zone` · `date` · `time without time zone` · `uuid` · `text` · `varchar(N)` · `char(N)` · `bytea` · `oid` · `numeric(P,S)` (P ≤ 38) · `jsonb` / `json` · `interval`

Anything else (unbounded `numeric`, `xml`, `tsvector`, range/multirange types, custom enums, arrays, composite types) is rejected at table-creation time. We refuse silent fallback to `varchar` — losing precision/identity is worse than no support.

`jsonb`, `json` and `interval` are stored as `varchar` in Iceberg (no native primitive) and view-cast back to the rich PG type on read. Queries like `data->>'key'` work; jsonb-only operators (`?`, `@>`) need an explicit `data::jsonb` cast.

`inet`/`cidr` are **not supported**: pg_duckdb cannot process PG `inet` (Oid 869) in any Iceberg-backed query, and every cross-tier read is planned by pg_duckdb — so no cast makes them readable. Store IP data as `text` (you can still index/compare it; cast to `inet` in your own queries on the hot side only if needed).

## Gotchas

- **`jsonb` reads**: surface as `json`, not `jsonb`. Most operators work; the binary-only ones don't.
- **Cross-tier isolation**: a long-running `SELECT` that touches the Iceberg side multiple times within one transaction may see writes from other sessions interleaved between scans. PG's repeatable-read does not extend across the pg_duckdb boundary. Read-your-own-write *within* one tx works (verified) — it's only cross-statement consistency vs. concurrent writers that's weaker.
- **Crash-mid-commit (decoupled mode)**: if a backend crashes between Iceberg snapshot commit and PG commit, S3 objects can be orphaned. Iceberg housekeeping reclaims them — not corrupting, but a real failure mode.
- **Concurrent writes from multiple PG nodes (decoupled mode)**: serialized PG-side by the bakery protocol — every iceberg-only INSERT goes through `coldfront._exec_iceberg_with_claim`, which holds a globally-ordered snowflake ticket and waits for its turn before committing to Lakekeeper. No 409 conflicts, no app-level retry. The protocol is Lamport-1978 mutex with the Ricart–Agrawala (1981) deferred-reply optimisation over Spock's per-origin FIFO apply (modelled in [docs/formal/Bakery_v2.tla](docs/formal/Bakery_v2.tla)). The bakery requires the `dblink` + `snowflake` extensions, the `coldfront.dblink_self` GUC, and a one-time `SELECT coldfront._ensure_claims_replicated()` call on every node after spock mesh setup; see [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md#concurrency--horizontal-scaling--the-bakery-protocol). Sync-rep is **not** required. The throughput ceiling is Lakekeeper's commit rate, not the writer count.
- **Direct table access**: `_events` is the hot heap (tiered mode only). `ice.default.<name>` is the Iceberg table — only addressable via `iceberg_scan(...)` or `duckdb.raw_query('… ice.… …')`, never via PG-native 3-part names.
- **Tiered INSERT with omitted IDENTITY column** (e.g. `INSERT INTO events (ts, status, data) VALUES …` where `id` is `GENERATED ALWAYS AS IDENTITY`): the cold side falls back to a plpgsql cursor loop that calls `nextval()` per row so cold ids share the hot side's sequence. Correctness is full; throughput is lower than the set-based fast path. Either supply `id` explicitly in the INSERT, or use a partition-column predicate that proves the rows are all hot, to stay on the fast path. For very large historical seeds (mostly-cold), prefer iceberg-only mode where ids come from your source data.

## Distributed setup (3-node mesh, decoupled mode)

For multi-writer iceberg workloads, run coldfront on N PG nodes in a Spock mesh against the same Lakekeeper + S3. The bakery serializes commits PG-side so writers never collide at the catalog.

**Per-node `postgresql.conf`:**

```ini
wal_level = logical
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'

# Keep pg_stat_replication.reply_time fresh on every walsender.  PG
# default is 10 s; with the bakery's 5 s liveness window that would
# false-positive every idle peer as "dead" on the first claim after a
# quiet period.  1 s leaves comfortable margin.
wal_receiver_status_interval = 1s

# Per-node — distinct integer 1..1023.  MUST equal
# (hashtext(<spock node_name>) & 1023); the bakery alignment check raises
# at first claim if these disagree.
snowflake.node = 1

# DSN used by the bakery's autonomous-tx claim INSERT/DELETE via dblink.
# Unix socket avoids TCP overhead; `event_triggers=off` bypasses the
# coldfront LOGIN event trigger so the dblink session never enters DuckDB
# territory (saves ~100ms per claim, avoids a libpq linker recursion).
# application_name=coldfront_dblink is a marker the trigger checks.
coldfront.dblink_self = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_dblink options=-cevent_triggers=off'

coldfront.warehouse = 'wh'
coldfront.lakekeeper_endpoint = 'http://lakekeeper:8181/catalog'
```

The bakery has no peer-ack timeout. R-A's only failure mode is a
dead peer (would wait forever), closed by a liveness check inside
the wait-loop: a peer whose `pg_stat_replication.reply_time` is
older than `coldfront.peer_alive_window_ms` (default `5000`) is
implicitly treated as already-acked. Raise this on slow/lossy WAN
links if false-positive dead-peer rulings become a problem. An
alive peer that hasn't acked is either deferring legitimately
(R-A's defer rule) or about to ack — either way, waiting is
correct, not a failure.

Sync-rep (`synchronous_standby_names`) is **not required** by the bakery —
the R-A ack barrier replaces it. You can still enable it cluster-wide if
you want stronger durability for non-bakery writes, but it's no longer
load-bearing for iceberg-commit serialisation.

**One-time mesh setup** — must be done in this order on every node,
because `coldfront._ensure_claims_replicated()` calls `spock.repset_add_table`
and so requires the local spock node to already exist:

```sql
-- 1. Extensions, in dependency order. dblink + snowflake are bakery
-- prereqs (R-A's autonomous-tx claim/ack INSERTs go through dblink;
-- claim tickets come from snowflake.nextval).
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS snowflake;
CREATE EXTENSION IF NOT EXISTS spock;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- 2. Spock node + full-mesh subscriptions (each node has N-1 subs).
SELECT spock.node_create('n<i>', 'host=<this_node_priv_ip> user=coldfront dbname=coldfront port=5432');

-- on n1 (n2 and n3 symmetric):
SELECT spock.sub_create('sub_n1_from_n2', 'host=<n2> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);
SELECT spock.sub_create('sub_n1_from_n3', 'host=<n3> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);

-- 3. **Required** on every node, after spock setup: register the R-A
-- bakery tables (coldfront.claims + coldfront.claim_acks) in the local
-- node's default repset.  Without this on a peer, the peer's ack INSERTs
-- never replicate back to the originating writer and every claim
-- ack-waits to timeout.
SELECT coldfront._ensure_claims_replicated();
```

`synchronize_structure := false, synchronize_data := false` — tables already exist on every node from the coldfront extension; no initial copy needed.

**Verify before benching** — insert a sentinel claim on each node and read it back from every other node. All N×(N-1) directions must show the row before traffic starts. `run-ci-distributed.sh` step 12b is a copyable reference.

## Tuning knobs

- `coldfront.allow_mixed_writes` (bool, default `on`) — controls what happens for tiered-mode UPDATE/DELETE whose WHERE can't be proven to target one tier. `on` emits a dual-tier CTE; `off` rejects with an error and a hint. Not relevant in decoupled mode (every write is single-tier by definition).
- `duckdb.force_execution` — bench it before flipping. See [bench.md](bench.md): on a mixed workload it helps `count(distinct)` and similar but regresses index lookups, top-K with PK ordering, and JSON access by 2× to 80,000×. **Default off.**

## Going deeper

- Tiered architecture, watermark, archiver, transparent UPDATE/DELETE, concurrency: [ARCHITECTURE.md](ARCHITECTURE.md).
- Decoupled mode internals, ACID model, distributed scaling: [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md).
- Benchmark numbers (hot heap vs Iceberg/DuckDB at matched 250 M rows): [bench.md](bench.md).
