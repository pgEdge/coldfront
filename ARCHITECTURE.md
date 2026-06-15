# pgEdge ColdFront — Architecture

ColdFront makes a single PostgreSQL table transparently span two storage
tiers: recent rows stay in the PostgreSQL heap, older rows live in Apache
Iceberg on object storage. Applications see one table (in fact a view); a C
extension rewrites reads and writes to hit the right tier, and **all Iceberg
I/O goes through `pg_duckdb` running in-process inside PostgreSQL** — no
external query engine, no Go Iceberg libraries.

## Contents

- [Operating modes and topologies](#operating-modes-and-topologies) — the three axes + read target (primary / standby)
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

### Read target: primary or physical standby

Orthogonal to the three axes above, any ColdFront node — vanilla or a mesh
member — can have one or more **physical (streaming) standbys that serve
read-only cross-tier reads**. The hot tier arrives by physical replication; the
cold tier is read by `iceberg_scan` executing on the read-only backend. A base
backup carries everything a replica needs — the coldfront catalog
(`tiered_views`, `archive_watermark`, `storage_secret`), the DuckDB persistent
S3 secret (loaded at instance init), and the GUCs (in `postgresql.conf`, not
`ALTER SYSTEM`) — so a replica is byte-identical to its primary (same OIDs) with
zero extra setup. Cold **writes** are refused on a standby: every cold write funnels through
`_exec_iceberg_with_claim`, which raises when `pg_is_in_recovery()`, so a read
replica can never become an uncoordinated writer to the shared Iceberg table
(hot writes hit a PG heap and PG rejects them natively).

Standby reads are gated by [`ci/probe-standby.sh`](ci/probe-standby.sh) (the
risk-first check that `iceberg_scan` runs on a read-only backend at all) and
exercised in the journey by `story_standby_reads` (the `·standby` matrix cells).
Failover/promotion is delegated to Patroni and is out of scope for the test
matrix — see [ci/runbooks/failover-patroni.md](ci/runbooks/failover-patroni.md).

## System Overview

A ColdFront database is PostgreSQL with two extensions preloaded
(`pg_duckdb` + `coldfront`), backed by an Iceberg REST catalog and an
object store:

```
┌──────────────────────────────────────────────────────────┐
│  PostgreSQL + pg_duckdb + coldfront                        │
│  • one transparent view per managed table                  │
│  • coldfront hooks: post_parse_analyze (DML rewrite),      │
│    ProcessUtility (DDL); the C hook lazily ATTACHes the    │
│    Iceberg catalog on the first query touching a view      │
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
│  S3-compatible object store (SeaweedFS, MinIO, GCS, …)     │
│  Parquet data files + Iceberg metadata files               │
└────────────────────────────────────────────────────────────┘
```

| Component | Role | License |
|-----------|------|---------|
| PostgreSQL 16+ | Heap storage; range partitioning for the tiered hot tier. Works uniformly on PG 16, 17, and 18 — the cold-tier secret is a DuckDB persistent secret loaded at instance init, with no version-gated mechanism. | PostgreSQL |
| pg_duckdb | DuckDB in-process. Iceberg read + write. Analytics. pg_duckdb 1.5.3 (PR #1025; no released 1.5.x tag yet). The `duckdb-iceberg` carries the bakery-aware commit-refresh patch (async parquet overlap, no 409); see [Cold-write strategy](#cold-write-strategy-stock-vs-patched-duckdb-iceberg). | MIT |
| coldfront | PGXS C extension. `post_parse_analyze_hook` rewrites INSERT/UPDATE/DELETE on registered views to the correct tier; `ProcessUtility_hook` handles DDL; the hook lazily ATTACHes the Iceberg catalog on the first query touching a tiered view. | PostgreSQL |
| Lakekeeper | Iceberg REST catalog. Single Rust binary. | Apache 2.0 |
| S3-compatible store | Any: SeaweedFS, MinIO, GCS, Azure Blob, etc. | Varies |
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

**Cold-tier S3 secret** (set once per cluster). A single call records the
credentials and materializes a DuckDB persistent secret:

```sql
SELECT coldfront.set_storage_secret('<key>', '<secret>', '<endpoint>');
```

This does two things. (1) It stores the secret in the
`coldfront.storage_secret` table — an extension-member table, so its data is
excluded from `pg_dump` by default, and it is added to the Spock replication
set, so the secret replicates **by value** to every mesh node with no per-node
file syncing. (2) It materializes a DuckDB **persistent secret**, which DuckDB
loads automatically at instance init — so every backend, including the first
fresh one, sees the secret at a committed timestamp before any query runs.

**Backup / restore (`pg_dump`).** The durable tiering metadata —
`coldfront.tiered_views` (registry), `archive_watermark` (cutoffs) and
`partition_config` — is marked with `pg_extension_config_dump`, so a logical
`pg_dump` carries it and a restore re-attaches to the **same** Iceberg cold tier
with no re-provisioning. Two things are deliberately **not** dumped: the
credential (`coldfront.storage_secret` above — re-run `set_storage_secret` once
after restoring into a fresh instance) and the bakery's transient claim tables
(`claims` / `claim_acks` / `deferred_acks`, per-node mesh state). Until the
credential is re-established a restored node serves hot reads but fails cold I/O
cleanly. `ci/ops.sh` Check 4 exercises exactly this.

**Iceberg catalog ATTACH** is **lazy**: the coldfront C extension hook issues
`ATTACH IF NOT EXISTS` against Lakekeeper — using the cluster's
`coldfront.warehouse` and `coldfront.lakekeeper_endpoint` GUCs — on the **first
query that touches a tiered view** (read or write), per DuckDB cached
connection. There is no arming step and no per-session boilerplate: both reads
(`iceberg_scan`) and writes (`duckdb.raw_query`) just work on a fresh psql
session. Until a tiered view is touched no ATTACH is attempted, so a
pre-bootstrap connection is never blocked by a missing warehouse.

### Non-superuser app roles (least privilege)

pg_duckdb force-disables DuckDB's `LocalFileSystem` for non-superusers (see
[Upstream Requests](#pg_duckdb-non-superuser-localfilesystem-blocks-side-loaded-extensions)),
which would block the side-loaded iceberg/postgres DuckDB extensions from loading
on `ATTACH`. So `coldfront.ensure_attached()` / `ensure_pg_attached()` are
`SECURITY DEFINER` with a pinned `search_path`: the extension load + `ATTACH` run
elevated (gates key off `GetUserId()`, the effective user), and because the
DuckDB instance is per-backend the attach persists for the session — every
subsequent `iceberg_scan` / `_exec_iceberg_with_claim` then runs as the **app
role** over S3/httpfs, never touching `LocalFileSystem`. The app role needs only
`duckdb.postgres_role` membership + object grants; **no superuser, no
`pg_{read,write}_server_files`**.

Because the attach helpers run elevated, the deployment-config GUCs they consume
(`coldfront.warehouse`, `coldfront.lakekeeper_endpoint`, `coldfront.local_pg_dsn`)
are registered `PGC_SUSET` (the last also `GUC_SUPERUSER_ONLY`) in `_PG_init`, so
a non-superuser cannot redirect the elevated `ATTACH` at an attacker endpoint.
Onboarding is one operator call, `coldfront.grant_app_access(role)` — idempotent,
registry-derived (schemas, views, the hot heap + its identity sequence, the
cold-path function EXECUTE allow-list), not `PUBLIC`-executable. The image defaults
`duckdb.postgres_role = coldfront_duckdb` (env `COLDFRONT_DUCKDB_ROLE`) and creates
the role, so the path is turnkey.

In a **Spock mesh** the role and its grants replicate via Spock DDL — onboard once
on any node. Mesh cold *writes* route through the R-A bakery; its coordination
functions `_claim_iceberg_lock` / `_release_iceberg_lock` are themselves
`SECURITY DEFINER` (search_path-pinned, fully schema-qualified) so a non-superuser
drives the cross-node serialization (`pg_stat_replication` liveness + the dblink
claim) with the privilege it requires. `_exec_iceberg_with_claim` deliberately
stays `SECURITY INVOKER` — it runs the caller's cold DML, which must execute as the
caller. The bakery SD is **protocol-neutral**: it changes the PG execution
privilege, not the claim/ack/lock/ticket protocol, re-verified against
[the TLA+ model](formal/Bakery_v2.tla) (all safe configs pass; the race config
still violates `NoLakekeeperConflict`).

See README "Security"; asserted by the journey's `story_app_privilege`, `ci/ops.sh`
check 3, and the `privilege_model` pg_regress test.

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
`coldfront.tiered_views` by name (`schema_name`, `relname`) — and rewrites the parsed `Query` so it lands
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

### Cold-tier DML from inside plpgsql (functions, DO blocks, triggers)

Cold-tier `INSERT`/`UPDATE`/`DELETE` work as top-level statements *and* from
inside a plpgsql function / `DO` block / trigger. The hook runs at parse-analyze
(there is no executor hook), so parameter *values* are never reachable to it;
making the in-plpgsql case work meant solving two independent problems.

**Cause 1 — bound parameters (`$N`).** plpgsql compiles variable references —
and any client using bind parameters / `PREPARE` / the extended protocol sends —
into `$N` `PARAM_EXTERN` nodes whose values are unknown at parse-analyze time.
The deparser emits those as literal `$N` text, so the cold SQL handed to
`duckdb.raw_query` carried `$N` with nothing to bind (DuckDB: *"Expected N
parameters, but none were supplied"*). **Fix:** keep the params live — emit the
cold SQL as a runtime `format(<template>, $1, $2, …)` call (`cold_sql_arg`) and
declare the param types on the re-parse (`parse_analyze_fixedparams`). PG binds
the values at execution; DuckDB only ever sees finished literals. This applies
everywhere (top level and plpgsql) and adds no object — a driver's parameterized
cold `UPDATE` at the top level is exactly this case.

**Cause 2 — statement shape.** The cold rewrite is a row-returning
`SELECT coldfront._exec_iceberg_with_claim(...)`. At the top level the client
discards the row, but plpgsql rejects a bare result-returning SELECT with no
`INTO`/`PERFORM` (*"query has no destination for result data"*); it only accepts
a statement whose command tag is a DML returning no rows. We cannot inject
`INTO`/`PERFORM` (plpgsql source constructs, fixed before the hook runs), and the
cold table is a DuckDB-attached object, not a PG relation, so PG cannot tag a
real `UPDATE`/`DELETE` against it. **Fix (only where needed):** when — and only
when — the statement is parsed inside plpgsql, wrap the cold call as a DML over a
permanent single-row dummy carrier, `coldfront._dummy_dml_target`:

```sql
UPDATE coldfront._dummy_dml_target SET anchor = anchor
 WHERE coldfront._exec_iceberg_with_claim(...) IS NULL
```

That is a DML (plpgsql accepts it). The cold call runs exactly once in the WHERE
qual; because `_exec_iceberg_with_claim` returns `void` and `void IS NULL` is
always false, **zero rows match — the table is never written: no dead rows, no
WAL, no bloat, ever.** For dual-tier and tiered-INSERT the hot DML is the outer
statement and this same UPDATE rides in a data-modifying `WITH`-CTE (PostgreSQL
always runs those to completion, even unreferenced). At the top level nothing
changes — the SELECT shape is kept byte-for-byte.

**Detecting "inside plpgsql".** When plpgsql parses one of its statements it
installs `p_post_columnref_hook` on the `ParseState` (to resolve identifiers as
plpgsql variables); a top-level statement — including a parameterized one, which
sets only `p_paramref_hook` — never does. So the hook reads
`pstate->p_post_columnref_hook != NULL` as a precise, stateless,
side-effect-free "in plpgsql" signal — no PL/pgSQL plugin (which would collide
with the single global `PLpgSQL_plugin` slot that debuggers/profilers use), no
global counter, nothing that can interfere with other tooling.

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
| `on` | **patched** (`iceberg-bakery-aware-commit-refresh-v15.patch`) | Overlap: upload parquet in the background *first*, then take the ticket only for the Lakekeeper commit. Concurrent writers' uploads overlap; only the short commit POST is serialised. |

The code path is identical and the application-visible behaviour is
identical — one transactional write, no 409, no app-level retry — so the
GUC is purely a performance knob. The patch is needed only because stock
duckdb-iceberg stamps the parent snapshot id at *upload* time; overlapping
uploads would then commit a stale parent. The patch relocates that stamping
into PG's pre-commit phase (inside the bakery ticket, against a
freshly-fetched table), making the upload safe to overlap. The Docker image
ships the patched binary with `iceberg_async_parquet = on`; bare-metal users
on a stock binary leave it `off` and lose only the upload overlap. See
[DUCKDB_1.5_PATCHED.md](DUCKDB_1.5_PATCHED.md) and [DUCKDB_1.5_UNPATCHED.md](DUCKDB_1.5_UNPATCHED.md) for the build and
the full rationale.

### Transparent DDL via coldfront

A `ProcessUtility_hook` in the coldfront extension intercepts DDL that
targets a registered tiered table's hot heap (matched by resolving the
DDL target relation to an OID and comparing against the OID of the
registry's `hot_table` — never by string, so it is schema-agnostic):

| DDL | Behaviour |
|---|---|
| `ALTER TABLE _t ADD/DROP COLUMN`, `ALTER COLUMN ... TYPE`, `RENAME COLUMN` | **Mirrored to Iceberg** — the hook drops the view, runs the hot-side change, then `coldfront._mirror_iceberg_alter` issues the matching Iceberg `ALTER` (one bakery-serialized, claim-first catalog change) and rebuilds the view, so both tiers evolve in one statement. Column types map through `coldfront._iceberg_storage_type`, so an unsupported type (e.g. `inet`) is rejected up front; `ALTER COLUMN TYPE` is limited to the safe promotions duckdb-iceberg accepts (int→bigint, float→double, date→timestamp, decimal-widen). |
| `ALTER TABLE _t RENAME TO ...` | Supported (touches no Iceberg schema): update `tiered_views.hot_table`, rebuild the view. |
| `ALTER VIEW v RENAME TO ...` | Supported: migrate the name-keyed registry + `archive_watermark` rows to the new view name, then rebuild (otherwise the lookups miss and the cold UNION branch silently disappears). |
| `DROP TABLE _t` / `DROP VIEW v` | **Blocked by design** — would orphan the Iceberg cold tier. Dismantling tiering is a deliberate operator action (unregister with `partitioner remove`/`archiver remove`, which deletes the `partition_config` row, then drop each tier explicitly), never a one-shot call. |
| `TRUNCATE _t` | **Blocked by design** — cold-tier rows would remain visible through the view. The operator truncates each tier explicitly. |

The view rebuild always does `DROP VIEW` + `CREATE VIEW` (not
`CREATE OR REPLACE VIEW`, which PG only allows for appending columns at
the end). The registry is keyed by the view's `(schema_name, relname)`,
which the rebuild leaves unchanged, so there is nothing to re-point. A column
change is mirrored to Iceberg through `ensure_attached()` + the bakery, so it
requires a configured `coldfront.warehouse`; a RENAME TABLE/VIEW touches no
Iceberg schema and rebuilds the view regardless. Concurrent schema changes are
serialised by the same bakery as cold DML.

**Active-active.** Spock 5.0.8 replicates the top-level `ALTER TABLE` (the
hook's SPI-issued mirror/rebuild DDL runs at non-top-level context, which
Spock's `autoddl_can_proceed()` filters out). A peer's apply worker re-runs the
replicated `ALTER TABLE`; the hook rebuilds **that peer's own** local view, but
`coldfront._mirror_iceberg_alter` skips the Iceberg `ALTER` there (it runs under
`session_replication_role = replica`) because the originator already evolved the
shared Lakekeeper catalog. Because the registry is keyed by
`(schema_name, relname)` — node-independent — the row is identical on every
node: the rebuild needs no re-pointing, and the registry replicates cleanly by
value across the mesh (an OID could not). DROP and TRUNCATE are blocked on
every node. What a tiered table additionally needs to be usable on a peer is
covered next.

The tiered-specific cross-node behaviour — what replicates so a tiered table
is usable on every peer, and why both the registry and the watermark join the
replication set — is in
[ARCHITECTURE_TIERED.md → Tiered tables in a Spock mesh](ARCHITECTURE_TIERED.md#tiered-tables-in-a-spock-mesh).

### Registry keying: by name, not OID

`coldfront.tiered_views` is keyed by `(schema_name, relname)` — the transparent
view's qualified name. The C hook resolves it with
`WHERE schema_name = … AND relname = …` on every parsed statement that targets a
candidate relation; the hook already holds the target `relid`, from which the
schema and name are a cheap syscache lookup.

The name is the right key because it is **stable across the churn the system
actually produces**. The archiver and the DDL-rebuild path `DROP`+`CREATE` the
view regularly, minting a new view OID each time, while the name is unchanged —
an OID key would have to be re-pointed on every rebuild; a name key is not. The
one event that *does* change the name, `ALTER VIEW … RENAME`, migrates the
registry row and the watermark to the new name in a single step
(`_rename_tiered_view`), exactly as the watermark has always been name-keyed.

The name also **replicates cleanly across a Spock mesh**: it is node-independent,
so the registry row is identical on every node and the replication set copies it
by value (an OID is node-local and could not be). That is what makes cross-node
tiered tables work with no per-node re-resolution — see
[ARCHITECTURE_TIERED.md → Tiered tables in a Spock mesh](ARCHITECTURE_TIERED.md#tiered-tables-in-a-spock-mesh).

Lower-level operations that genuinely need an OID — catalog lookups, the DDL
hook matching the hot heap — resolve name→OID via `to_regclass` / `get_rel_name`
at the point of use: names everywhere, OIDs only where required.

### Per-table config: `coldfront.partition_config`

Which tables are managed and their lifecycle (`hot_period`, `retention_period`,
`partition_period`, premake, mode, `expiration_strategy`) live in
`coldfront.partition_config` — like `tiered_views` and `archive_watermark` above,
a **name-keyed** table that replicates **by value** across a Spock mesh. It is
auto-added to the default replication set on a spock node (a no-op on vanilla,
where there is one node), so every node reads identical config with no per-node
file syncing — the same property that motivates name-keying everywhere else.
`CHECK` constraints encode the lifecycle rules (a destroy boundary is required;
`id` mode forbids a hot tier — the cold tier is time-only; 2-level needs an
explicit RANGE column; `expiration_strategy` is `drop`|`detach`, and `detach` —
expire by detaching only, not dropping — is allowed partition-only), so an
invalid row is rejected at write time. The standalone partitioner
self-materializes the table on stock PostgreSQL via `EnsureTable`, needing no
extension. Connection config (DSN, Iceberg/S3 credentials) is deliberately **not**
stored here — it is per-node and must never ride the replication stream.

The *config* replicates by value; the partition **lifecycle DDL** must also reach
every node. `CREATE … PARTITION OF …` and `DROP TABLE` are ordinary transactional
DDL, so Spock's DDL replication carries them automatically. The retention
`DETACH PARTITION … CONCURRENTLY` is the exception: `CONCURRENTLY` cannot run in a
transaction block, so Spock skips it (`WARNING: This DDL statement will not be
replicated`) — left alone, a partition would stay attached on every peer while the
origin detaches it. The partition manager therefore detaches locally (top-level,
non-blocking) and then fans the **identical** concurrent detach to each peer via
`coldfront._detach_partition_peers`, which runs it in each peer's own autocommit
session over a dblink to that node's Spock interface DSN (a no-op off-mesh). The
archiver's cold-tiering cutover instead uses a plain, transactional `DETACH` inside
its atomic watermark+view+detach commit, so that one replicates on its own. This is
verified before any mesh partitioner run by `story_mesh_partition_ddl` in
`ci/journey.sh` (an N×(N-1) probe: create from every node, detach, drop, asserting
each lands on all nodes).

Both binaries read this table (the YAML `archiver.tables` list is a deprecation
bridge, used only when the table is empty) and expose a management CLI —
`register` / `list` / `set` / `remove` / `import` / `export` — documented in
[USAGE.md](USAGE.md#managing-partitioned-tables-cli).

## Known Limitations

These apply to both storage modes. Tiered-only limitations (cold RETURNING,
dual-tier command tag, crash-safety of permissive writes, partition-scheme
constraints, the empty cold-tier partition spec, autovacuum-vs-cutover) are in
[ARCHITECTURE_TIERED.md → Tiered-specific limitations](ARCHITECTURE_TIERED.md#tiered-specific-limitations).

1. **One-time secret setup after warehouse bootstrap** — after Lakekeeper is
   provisioned, an operator calls `SELECT coldfront.set_storage_secret(...)`
   once per cluster to record the cold-tier S3 credentials and materialize the
   DuckDB persistent secret. The Iceberg catalog ATTACH itself is lazy (on the
   first query touching a tiered view), so no per-session arming is needed and
   a pre-bootstrap connection can't be blocked by a missing warehouse.

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
   rather than parallelising one query. Those replicas **do** serve
   cross-tier reads — including read-only physical standbys, where
   `iceberg_scan` runs on the recovery backend (verified by
   [`ci/probe-standby.sh`](ci/probe-standby.sh)); a standby's cold reads
   are snapshot-consistent, not linearizable with concurrent primary cold
   writes (ordinary Iceberg snapshot isolation — see
   [ci/runbooks/failover-patroni.md](ci/runbooks/failover-patroni.md)).

6. **Iceberg only** — no Delta Lake support.  Adding Delta would
   require either a second writer path in `pg_duckdb`'s Iceberg
   extension or a different analytical engine.

## Infrastructure (Docker)

Three services: PG+pg_duckdb+coldfront, Lakekeeper, and any
S3-compatible store.  Both extensions must be in
`shared_preload_libraries` — `coldfront` installs its hook in
`_PG_init`, which fires at backend start.

A two-layer image serves every deployment: a prebuilt **base**
(`docker/Dockerfile.duckdb15-base`) carrying pg_duckdb 1.5.3 (PR #1025) + the
patched duckdb-iceberg on a pgEdge `*-spock5-minimal` base (Spock + Snowflake),
and a thin **app** layer (`docker/Dockerfile.duckdb15`, `--build-arg
PG_MAJOR=16|17|18`) that compiles coldfront on top. The same image plays both
topology roles — vanilla leaves spock/snowflake out of
`shared_preload_libraries`; mesh loads them (`MESH=on`, set by the entrypoint).

```yaml
services:
  db:
    build:
      context: .
      dockerfile: docker/Dockerfile.duckdb15
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

## Upstream Requests (Potentially)

Behaviours in upstream projects that ColdFront works around, kept as
architectural notes: the gap, the workaround in use today, and the shape of
the upstream capability that would let us drop the workaround.

### pg_duckdb: non-superuser LocalFileSystem blocks side-loaded extensions

pg_duckdb force-disables DuckDB's `LocalFileSystem` for any role that is not a
member of both `pg_read_server_files` and `pg_write_server_files`
(`AllowRawFileAccess()` → `RefreshConnectionState`, keyed off `GetUserId()`).
That is correct hardening for raw file access, but it also blocks **loading a
locally-installed DuckDB extension** — and ColdFront side-loads a patched
`iceberg` (and `postgres`) extension from disk, which DuckDB lazily loads on
`ATTACH`. So a non-superuser's first cold query fails at the elevated load step.

**Workaround today:** `coldfront.ensure_attached()` / `ensure_pg_attached()` are
`SECURITY DEFINER`, so the load + `ATTACH` run as the (privileged) extension
owner once per backend; the per-backend DuckDB instance then keeps the extension
loaded, and subsequent scans/commits run unprivileged over S3 (no
`LocalFileSystem`). The config GUCs the elevated path consumes are `PGC_SUSET` so
the privilege can't be abused to redirect the `ATTACH`.

**Upstream shape that would drop it:** either a way to mark specific
locally-installed extensions as loadable without `LocalFileSystem` access, or
distinguishing extension-load file access from user-initiated raw file access in
the non-superuser sandbox — so a non-superuser member of `duckdb.postgres_role`
could `ATTACH (TYPE ICEBERG, …)` directly, without ColdFront's `SECURITY DEFINER`
shim.

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

**Workaround today.** A DuckDB **persistent secret**, set via
`coldfront.set_storage_secret(...)` and materialized into the
`coldfront.storage_secret` table, is loaded by DuckDB automatically at
instance init. Because it is persisted before any backend issues a query, it
already sits at a committed timestamp (< `start_time`) when a fresh
transaction looks it up (see Mechanism below) — so the secret is
committed-visible to the very first cold-tier write, with no warmup step
needed and no dependency on any per-session connect-time hook.

**Symptom.** Without the warmup, a fresh PG backend's first cold-tier
write fails with HTTP 403 against any non-AWS S3-compatible endpoint
(SeaweedFS, MinIO, path-style GCS, on-prem S3). DuckDB's httpfs falls
through to AWS virtual-hosted-style defaults
(`<bucket>.s3.amazonaws.com`) because `SecretManager::LookupSecret` returns
empty.

**Mechanism (verified against duckdb-iceberg `v1.5-variegata` @ `0fad545a`
`IcebergTransaction::Commit` and DuckDB's `CatalogSet` / `SecretManager`
source).** `IcebergTransaction::Commit` opens a fresh `Connection` +
`BeginTransaction` for its commit-time I/O and **copies the caller's
`ClientConfig`** into it (`temp_con_context->config = context->config` — so
`SET`-style settings such as `s3_access_key_id` *are* available). But a secret
created with `CREATE SECRET` does **not** live in `ClientConfig` — it is a
`CatalogEntry` in the `SecretManager` catalog, which `config` does not carry. So
the fresh transaction still cannot see a secret registered by the caller's
still-active transaction: `CatalogSet::UseTimestamp`'s visibility rules require
either same-tx (`timestamp == transaction_id`) or already-committed
(`timestamp < start_time`), and neither holds for the caller's still-uncommitted
secret. After any prior DuckDB `MetaTransaction::Commit` in the backend the
secret entry's timestamp flips to a committed value (< `TRANSACTION_ID_START`)
and every subsequent fresh transaction satisfies the second rule. A DuckDB
**persistent** secret achieves this structurally: loaded at instance init, it is
already at a committed timestamp before any backend's first cold-tier
transaction looks it up — so the persistent-secret design still holds on v1.5
and is still required for a synthesized (non-`SET`) credential.

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

**Desired end-state.** Either `IcebergTransaction::Commit` runs its commit-time
I/O under the caller's `ClientContext` (rather than a freshly-opened
Connection), or any extension that synthesises `CREATE SECRET` from external
state commits that transaction explicitly, so the secret sits at a committed
timestamp before a consumer's fresh transaction looks it up. Either would let
a per-session synthesized secret work without relying on the persistent-secret
mechanism; today the persistent secret sidesteps the bug entirely at zero
per-session cost.

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
`duckdb-iceberg`:

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

