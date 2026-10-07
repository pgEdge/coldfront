# Performing Daily Operations with ColdFront

This guide walks through the full lifecycle of a ColdFront deployment,
from getting a cluster running to the ongoing maintenance a live
deployment needs.

## Getting ColdFront Running

This is covered in detail in
[Installing and Configuring ColdFront](installation.md):

- Install via package (`pgedge-coldfront` and its dependencies) or build
  from source/Docker.
- Configure `postgresql.conf` (`shared_preload_libraries`, the `duckdb.*`
  extension-loading settings, `coldfront.warehouse`/`lakekeeper_endpoint`).
- Stand up Lakekeeper, bootstrap it, create a warehouse pointing at your
  object store, pre-create the namespace.
- `CREATE EXTENSION pg_duckdb; CREATE EXTENSION coldfront;`, then
  `coldfront.set_storage_secret(...)` once.

## Using ColdFront Day to Day

Each table is assigned one mode at creation time:

- **Tiered**: an ordinary partitioned Postgres table. Recent partitions
  stay hot in Postgres; the archiver (run from cron) ages old
  partitions out to Iceberg once they pass `hot_period`. Reads
  transparently union hot and cold data.
- **Decoupled**: `coldfront.create_iceberg_table(...)` - the whole
  table lives in Iceberg from row one, with no archiver involved.
- **Standalone partitioner**: no cold tier at all. The partitioner
  alone manages Postgres range partitions - premaking forward
  partitions and dropping or detaching expired ones - with no Iceberg
  or DuckDB involved.

Regardless of mode, normal `SELECT`, `INSERT`, `UPDATE`, and `DELETE`
statements work against the relation; a write that touches cold data
just can't use `RETURNING`.

## Scheduling the Background Jobs

ColdFront relies on three background jobs, all run from cron:

- **archiver** - tiers old partitions to cold storage (tiered mode only).
- **partitioner** - premakes upcoming partitions, retires expired ones
  (every mode that uses partitioning).
- **compactor** - cold-tier housekeeping: compaction, snapshot expiry,
  orphan-Parquet-file removal.

## Keeping the Deployment Healthy

A few things need periodic attention once a deployment is running:

- `coldfront.grant_app_access('role')` has to be re-run after creating,
  adopting, or tiering a table, since `grant_app_access` derives its
  grants from the registry at the moment it runs.
- Lakekeeper's `LAKEKEEPER__PG_ENCRYPTION_KEY` must stay stable and backed
  up - losing it makes every stored credential unrecoverable.
- In a distributed (Spock mesh) deployment, the bakery protocol serializes
  concurrent cold writes across nodes using replicated tickets
  (`coldfront.claims`/`claim_acks`); at steady state that ledger should be
  empty, and half of `wal_sender_timeout` must stay below
  `coldfront.peer_alive_window_ms`, or a claim refuses to run.
- For compliance environments, `coldfront.set_storage_secret_vended()`
  avoids storing a credential at all - Lakekeeper vends short-lived STS
  credentials per table instead.
