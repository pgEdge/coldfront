# pgEdge ColdFront vs the lakehouse-Postgres incumbents

## TL;DR — KISS wins

ColdFront is **stock upstream PostgreSQL 17/18 + two extensions + one
small Rust binary (Lakekeeper) + any S3**.  The archiver is a
small static Go binary (~9 MB, no runtime, no CGO, no daemon) that
runs from cron.  That is the entire stack.
Hot data stays in vanilla `PARTITION BY RANGE` tables; cold writes
are a library call into `pg_duckdb` running **in the same Postgres
process** — no RPC, no sidecar daemon, no cluster manager, no fork.

Every competitor picks a heavier compromise:

- **EDB PGAA** requires EDB's Postgres distribution, the PGAA
  extension (a non-standard Table Access Method), the **Seafowl
  daemon** talking Arrow Flight RPC to Postgres per query, the
  PGFS connector, and — for Tiered Tables — the PGD cluster manager
  (min. 3 nodes) with its distributed state machine.
- **Databricks Lakebase** is a Databricks-managed **Neon fork** (not
  self-hostable).  Cold storage is proprietary chunked PG pages on
  S3 — not Iceberg.  The open-format story is `pg_mooncake` +
  `pg_moonlink` *mirroring* PG tables into Delta/Iceberg for
  consumption by **Photon** on the Databricks side — a CDC mirror,
  not a tier.  Needs a Databricks workspace, Unity Catalog, and the
  Lakebase runtime.
- **Snowflake Postgres / `pg_lake`** loads **15+ PG extensions**
  (`pg_lake_iceberg`, `pg_lake_table`, `pg_lake_copy`,
  `duckdb_pglake`, …) and runs DuckDB as a **separate
  `pgduck_server` daemon** behind a local PG wire-protocol socket.
  The application sees two separate tables (PG heap and Iceberg
  table); moving data between them is the user's job.

## Overview

