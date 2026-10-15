# Using ColdFront in Standalone Partitioned Mode

This mode needs only a working PostgreSQL instance, optionally in a Spock mesh;
it uses no Lakekeeper, no object store, no pg_duckdb, and no `coldfront`
extension. A database set up this way can gain the cold tier later by following
[Configuring ColdFront](configuration.md),
[Configuring Lakekeeper](configure_lakekeeper.md), and
[Configuring your Object Store](object_store.md). This page walks through
building and registering the `partitioner` binary, operating it day to day,
giving a time-partitioned table a real primary key, and two-level
sub-partitioning. The management CLI that the partitioner shares with the
archiver is described in
[Managing Partitioned Tables (CLI)](using_coldfront/index.md#managing-partitioned-tables-cli).

**You do not need Iceberg at all.** If automated PostgreSQL partition
maintenance is all you want - declarative time- or id-based RANGE partitioning
with a premade forward window and automatic age-out of old partitions -
ColdFront's `partitioner` binary is the whole product: stock PostgreSQL (or a
Spock mesh), no cold tier, no DuckDB, no Iceberg, nothing to preload. Each
invocation makes one reconcile pass per managed table: premake the forward
window, ensure the partition covering *now* exists, and detach-then-drop
partitions past retention (`DETACH ... CONCURRENTLY`, never a bare `DROP` of
attached data). Build the partitioner with `make build` and run it from cron:

```bash
go build -o bin/partitioner ./cmd/partitioner   # or: make build
./bin/partitioner
```

A database set up this way can gain the cold tier later:
`CREATE EXTENSION coldfront` adopts the `coldfront.partition_config` the
partitioner created, registrations included.

The partitioner connects from the libpq environment or `--dsn`, like psql, and
reads its tables from `coldfront.partition_config`; it needs no file. A
partition-only deployment has no cold tier: a table with a `hot_period`
belongs to the archiver, and the partitioner leaves it alone.

Register each managed table in `coldfront.partition_config`:

```bash
./bin/partitioner register --table events \
    --period monthly --retention "12 months" \
    --strategy drop   # drop (DETACH+DROP, destroy; default)
                      #   | detach (DETACH only, keep as a
                      #     standalone table - data preserved)
```

## Operating the Partitioner

Schedule one pass per period or more often - a cron line, or a systemd
`oneshot` service plus timer (systemd then reports a failed pass as a failed
unit, so alerting is free):

```text
17 * * * * postgres PGDATABASE=mydb /usr/local/bin/partitioner >> /var/log/coldfront-partitioner.log 2>&1
```

Keep the following operational behavior in mind when scheduling it:

- The exit code is `0` when every table reconciled (a self-healed *behind*
  condition still exits `0`) and non-zero when at least one table failed
  (`N table(s) failed`), each failure logged with a `[table]` prefix (the bare
  table name) followed by the schema-qualified error. Alert on a non-zero exit
  code.
- If a table already has a *past* partition but none covers *now* at the start
  of a pass (a lagging cron - live inserts had no home), the pass heals the
  table (creates the current partition), logs a `WARNING (self-healed)` line,
  and still exits `0`. Monitor for that warning in the log rather than via the
  exit code, and widen `future_partitions` or run more often. A fresh table
  (only just-premade future partitions) is **not** behind: its first reconcile
  succeeds cleanly.
- With the default `expiration_strategy: drop`, expiry is
  `DETACH CONCURRENTLY` + `DROP TABLE` - the data is **gone**, so back up
  before shrinking `retention_period`. Set `expiration_strategy: detach` to
  instead leave the expired partition as a standalone table (detached from the
  parent, data preserved) and reclaim it yourself. A partition is expired only
  once its *entire* range is older than `now − retention_period`, computed
  with calendar-accurate PostgreSQL interval arithmetic (a real month, leap
  years correct). `detach` is partition-only - the tiered archiver always drops
  after exporting to cold.

## Primary Keys on Time-Partitioned Tables (id Mode)

PostgreSQL requires a unique index to include the partition key, so a plain
`PRIMARY KEY (id)` is impossible on a table partitioned by a separate `ts`
column. Partition instead by RANGE on a **time-ordered id** and the partition
key *is* the key - a single-column `PRIMARY KEY (id)`:

```yaml
    - source_table: events
      partition_column: id
      partition_period: monthly
      retention_period: 12 months
      part_mode: id
      id_scheme: snowflake             # snowflake | uuidv7
```

`uuidv7` reads the RFC 9562 leading-millisecond timestamp; `snowflake` decodes
the pgEdge Snowflake extension's layout. Either way the manager computes the
month/day partition bounds as id values, so id-order equals time-order and the
forward/retention schedule is unchanged.

## Two-Level (LIST → RANGE) Sub-Partitioning

For a table partitioned by `LIST (region)` whose children are themselves
`RANGE`-partitioned by time, add a `sub_partition` block. `values_source` is a
query returning the current level-1 values; the manager provisions and
maintains a RANGE sub-tree under each, creating sub-trees for newly appearing
values automatically:

```yaml
    - source_table: events
      partition_column: ts             # the level-2 RANGE column
      partition_period: monthly
      retention_period: 12 months
      sub_partition:
        values_source: "SELECT code FROM regions"
```

Each level-1 child is named `<table>_<value>`, with the value lowercased and
every character outside `a-z`, `0-9` and `_` replaced by `_`. That name must
fit in 50 bytes, which leaves room for the daily leaf suffix within
PostgreSQL's 63-byte identifier limit. A pass that meets a longer name fails,
for tiered two-level tables as well. The partitioner and the archiver also
fail a pass in which two values map to the same name.
