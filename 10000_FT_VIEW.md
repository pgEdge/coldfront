# pgEdge ColdFront — 10,000-foot view

## The shape of the problem

A long-lived PostgreSQL database keeps accumulating history. A year in,
most of the rows are old and rarely read; a small working set at the head
of the timeline carries almost all of the traffic. The storage bill, the
VACUUM cost, the backup window, and the replica catch-up time all scale
with the total row count, not with the part anyone actually touches.

Teams handle this in one of a few ways, none of them good:

- **Do nothing.** Costs keep growing, operational windows keep shrinking.
- **Periodically delete or archive to flat files.** Queries that need the
  old data now have to go somewhere else — different system, different
  tools, different SQL.
- **Buy a vendor-specific tiering add-on.** Cold data becomes tied to a
  proprietary storage layer (different table access method, different
  file format, different licence). Migrating off it later is its own
  project.

The goal of pgEdge ColdFront is to keep the working set in native
PostgreSQL partitions, move the rest to an open file format on cheap
object storage, and let applications keep using the same table name
for all of it — reads and writes.

## What the application sees

Before adoption:

```sql
INSERT INTO events (ts, user_id, ...) VALUES (...);
UPDATE events SET status = 'done' WHERE id = 42;
SELECT count(*) FROM events WHERE ts > now() - interval '1 day';
```

After adoption: exactly the same SQL.

The same four verbs (`SELECT`, `INSERT`, `UPDATE`, `DELETE`) continue to
work against the same name (`events`). There is no parallel `events_cold`
table, no `duckdb.raw_query('...')` in application code, no
"please-use-this-hint-to-query-archived-data" special path. The tiering
is a property of the deployment, not of the application's SQL.

## What's under the hood

- **PostgreSQL**: stock upstream open-source PostgreSQL 16, 17, or 18.
  Not a fork, not a patched build. Installable from the usual
  packages, operable with the usual tools. The project adds
  extensions on top; nothing below them is modified. The `coldfront`
  extension attaches the Iceberg catalog lazily — a C extension hook
  attaches it on the first query that touches a tiered view — so there
  is no per-session setup step and no version gating; the same
  mechanism works uniformly on PG 16, 17, and 18.