| | **ColdFront** | **EDB PGAA** | **Databricks Lakebase** | **Snowflake PG / `pg_lake`** |
|---|---|---|---|---|
| PostgreSQL | **Stock upstream PG 17/18** | EDB distribution | Databricks-managed Neon fork | Stock upstream PG 16/17/18 |
| License | 100% OSS (PostgreSQL / MIT / Apache 2.0) | Proprietary (EDB subscription) | Service proprietary; [Neon](https://github.com/neondatabase/neon) Apache 2.0, [pg_mooncake](https://github.com/Mooncake-Labs/pg_mooncake) MIT | Service proprietary; [pg_lake](https://github.com/Snowflake-Labs/pg_lake) Apache 2.0 |
| PG extensions required | **2** (`pg_duckdb`, `coldfront`) | `pgaa` TAM + PGD stack | Lakebase runtime + `pg_mooncake` + `pg_moonlink` | **15+** (`pg_lake_iceberg`, `pg_lake_table`, `pg_lake_copy`, `duckdb_pglake`, …) |
| Separate services / daemons | Lakekeeper (~20 MB Rust binary) + S3 | Seafowl daemon + PGFS + PGD consensus + AutoPartition | Databricks workspace, Pageserver, Photon, Unity Catalog, Synced Tables / Lakehouse Sync | `pgduck_server` daemon + optional Polaris |
| Analytical engine | DuckDB — **in-process library call** | Seafowl — **Arrow Flight RPC** to separate daemon | Photon — **not callable from PG** (Databricks-side only) | DuckDB — **separate daemon** over local socket IPC |
| Cluster requirement | None | **PGD cluster (min. 3 nodes)** for Tiered Tables | **Databricks SaaS** only | None for OSS pg_lake; SaaS for managed |
| Iceberg catalog | Lakekeeper | External REST catalog | Unity Catalog (optional) | Postgres itself; Polaris experimental |
| Object storage | Any S3-compatible | S3 / GCS / Azure | S3 (AWS GA), Azure preview | S3 primary, Azure mentioned, GCS absent |
| Lake format | Apache Iceberg | Iceberg + Delta (Delta read-only) | Delta native; Iceberg via Mooncake | Iceberg only |
| Lifecycle | Small static Go archiver (~9 MB, no CGO), cron | PGD AutoPartition | No tier — `pg_moonlink` mirrors out | Manual application `INSERT … SELECT` |
| Self-host | **Yes, trivially** | No | No | Yes for OSS pg_lake; no for managed |

## Tiered-tables comparison

The one question that matters for this project: does the product
give you a **single table name** that transparently spans hot PG
rows and cold object-storage rows, with standard DML on both?

| | **ColdFront** | **EDB PGAA** | **Databricks Lakebase** | **Snowflake PG / `pg_lake`** |
|---|---|---|---|---|
| Single table name spans hot + cold | Yes | Yes (TAM parent) | No (Delta mirror, not a tier) | No (two separate tables) |
| Cold-tier row-level `UPDATE`/`DELETE` | Yes | No (offloaded rows are read-only) | N/A — no tier | Yes (Iceberg v2 MOR/COW) |
| Cold written via same application SQL | Yes | CTAS bulk only | N/A | No — explicit `INSERT INTO iceberg_table` |
| Stock upstream PostgreSQL | Yes | No | No | Yes (pg_lake OSS) |

ColdFront is the only option that combines transparent tiering with
row-level cold mutability on stock upstream PostgreSQL.

## Transparency Comparison

### Reads

| | **ColdFront** | **EDB PGAA** | **Lakebase** | **Snowflake PG / `pg_lake`** |
|---|---|---|---|---|
| Transparent cross-tier reads | Yes (unified view) | Yes (TAM parent) | N/A — no tier; Delta mirror queried in Databricks | No — user SELECTs from PG heap *or* Iceberg table |
| Standard SQL | Yes | Yes | Yes (on the PG surface) | Yes (on either table individually) |
| Hot-only query pruning | Yes (PG partition pruning) | Yes (PG partition-wise planning) | N/A | N/A |
| Cold query acceleration | DuckDB in-process | Seafowl (separate daemon, RPC) | Photon (Databricks-side only) | DuckDB via `pgduck_server` (separate daemon) |
| Hot query acceleration | `duckdb.force_execution=true` | Seafowl DirectScan | Photon | `pg_lake` routing to DuckDB |
| Query modes | Single mode | DirectScan / CompatScan | Single | Single |
| Source-of-truth schema | Vanilla `PARTITION BY RANGE` | `CREATE TABLE ... USING PGAA` (non-standard TAM) | Plain PG tables (Lakebase-hosted) | Plain PG tables + separate Iceberg tables |
| `pg_dump` portability | **Unchanged** | Breaks on non-PGAA servers | Lakebase-locked | Hot heap dumps normally; Iceberg tables need `pg_lake` to restore |

ColdFront's hot tier is indistinguishable from a plain partitioned
table — `pg_dump`, logical replication, and pgEdge Spock all work
unchanged.  EDB's TAM makes the schema non-portable; Lakebase's
managed fork makes the whole database non-portable; `pg_lake`
requires the same 15+ extensions at the target.

### Writes

| | **ColdFront** | **EDB PGAA** | **Lakebase** | **Snowflake PG / `pg_lake`** |
|---|---|---|---|---|
| Hot `INSERT` | Yes (unified view) | Yes (native PG) | Yes (native PG) | Yes (native PG heap) |
| Hot `UPDATE`/`DELETE` | Yes (view rewrite to `_events`) | Yes (native PG) | Yes | Yes |
| Cold `INSERT` | Yes (view's `INSTEAD OF` trigger routes by `ts`) | CTAS bulk only; no row `INSERT` | N/A — no tier | Yes, but on the separately-named Iceberg table |
| Cold `UPDATE`/`DELETE` | Yes (view rewrite to `duckdb.raw_query`) | **No** — offloaded rows read-only | N/A | Yes (Iceberg v2 MOR/COW) |
| Cross-tier `UPDATE`/`DELETE` | Yes in permissive mode; opt-out via `coldfront.allow_mixed_writes = off` | **No** | N/A | No — two tables, two statements |
| Write transparency | **Full** — every verb uses the original table name | Hot only; cold read-only | N/A | None — application must know which table |

ColdFront is the only option where cold data is mutable under the
same table name the application already uses.  EDB enforces
read-only cold; Lakebase has no tier at all; `pg_lake` pushes the
hot/cold split into the application layer.

Operators who want EDB's read-only-cold guarantee can set
`coldfront.allow_mixed_writes = off` — ambiguous cross-tier writes
are then rejected with a clear error.  The writable-cold model is
opt-in, not imposed.

## Cold-query path

ColdFront is the only option that keeps the cold query path
in-process; EDB and `pg_lake` both serialise across a process
boundary per query; Lakebase doesn't have a cold query path from the
PG surface at all.

| Step | **ColdFront** | **EDB PGAA** | **Snowflake PG / `pg_lake`** |
|---|---|---|---|
| 1. PG receives query | — | — | — |
| 2. Cold hand-off | Library call into `pg_duckdb` — no network | Arrow Flight RPC to Seafowl daemon | PG wire-protocol call to local `pgduck_server` daemon |
| 3. Engine reads storage | DuckDB reads S3 directly | Seafowl reads object store | DuckDB reads S3 |
| 4. Return to PG | Direct memory | Arrow batches over RPC + deserialise | Tuples over local socket + deserialise |

(Lakebase omitted: cold reads from the PG surface go through
Neon's Pageserver as regular PG pages; analytical queries over
Delta/Iceberg run in Databricks via Photon, not in PG.)

## Honest tradeoffs in ColdFront

Short list of where we're not best-in-class.  Mechanics and the
rationale for each are in [ARCHITECTURE.md — Known
Limitations](ARCHITECTURE.md#known-limitations).

1. Cross-tier atomicity is not crash-safe in permissive mode — a
   crash mid-commit can orphan S3 objects.  `ROLLBACK` works; the
   strict mode avoids the path entirely.
2. Dual-tier UPDATE has cosmetic regressions — command tag and
   `RETURNING` are hot-side only in v0.1.
3. `jsonb` surfaces as `json` (not `jsonb`) through the unified
   view — DuckDB has no native `jsonb`, so the view unifies both
   tiers on DuckDB's `json`. Standard access operators (`->>`,
   `->`, `#>`) work unchanged; jsonb-only operators (`?`, `@>`,
   containment, de-dup) need an explicit `data::jsonb` in the
   caller's query.
4. One-time arming after Lakekeeper bootstrap: an operator must
   call `SELECT coldfront.arm_login_attach()` once per database for
   the LOGIN event trigger to start auto-attaching Iceberg on every
   new session. After that, session setup is fully automatic — no
   per-query boilerplate. EDB's tiering has no equivalent arming
   step.
5. Lifecycle is a cron-driven archiver — no state machine, no
   automatic restore.  EDB PGD AutoPartition is more turnkey.
6. No DirectScan/CompatScan decision engine — `pg_duckdb`
   intercepts at the planner level.
7. Single-node query execution.  Replication (single- or
   multi-master via pgEdge Spock) is supported on the hot tier; EDB
   PGD adds distributed query execution on top of its clustering.
8. Iceberg only — no Delta Lake.  EDB supports both.

## Bottom line

Non-redundant differentiators, distilled:

| | **ColdFront** | **EDB PGAA** | **Lakebase** | **Snowflake PG / `pg_lake`** |
|---|---|---|---|---|
| Licence | Open source (PostgreSQL / MIT / Apache) | Proprietary EDB subscription | Proprietary service (Neon Apache, Mooncake MIT) | Proprietary service (`pg_lake` Apache) |
| Runs on | Stock upstream PG 17/18 | EDB PGD cluster (min. 3 nodes) | Databricks SaaS only | Snowflake SaaS or stock PG 16/17/18 |
| Forks / distributions required | None | EDB Postgres distribution | Databricks-managed Neon fork | None for OSS pg_lake |
| PG extensions | 2 | 1 (`pgaa`) + PGD stack | Lakebase runtime + 2 Mooncake extensions | 15+ |
| Analytical engine | **In-process** DuckDB | Arrow Flight RPC to Seafowl daemon | Photon (Databricks-side only) | Local socket IPC to `pgduck_server` daemon |
| Hot-tier schema | Vanilla `PARTITION BY RANGE` — `pg_dump` / logical replication / Spock unchanged | `CREATE TABLE … USING PGAA` (TAM) — dump/restore breaks on non-PGAA servers | Managed Lakebase database — not portable | Plain PG tables + separate Iceberg tables |
| Cold tier is | **Writable via the same table name** | Row-DML read-only | Not a tier — Delta/Iceberg mirror queried in Databricks | Writable Iceberg table *with a different name* |
| Multi-master replication | pgEdge Spock on the hot tier, plain PG DML | PGD-native | Primary + ≤3 readable secondaries | None |
| Lake format | Apache Iceberg | Iceberg + Delta Lake (Delta read-only) | Delta native; Iceberg via Mooncake | Iceberg only |
| Distributed queries | No — single-node execution | Yes (PGD) | No on the PG surface | No (single-node PG + local DuckDB) |

Rows covered by the detailed tables above are not repeated here.
