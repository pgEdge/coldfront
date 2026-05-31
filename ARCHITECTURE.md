# pgEdge ColdFront — Architecture

ColdFront makes a single PostgreSQL table transparently span two storage
tiers: recent rows stay in the PostgreSQL heap, older rows live in Apache
Iceberg on object storage. Applications see one table (in fact a view); a C
extension rewrites reads and writes to hit the right tier, and **all Iceberg
I/O goes through `pg_duckdb` running in-process inside PostgreSQL** — no
external query engine, no Go Iceberg libraries.

## Contents

- [Operating modes and topologies](#operating-modes-and-topologies) — the three axes of a deployment
- [System Overview](#system-overview) — the moving parts
- [Core Mechanics: pg_duckdb](#core-mechanics-pg_duckdb) — how Iceberg I/O happens
- [Application Interface](#application-interface) — the shared rewrite hook
- [Concurrency and pgEdge Spock Deployments](#concurrency-and-pgedge-spock-deployments) — bakery, cold-write strategy, DDL, OID-vs-name
- [Known Limitations](#known-limitations) — cross-cutting
- [Infrastructure (Docker)](#infrastructure-docker)
- [Upstream Requests](#upstream-requests) — open asks to pg_duckdb / duckdb-iceberg

**Mode-specific design:** [ARCHITECTURE_TIERED.md](ARCHITECTURE_TIERED.md) (hot PG + cold Iceberg) · [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md) (all-Iceberg)

## Operating modes and topologies

Three independent axes describe any ColdFront deployment. They compose
freely — e.g. tiered + mesh + permissive writes:

| Axis | Values | Selected by |
|---|---|---|
| **Storage mode** | **Tiered** — hot PG heap + cold Iceberg, unified by a `UNION ALL` view; an archiver moves rows hot→cold on a cron. · **Decoupled** — the table lives entirely in Iceberg; PG holds only a wrapper view + `INSTEAD OF` trigger + a registry row (no archiver, no PG storage, no watermark). | Per relation at creation, via the `is_iceberg_only` flag on `coldfront.tiered_views` (short-circuited in the hook's `classify_tier()`). |
| **Topology** | **Vanilla** — single node; `spock`/`snowflake` not loaded; cold writes serialise on a local advisory lock. · **Mesh** — 3-node pgEdge Spock active-active; cold writes serialise cluster-wide via the bakery protocol. | Whether `spock`/`snowflake` are in `shared_preload_libraries`. One image and one SQL surface serve both; the `_exec_iceberg_with_claim` chokepoint self-selects via its `v_armed` gate. |
| **Write mode** | **Permissive** (default) — an ambiguous cross-tier `UPDATE`/`DELETE` writes both tiers. · **Strict** — it is rejected with a hint. | `coldfront.allow_mixed_writes` (USERSET). |

Both storage modes coexist in one database and share **one** code path: the
transparent view and read rewriter, the INSERT/UPDATE/DELETE hook
(`emit_cold` / `emit_hot` / `emit_dual_cte` in
[`extension/coldfront/src/coldfront.c`](extension/coldfront/src/coldfront.c)),
and the `_exec_iceberg_with_claim` write chokepoint. Decoupled mode simply
always classifies as `TIER_COLD` and never reaches `emit_hot`; vanilla and
mesh differ only in how that chokepoint serialises cold writes. This
document covers the shared mechanics and the tiered path; see
[ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md) for the decoupled
mode's ACID model and distributed scaling story.

## System Overview

A ColdFront database is PostgreSQL with two extensions preloaded
(`pg_duckdb` + `coldfront`), backed by an Iceberg REST catalog and an
object store:

```
┌──────────────────────────────────────────────────────────┐
│  PostgreSQL + pg_duckdb + coldfront                        │
│  • one transparent view per managed table                  │
│  • coldfront hooks: post_parse_analyze (DML rewrite),      │
│    ProcessUtility (DDL), LOGIN (Iceberg auto-attach)       │
│  • coldfront.tiered_views registry + bakery claims         │
│  • pg_duckdb runs DuckDB in-process:                       │
│      iceberg_scan() reads cold data, duckdb.raw_query()    │
│      writes it                                             │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│  Lakekeeper — Iceberg REST catalog (own dedicated Postgres)│
│  Manages Iceberg metadata, snapshots, commit concurrency   │
└──────────────┬───────────────────────────────────────────┘
               │
┌──────────────▼───────────────────────────────────────────┐
│  S3-compatible object store (AWS S3, SeaweedFS, MinIO, …)  │
│  Parquet data files + Iceberg metadata files               │
└────────────────────────────────────────────────────────────┘
```

| Component | Role | License |
|-----------|------|---------|
| PostgreSQL 16+ | Heap storage; range partitioning for the tiered hot tier | PostgreSQL |
| pg_duckdb | DuckDB in-process. Iceberg read + write. Analytics. Stock upstream `pgduckdb/pgduckdb:18-v1.1.1` (no fork). The bundled `duckdb-iceberg` carries one optional mesh-performance patch — async parquet overlap; see [Cold-write strategy](#cold-write-strategy-stock-vs-patched-duckdb-iceberg). | MIT |
| coldfront | PGXS C extension. `post_parse_analyze_hook` rewrites INSERT/UPDATE/DELETE on registered views to the correct tier; `ProcessUtility_hook` handles DDL; a LOGIN trigger auto-attaches Iceberg. | PostgreSQL |
| Lakekeeper | Iceberg REST catalog. Single Rust binary. | Apache 2.0 |
| S3-compatible store | Any: AWS S3, SeaweedFS, MinIO, GCS, Azure Blob, etc. | Varies |
| Archiver (tiered mode) | Go binary, invoked by cron. Thin SQL orchestrator that moves rows hot→cold. | PostgreSQL |

How rows move through this depends on the storage mode: the tiered hot heap +
archiver + `UNION ALL` data-flow is in
[ARCHITECTURE_TIERED.md → Data flow](ARCHITECTURE_TIERED.md#data-flow); the
all-Iceberg flow is in
[ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md).

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

## Application Interface

Applications use the transparent view exactly like a table. A
`post_parse_analyze_hook` in the coldfront extension intercepts
INSERT/UPDATE/DELETE whose target is a registered relation — resolved in
`coldfront.tiered_views` by OID — and rewrites the parsed `Query` so it lands
in the correct tier; cold-side writes funnel through the
`_exec_iceberg_with_claim` chokepoint (see
[Concurrency](#concurrency-and-pgedge-spock-deployments)). A
`ProcessUtility_hook` handles DDL on the same relations.

| Operation | Interface | Routed via |
|---|---|---|
| SELECT | `SELECT FROM events` | pg_duckdb (UNION ALL in tiered, wrapper view in decoupled) |
| INSERT | `INSERT INTO events ...` | coldfront `post_parse_analyze_hook` |
| UPDATE / DELETE | `... events WHERE ...` | coldfront `post_parse_analyze_hook` |
| DDL (ALTER / RENAME) | `ALTER TABLE _events ...` | coldfront `ProcessUtility_hook` (see [Transparent DDL](#transparent-ddl-via-coldfront)) |
| DROP / TRUNCATE | `DROP TABLE _events` | blocked by the hook (see [Transparent DDL](#transparent-ddl-via-coldfront)) |

With `duckdb.force_execution = true`, hot-side queries are also accelerated
by DuckDB's vectorized columnar engine.

How the hook splits a write is mode-specific:

- **Tiered** routes by the partition-column watermark — hot heap vs cold
  Iceberg, with dual-tier writes for ambiguous predicates. See
  [ARCHITECTURE_TIERED.md → Transparent INSERT](ARCHITECTURE_TIERED.md#transparent-insert)
  and [→ UPDATE/DELETE](ARCHITECTURE_TIERED.md#transparent-updatedelete).
- **Decoupled** always classifies `TIER_COLD`: every write is a single-tier
  Iceberg write. See [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md).

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

### Cold-write strategy: stock vs patched duckdb-iceberg

Every cold write runs through the same `_exec_iceberg_with_claim`
chokepoint, which **never returns a 409** to the application regardless of
the duckdb-iceberg binary. What differs is *when* the bakery ticket is
held, selected by `coldfront.iceberg_async_parquet` (default `off`):

| `iceberg_async_parquet` | duckdb-iceberg | Behaviour |
|---|---|---|
| `off` (default) | **stock** upstream | Claim-first: take the bakery ticket, *then* upload parquet **and** commit inside the ticket. Correct on an unpatched binary, but the whole parquet upload happens under the lock, so concurrent writers serialise on upload + commit. |
| `on` | **patched** (`iceberg-bakery-aware-commit-refresh.patch`) | Overlap: upload parquet in the background *first*, then take the ticket only for the Lakekeeper commit. Concurrent writers' uploads overlap; only the short commit POST is serialised. |

The code path is identical and the application-visible behaviour is
identical — one transactional write, no 409, no app-level retry — so the
GUC is purely a performance knob. The patch is needed only because stock
duckdb-iceberg stamps the parent snapshot id at *upload* time; overlapping
uploads would then commit a stale parent. The patch relocates that stamping
into PG's pre-commit phase (inside the bakery ticket, against a
freshly-fetched table), making the upload safe to overlap. The Docker image
ships the patched binary with `iceberg_async_parquet = on`; bare-metal users
on a stock binary leave it `off` and lose only the upload overlap. See
[PATCHED.md](PATCHED.md) and [UNPATCHED.md](UNPATCHED.md) for the build and
the full rationale.

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

**Active-active.** Schema changes propagate as DDL, not as registry rows.
Spock 5.0.8 replicates the top-level `ALTER TABLE` (the hook's SPI-issued
view-rebuild DDL runs at non-top-level context, which Spock's
`autoddl_can_proceed()` filters out). A peer applies the replicated
`ALTER TABLE` with `IsLogicalWorker() == true`; the hook then rebuilds
**that peer's own** local view and re-points **that peer's own** registry
row, but skips the Iceberg mirror (the originator already wrote the shared
Lakekeeper catalog). Because each node re-points its own row, the registry
is **resolved per-node**: every `coldfront.tiered_views` row carries that
node's *local* view OID, so the OID-keyed hook is correct whether OIDs match
across nodes (lockstep creation) or diverge (local recreation). DROP and
TRUNCATE are blocked on every node. What a tiered table additionally needs
to be usable on a peer is covered next.

The tiered-specific cross-node behaviour — what replicates so a tiered table
is usable on every peer, and why both the registry and the watermark join the
replication set — is in
[ARCHITECTURE_TIERED.md → Tiered tables in a Spock mesh](ARCHITECTURE_TIERED.md#tiered-tables-in-a-spock-mesh).

### Why OID-keyed (and when names are better)

`coldfront.tiered_views` is keyed by `view_oid oid`, and the hook resolves
the registry with `WHERE view_oid = <relid>` on every parsed statement that
targets a candidate relation. OID was chosen because:

- **The hook already holds the OID, not a name.** `post_parse_analyze_hook`
  receives the target relation as a `relid`; an integer-equality probe with
  no name resolution is cheap on the hot path of every query.
- **It is rename-stable.** `ALTER ... RENAME` changes a relation's name but
  not its OID, so a rename cannot silently orphan the registry entry.
- **It is unambiguous within a node** — no schema-qualification or
  `search_path` ambiguity to resolve.

The cost surfaces only in a Spock mesh: an OID is **local to a node**, so
the registry cannot simply be copied between nodes by value, and the design
leans on each node re-registering its own view (above). The watermark
sidesteps this by keying on `table_name` — and that is the template for the
recommended hardening: **key the registry on `schema.relname` as well**,
resolving to an OID only at the point the hook needs one. Names are stable
across nodes, so a name-keyed registry would replicate by value with no
per-node OID dependence and would survive divergent active-active DDL. The
watermark already proves the pattern; moving `tiered_views` to a name key is
the clean end state for multi-node robustness.

## Known Limitations

These apply to both storage modes. Tiered-only limitations (cold RETURNING,
dual-tier command tag, crash-safety of permissive writes, partition-scheme
constraints, the empty cold-tier partition spec, autovacuum-vs-cutover) are in
[ARCHITECTURE_TIERED.md → Tiered-specific limitations](ARCHITECTURE_TIERED.md#tiered-specific-limitations).

1. **One-time arming after warehouse bootstrap** — the LOGIN event trigger
   that auto-attaches Iceberg per session is gated on
   `coldfront.runtime_config.attach_on_login` (default `false`). An operator
   must call `SELECT coldfront.arm_login_attach()` once per database after
   Lakekeeper is provisioned. This is a deliberate opt-in so pre-bootstrap
   connections can't be blocked by a missing warehouse; once armed every
   subsequent session auto-attaches without boilerplate.

2. **`jsonb` surfaces as `json` through the view** — DuckDB has no
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

3. **S3 compatibility** — Lakekeeper remote signing may not work with all
   S3-compatible stores. Workaround: `ACCESS_DELEGATION_MODE NONE` with
   direct DuckDB S3 secret.

4. **Planner-level interception, no per-query decision engine** —
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

5. **Single-node query execution** — a query runs on the PG backend
   it landed on.  `pg_duckdb` does not distribute the DuckDB plan
   across nodes.  Replication (single- or multi-master via pgEdge
   Spock) is supported on the hot tier and transparent to the
   application; scaling read throughput requires more replicas
   rather than parallelising one query.

6. **Iceberg only** — no Delta Lake support.  Adding Delta would
   require either a second writer path in `pg_duckdb`'s Iceberg
   extension or a different analytical engine.

## Infrastructure (Docker)

Three services: PG+pg_duckdb+coldfront, Lakekeeper, and any
S3-compatible store.  Both extensions must be in
`shared_preload_libraries` — `coldfront` installs its hook in
`_PG_init`, which fires at backend start.

One parameterized image (`docker/Dockerfile`, `--build-arg PG_MAJOR=16|17|18`)
serves every deployment: a pgEdge `*-spock5-minimal` base (bundles Spock +
Snowflake) with pg_duckdb v1.1.1 compiled on top and coldfront installed. The
same image plays both topology roles — vanilla leaves spock/snowflake out of
`shared_preload_libraries`; mesh loads them (`MESH=on`, set by the entrypoint).

```yaml
services:
  db:
    build:
      context: .
      dockerfile: docker/Dockerfile
      args: { PG_MAJOR: 18 }
    environment: { PG_MAJOR: 18, MESH: "off" }   # entrypoint configures preload + GUCs
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

**Lakekeeper's metadata store.** Lakekeeper keeps its own catalog tables in a
PostgreSQL database (and its schema migration needs the `uuid-ossp` contrib
extension). It runs on its **own dedicated Postgres** — a separate
`lakekeeper-db` container in the test stack, and a separate managed instance in
production — **never co-located on a ColdFront data node.** Co-locating would
couple the catalog's availability and load to a data node and would drag
contrib into the ColdFront image for no reason; the dedicated store keeps the
ColdFront image lean (core `uuid` type only, no uuid-ossp).

## Upstream Requests

Behaviours in upstream projects that ColdFront works around, kept as
architectural notes: the gap, the workaround in use today, and the shape of
the upstream capability that would let us drop the workaround.

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

**Desired end-state.** A way to drive the native in-process reader straight
into the Iceberg writer — e.g. a `COPY` form:

```sql
COPY (SELECT * FROM public.events_partition) TO ICEBERG 'ice.default.events';
```

That would make pg_duckdb the only place in the data path that touches the
rows: PG executor (heap reader) → pg_duckdb vector format → Iceberg writer,
**one pass, in-process**, with no libpq loopback and no temp-disk. The
`pglocal` ATTACH path covers the streaming case adequately at our sizes; the
in-process path would only shave off the libpq overhead.

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

**Desired end-state.** Either `IRCTransaction::Commit` runs its commit-time
I/O under the caller's `ClientContext` (rather than a freshly-opened
Connection), or any extension that synthesises `CREATE SECRET` from external
state commits that transaction explicitly, so the secret sits at a committed
timestamp before a consumer's fresh transaction looks it up. Either obviates
the LOGIN-trigger warmup; the warmup costs ~1 ms per session and is invisible
to applications.

### duckdb-iceberg: INSERT into a table with a partition spec

**Workaround today.** None. Iceberg tables created by coldfront have an
empty partition spec; cold-tier pruning relies on per-file manifest
min/max stats. See
[ARCHITECTURE_TIERED.md → Tiered-specific limitations](ARCHITECTURE_TIERED.md#tiered-specific-limitations).

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

**Desired end-state.** INSERT/MERGE into a partitioned Iceberg table —
DuckDB writes data files into the appropriate partition directories based on
the catalog's current spec, with no new SQL surface (existing
`INSERT INTO ice.x VALUES ...` would route rows through the partition
transform). Until then the spec stays empty and pruning relies on manifest
statistics.

