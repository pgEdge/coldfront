# Experimental: PG-style MVCC on Iceberg via Snowflake CSN

Status: design proposal, unimplemented. Captures the architecture
considered while investigating multi-writer scaling on a single
Iceberg table and the cross-query snapshot consistency gap noted in
[ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md).

## Problem statement

Decoupled mode today gives storage/compute decoupling but two
properties are weaker than a native PG deployment:

1. **Cross-query snapshot consistency.** Within a single PG
   transaction, two `iceberg_scan(...)` calls can interleave with
   commits from other sessions. The reader can see snapshot S₁ on the
   first scan and S₂ on the second. PG's MVCC guarantees a stable
   read-view across an entire transaction; Iceberg's snapshot model
   doesn't, because each scan resolves the catalog independently.

2. **Concurrent writers serialize at the catalog.** Lakekeeper enforces
   optimistic CAS on `metadata_location`. All writers commit through
   that single guard. Even commits to disjoint partitions or different
   branches share the same `metadata.json`, so concurrent writes 409
   each other regardless of partition or branch. (See
   [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md#concurrency--horizontal-scaling--the-bakery-protocol).)

The MVCC design below addresses both.

## Core idea

Treat every Iceberg table as a multi-version log:

- Each row carries `xmin BIGINT NOT NULL` (snowflake-shaped commit
  sequence number of the inserter) and `xmax BIGINT DEFAULT 0`
  (snowflake CSN of the deleter, or 0 = alive).
- All DML becomes pure append: INSERT writes new rows, UPDATE writes
  new row + an equality-delete row marking `xmax` on the old, DELETE
  writes only the equality-delete row.
- Visibility is row-level, evaluated at SELECT time via a `WHERE`
  predicate over `xmin`/`xmax` and the reader's transaction-pinned
  CSN.

This makes every Iceberg commit a **pure append** at the file level —
no in-place modification, no copy-on-write data file rewrites — which
means commits are *always* trivially rebaseable on conflict, and the
Iceberg snapshot graph itself becomes the commit log.

## Snowflake CSN

64-bit layout:

```
| 1 bit | 41 bits timestamp ms | 10 bits node_id | 12 bits sequence |
```

- 41 bits ms ≈ 69 years from a chosen epoch.
- 10 bits = 1024 distinct node identities.
- 12 bits = 4096 IDs per node per ms.
- Aggregate cluster ceiling: ~4 billion CSNs per second.

**No central allocator.** Each PG node generates CSNs locally from its
clock + a per-node identity (reused from Spock's node-id assignment) +
an in-process counter. Two writers never coordinate on CSN issuance.

`coldfront.snowflake_now()` is a `STABLE` SQL function:

```sql
CREATE FUNCTION coldfront.snowflake_now() RETURNS bigint
LANGUAGE plpgsql STABLE AS $$
DECLARE
    epoch_ms bigint := 1735689600000;  -- 2025-01-01
    ts_ms    bigint := EXTRACT(EPOCH FROM clock_timestamp()) * 1000;
    node_id  int    := current_setting('coldfront.node_id')::int;
    seq      int;
BEGIN
    -- atomic: backend-local counter wraps at 4096
    seq := nextval('coldfront.snowflake_seq') % 4096;
    RETURN ((ts_ms - epoch_ms) << 22) | (node_id << 12) | seq;
END $$;
```

## The Iceberg snapshot graph as commit log

In standard PG, the commit log (`pg_xact`/clog) records whether each
xid committed or aborted. With this design, no separate clog is
needed:

- A row tagged `xmin = X` is *committed* iff that row appears in some
  manifest reachable from the table's `current-snapshot-id`.
- A row whose data file was uploaded to S3 but never landed in a
  successful catalog commit (writer crashed, 409'd, network failed)
  is invisible by construction — it's not in any manifest. The Parquet
  blob is orphaned and cleaned up by S3 lifecycle policy or Iceberg
  housekeeping.

Reader algorithm:

1. At transaction start, capture `reader_csn := coldfront.snowflake_now()`.
2. Every `SELECT` against a tabular relation gets the predicate
   appended:
   ```sql
   xmin <= reader_csn AND (xmax = 0 OR xmax > reader_csn)
   ```
3. Iceberg-scan visibility (which manifests are read) is determined at
   the transaction's first scan and pinned for its duration. (Pinning
   exists today via `duckdb.query('SELECT * FROM ice.…')`; this design
   formalises it.)

Row visibility is now well-defined for the entire transaction — no
mid-transaction snapshot drift.

## Writer-side rewrites in the coldfront hook

The C hook in [extension/coldfront/src/coldfront.c](extension/coldfront/src/coldfront.c)
already rewrites DML on tracked relations into `duckdb.raw_query(…)`.
The MVCC layer extends those rewrites:

| Operation | Today | With MVCC |
|---|---|---|
| INSERT | append rows | append rows with `xmin = snowflake_now()`, `xmax = 0` |
| UPDATE | rewrite data files | append new row(s) with new `xmin`; emit equality-delete row(s) with `xmax = snowflake_now()` for the matched primary key(s) |
| DELETE | rewrite data files / emit position-deletes | emit equality-delete row(s) with `xmax = snowflake_now()` |
| SELECT | scan | scan with appended visibility predicate |

Equality-delete rows are an existing Iceberg v2 feature; DuckDB-iceberg
already supports writing them. They live in delete files alongside data
files in the same manifest.

## Why every commit becomes rebaseable

With MVCC, no commit ever modifies an existing data file. All commits
are pure additions — new data files (for INSERT/UPDATE-new-row) and
new delete files (for UPDATE-old-row/DELETE).

When two writers race on `metadata_location`:

- A's commit succeeds, advancing the table to `M₁`.
- B's commit, prepared with `parent = M₀`, gets a 409.
- B's writer reads the new metadata, replaces its commit's parent
  pointer with `M₁`, and resubmits. The data files B added are still
  valid; they don't conflict with A's data files (different paths).
  The new manifest list is the only thing that needs regenerating.

This rebase is *semantically free*: pure-append commits never have
rebase conflicts. The retry just needs to redo the catalog round-trip.

The rebase-retry is the work item that lives in **`duckdb-iceberg`**.
It's the same patch needed even without MVCC, but with MVCC it's
*always* successful, never falling back to "drop the batch" or
"escalate to user".

See [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md#concurrency--horizontal-scaling--the-bakery-protocol)
for the rebase-retry as it relates to the existing architecture.

## Vacuum / compaction

Iceberg already has `RewriteDataFiles` that compacts small files into
bigger ones, optionally filtered. With MVCC the filter expression is:

```sql
KEEP WHERE xmax = 0 OR xmax > min_active_reader_csn
```

`min_active_reader_csn` is the cluster-wide minimum of all in-flight
transactions' `reader_csn`. Same role as PG's `OldestXmin`.

Tracking the watermark:

- Each PG node maintains a session-local view of its own active
  reader CSNs in shared memory (`coldfront.active_readers`).
- Cluster-wide minimum is computed by a periodic worker that polls
  each node — Spock-replicated registry of per-node minima, minimum
  of those = `min_active_reader_csn`. Eventual consistency is fine;
  vacuum is conservative by under-counting reader liveness.

Compaction throughput is bounded by Parquet I/O — Iceberg compaction
routinely runs at GB/s on modern object stores. Parquet column stats
on `xmax` give predicate pushdown: files where every row has
`xmax = 0` skip entirely.

## Trade-offs and risks

1. **Storage amplification.** UPDATE-heavy workloads bloat without
   timely vacuum. Worst case: doubled storage per pending UPDATE
   generation. Mitigated by frequent compaction; worth measuring on
   a representative workload before committing to the design.

2. **Read amplification on uncompacted tables.** Every scan reads
   dead rows then filters. Parquet column stats over time-clustered
   `xmin`/`xmax` give good skipping for append-mostly workloads. UPDATE
   churn breaks the clustering — measure.

3. **Clock skew defines the snapshot-isolation skew window.** With
   NTP-synced nodes (±10 ms typical) the visibility boundary can be
   off by ±10 ms. A reader can briefly miss a row that's already in
   the iceberg manifest if the writer's `xmin` was generated on a
   node whose clock drifts ahead. Same model as CockroachDB, Spanner,
   FoundationDB. Not a correctness issue; a freshness one.

4. **Two reserved column names per table forever.** `xmin`/`xmax`
   either become user-visible (with the same semantics as PG's system
   columns of the same name — cohesive choice) or get a hidden
   prefix like `_mvcc_xmin`. Either way, every coldfront-managed
   table carries the cost and the schema lock-in.

5. **Hook complexity rises ~3–5×.** Today the hook has one rewrite
   path per DML verb. With MVCC, every verb gets two rewrites (the
   visible columns + the xmin/xmax bookkeeping) and SELECTs gain
   the predicate-rewrite path.

6. **`pg_dump` / native PG tools become irrelevant** for the table's
   contents (already true in iceberg-only mode), but more so —
   visibility cannot be reproduced without the reader_csn pinning,
   so external tools that scan Parquet directly will see all
   versions.

7. **Aborted transactions leak storage.** A writer that uploads
   Parquet then crashes before committing the catalog leaves
   orphan blobs in S3. Iceberg's existing housekeeping reclaims
   them via `expire_snapshots`/orphan-file cleanup — same gap that
   already exists in tiered mode (Known Limit §3 in ARCHITECTURE.md).

8. **Schema evolution interacts with the visibility predicate.**
   Adding a column to a tracked relation needs a strategy for older
   data files that don't have the new column — same as plain
   Iceberg, but the rewrite layer must keep up with column adds.

## Phased plan

**Phase 0 — prerequisite (independent of MVCC):**
- Land the writer-side rebase-retry loop in `duckdb-iceberg`'s
  commit path. ~50–100 lines in `irc_transaction.cpp`. Single-table
  multi-writer commits stop dropping batches.

**Phase 1 — MVCC schema + visibility:**
- Add `xmin BIGINT NOT NULL DEFAULT coldfront.snowflake_now()` and
  `xmax BIGINT DEFAULT 0` to every table created by
  `coldfront.create_iceberg_table()`.
- Implement `coldfront.snowflake_now()` and the `node_id` GUC
  (reuse Spock's node identity).
- Hook rewrites: INSERT (auto-fill xmin), SELECT (append visibility
  predicate using transaction-pinned `reader_csn`).
- Behaviour: no UPDATE/DELETE yet; pure append-only with snapshot
  isolation. Validates the read path.

**Phase 2 — UPDATE/DELETE via equality-delete files:**
- Hook rewrites: UPDATE expands to (INSERT new row + emit
  equality-delete row); DELETE emits equality-delete only.
- Verify pg_duckdb / DuckDB-iceberg can write equality-delete files
  through `raw_query`. If not, this is the next upstream patch.

**Phase 3 — vacuum / compaction worker:**
- ColdFront-side worker that periodically calls
  `duckdb.raw_query('CALL ice.system.rewrite_data_files(...)')`
  with the `xmax > min_active_reader_csn` filter.
- Cluster-wide reader-CSN watermark via Spock-replicated registry.

**Phase 4 — measurement and tuning:**
- Reproduce the multi-writer bench from
  [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md#concurrency--horizontal-scaling--the-bakery-protocol)
  with MVCC + rebase-retry. Confirm linear scaling.
- Storage bloat measurement on UPDATE-heavy workload.
- Read amplification with and without compaction.

## Comparison to alternatives

| Approach | Multi-writer scales | Cross-query consistency | Code change |
|---|---|---|---|
| Today (decoupled mode) | No (CAS serialization, dropped batches) | No | — |
| Writer-side rebase-retry only | Linear up to commit-rate ceiling | No | duckdb-iceberg ~100 lines |
| Sharded tables + UNION ALL | Linear, trivial | Per-shard only | trivial in coldfront; user rejected |
| DuckDB-iceberg branch support + Nessie | Per-branch parallelism | Per-branch only | duckdb-iceberg + catalog migration |
| Server-side rebase in Lakekeeper | Linear | No | Lakekeeper ~few-hundred lines |
| **MVCC layer (this doc)** | Linear | **Yes (full)** | **coldfront ~3–5× hook code + duckdb-iceberg rebase-retry** |

The MVCC layer is the only path that closes both gaps in a single
architecture. It is also the largest change.

## Open questions

- Are equality-delete files supported through `duckdb.raw_query`'s
  current API? If not, that's the next upstream patch.
- What is the cluster-wide `min_active_reader_csn` propagation
  latency budget? (Affects vacuum timeliness.)
- Does Spock cleanly replicate the `coldfront.node_id` GUC and
  `snowflake_seq` so a node can come up cold without coordinating?
- Failure mode: what happens if a node's clock jumps backwards (NTP
  step adjustment after long offline period)? Need a guard so
  `snowflake_now()` never returns a value <= the last one issued by
  the same node within the same epoch.