- **Hot tier**: regular PostgreSQL range-partitioned tables. Same planner,
  same pg_dump, same backup story. Logical replication (including
  pgEdge's Spock, for multi-master and cross-region setups) treats the
  hot tier as plain PostgreSQL DML because that's what it is.
- **Cold tier**: Apache Iceberg tables on any S3-compatible object store.
  Iceberg is an open specification backed by the Apache Software
  Foundation; files are plain Parquet plus metadata. Nothing on the cold
  tier is proprietary or locked to this project.
- **Catalog**: Lakekeeper, a small Apache-licensed binary that speaks the
  standard Iceberg REST catalog protocol.
- **Glue inside PostgreSQL**: two extensions. `pg_duckdb` (from the
  DuckDB team, stock upstream, no fork) gives PostgreSQL the ability to
  read Iceberg files in-process. `coldfront` (this project) is a
  small C extension that rewrites `UPDATE`/`DELETE` on the tiered view so
  the right rows end up on the right tier.
- **Archiver**: a small static Go binary (~9 MB, no runtime, no CGO,
  no daemon) that moves expired partitions off to Iceberg on a
  schedule. No queue, no dependencies beyond the PostgreSQL driver —
  invoked from cron.

The total moving-parts count: stock PostgreSQL, two in-process
extensions, one small Rust catalog binary, any S3. No engine sidecar,
no cluster manager, no fork.

## What you give up

- **Cold reads are slower than hot reads.** Iceberg on object storage is
  not an in-memory heap. Queries that scan large cold ranges will feel
  it; queries that hit the hot tier keep PostgreSQL's usual latency
  characteristics.
- **Cross-tier transactions are not crash-safe in the default mode.**
  A single `UPDATE` whose `WHERE` clause hits rows in both tiers writes
  to both together. Normal `ROLLBACK` undoes both sides (DuckDB's
  transaction is tied to PostgreSQL's). A backend crash mid-commit can
  leave orphaned object-storage files that Iceberg housekeeping later
  reclaims, but no visible inconsistency. Teams that need stricter
  guarantees flip a single setting to reject cross-tier writes outright
  — they still get transparent single-tier UPDATE/DELETE.
- **Not a sharded multi-node cluster.** This is a tiering story for a
  single PostgreSQL instance (which can still be replicated by standard
  PostgreSQL mechanisms, including pgEdge's Spock logical replication).
  If you need multi-master or distributed query execution, you need a
  different tool alongside it.
- **Range-partitioned tables only.** The source table must already be
  partitioned by a time-like column. Converting an unpartitioned table
  is not in scope; it has to be partitioned first by the usual
  PostgreSQL mechanisms.

## How this compares

Three other projects marry PostgreSQL to object-storage analytics,
each with a different compromise.  Databricks **Lakebase** (née Neon,
plus the Mooncake acquisition) has no user-visible tier at all —
cold pages go to S3 in a proprietary chunked format, and open-format
access is a one-way Delta/Iceberg mirror queried by Photon on the
Databricks side.  Snowflake's **Postgres** service with the
`pg_lake` extension family does support writable Iceberg, but
through a separately-named table: the application has to know
which table to address, and moving data between them is its job.
Only EDB PGAA actually attempts transparent hot-plus-cold under one
table name; the detailed breakdown is in [COMPARISON.md](COMPARISON.md).

The closest commercial offering is therefore EDB PGAA (PG Analytical
Accelerator).  The meaningful differences, in plain terms:

- ColdFront runs on stock open-source PostgreSQL (no fork, no patched
  build). PGAA is a paid add-on that runs inside EDB Postgres
  Distributed — a distinct distribution from community PostgreSQL with
  its own release cadence and licence.
- ColdFront's cold tier is writable through the same table name — users
  can update or delete archived rows without switching tools. PGAA's
  cold tier is read-only, so teams that need occasional corrections to
  old data end up rehydrating or bypassing the tiering.
- ColdFront offers both writable cold (default) and strict read-only-cold
  enforcement via a single GUC. Strict mode is the same
  read-only-cold guarantee PGAA provides, without giving up the option
  of writable cold for operators who want it.
- ColdFront uses standard Apache Iceberg files on any S3-compatible
  store. PGAA uses a proprietary table-access-method layer for cold
  data, and Seafowl as a separate process for the query engine.
- ColdFront runs in a single PostgreSQL process plus a small catalog
  daemon. PGAA requires an EDB Postgres Distributed cluster (three
  nodes minimum) plus a separate Seafowl engine communicating over
  Arrow Flight RPC.
- ColdFront is replication-compatible with pgEdge Spock. Hot-tier DML
  goes through standard PostgreSQL and replicates normally; cold-tier
  writes go directly to Iceberg, which uses its own optimistic
  concurrency control, so they converge across Spock nodes without
  conflicting with logical replication.

## When this is a fit

- The application is already on PostgreSQL and the table to tier is
  partitioned by a time-like column (or can be).
- A clearly bounded working set — "last N weeks / months of traffic" —
  carries the bulk of the read/write load, with a long tail of older
  data that's queried infrequently.
- You want the archived data to remain in an open format on commodity
  storage, queryable later without this project's tooling in the path.
- You want application developers to keep writing standard SQL against a
  single table name, and you want operations to keep using standard
  PostgreSQL tooling (pg_dump, logical replication, monitoring, backups)
  without special cases.

## When it isn't

- If the "cold" tier needs to serve sub-millisecond random reads at
  high QPS, object storage won't meet that. Keep it all hot.
- If the database doesn't have a monotonic time-like partition key and
  can't be made to have one, the archiver has nothing to advance over.

## Posture

Everything is open source and publicly developed. The target is stock
upstream PostgreSQL — installed from the normal distribution packages,
without a forked build or carried patches. The archiver is a small
pure-Go binary; the extension is a small C extension built with
PostgreSQL's standard PGXS build system. The cold file format, the
catalog protocol, and the query engine are all industry-standard open
specs. Nothing on disk — hot or cold — requires this project's tooling
to read after the fact.
