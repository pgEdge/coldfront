# Using ColdFront in Standalone Partitioned Mode

This mode needs only a working PostgreSQL instance, optionally in a Spock
mesh; it uses no Lakekeeper, no object store, no pg_duckdb, and no
coldfront extension. A database set up this way can gain the cold tier
later by following [Configuring ColdFront](configuration.md), [Configuring Lakekeeper](one_time_setup.md),
and [Configuring your Object Store](object_store.md). This page walks
through building and registering the `partitioner` binary, operating it
day to day, giving a time-partitioned table a real primary key, and
two-level sub-partitioning.

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

## Managing Partitioned Tables (CLI)

ColdFront's configuration lives in the server. **Per-table lifecycle** lives in
`coldfront.partition_config`, a name-keyed table that replicates by value
across a Spock mesh (like `tiered_views`/`archive_watermark`), so every node
reads identical config - no per-node file syncing. The cold-store credential
lives in `coldfront.storage_secret` and the catalog in the
`coldfront.warehouse` and `coldfront.lakekeeper_endpoint` settings. The
**connection** alone comes from outside, from the libpq environment or
`--dsn`, as for psql. Manage the lifecycle table with the CLI below (both
`partitioner` and `archiver` expose these subcommands; with no subcommand they
do their normal reconcile/archive run).

`register` is the primary way to manage tables: one command adds or adopts one
table, validated on the spot. `import` and `export` are bulk helpers for
(re)configuring a machine - write a deployment YAML into a fresh server, or
dump the live config to git and replay it on another node - not the day-to-day
path. A YAML passed to anything but `import` is checked against the server and
refused if it disagrees in any value.
`register` and `import` run the full validation; `set` re-runs it only when it
changes the partition period or column, `hot_period`, `retention_period` or the
sub-partition source, and otherwise relies on the table's CHECK constraints.

The data lifecycle is **hot PG → `hot_period` → cold Iceberg →
`retention_period` → dropped** (tiered) or **hot PG → `retention_period`
→ dropped** (partition-only). Setting `hot_period` makes a table tiered;
omitting it makes it partition-only.

### What Registration Refuses

`register` and `import` run the same validation, so a table that one rejects
cannot be added by the other; `set` re-runs it when it changes a validated
field. Registration fails when:

- any relation in the partition tree is `UNLOGGED`, because that data is
  truncated after a crash and replicates nowhere, so archiving it would
  preserve rows PostgreSQL never promised to keep.
- the table has a `DEFAULT` partition. Rows the `DEFAULT` partition catches
  have no time bounds, so they can never be tiered or expired, and PostgreSQL
  refuses `DETACH PARTITION ... CONCURRENTLY` for every partition of a table
  that has one, which is how partitions are expired. The partition's mere
  existence is enough; it does not have to hold any rows. Move any rows the
  `DEFAULT` partition holds into real partitions and detach it.
- the name differs only by case from an already-registered table. PostgreSQL
  keeps `public."Events"` and `public.events` apart, but DuckDB matches
  identifiers case-insensitively even when they are quoted, so both names would
  resolve to one Iceberg table and overwrite each other.
- the name starts with an underscore, which is reserved for the tiered hot
  table.
- the name leaves no room for the generated partition suffix: 53 bytes for
  monthly and 50 for daily, within PostgreSQL's 63-byte identifier limit.
- a tiered table has a column whose type has no Iceberg equivalent (see
  [Supported Column Types](supported_types.md)). Every column
  goes through the same type map the cold tier itself uses, so the answer
  comes back at the prompt rather than hours later from cron, and the
  refusal names the column. Partition-only tables are exempt: nothing about
  them reaches Iceberg, so their column types are PostgreSQL's business
  alone.
- a tiered table has a column whose name DuckDB parses as a keyword, such as
  `by`, `at` or `show` (see [Caveats](caveats.md)). The archiver checks
  the names again before it tiers or expires data, so a column added after
  registration is refused there, before any table or data reaches Iceberg.

Registration validates the table as it is at that moment, not continuously.
Adding a `DEFAULT` partition to an already-registered table is therefore not
caught then; the next archiver run fails while reading that table's partition
bounds.

Other unusual bounds are supported rather than refused. Partitions open at
either end (`MINVALUE`, `MAXVALUE`, `infinity`) are handled, as is PostgreSQL's
full timestamp range, from 4713 BC through year 294276.

`hot_period` and `retention_period` are native PostgreSQL `interval`s - use any
interval syntax (`1 month`, `90 days`, `1 year 2 mons`, `5 years`). Expiry
boundaries are computed with calendar-accurate interval arithmetic
(`now() - period`: real months, leap years), and `retention_period` must exceed
`hot_period` (validated at `register`/`set` time).

The following table describes the CLI subcommands:

| Command | Purpose |
|---|---|
| `register` | Adds or adopts a table, and validates that the PRIMARY KEY covers the partition key. |
| `list` | Shows the managed tables and their lifecycle. |
| `set` | Changes fields, or disables or enables a table with `--disable`/`--enable`. |
| `remove` | Stops managing a table; the table itself is left intact. |
| `import` | Writes a deployment YAML into the server once: its `archiver.tables` as rows, validated as `register` validates each table, and its `s3:` or `azure:` stanza as the storage secret. |
| `export` | Dumps the active (enabled) config to YAML or SQL, as a git-reviewable backup to replay on another node. |

The following examples register, inspect, and change managed tables:

```bash
# Partition-only: keep 3 future partitions, drop those older than 12 months.
partitioner register --table events --period monthly --retention "12 months"

# Partition-only, but DETACH (preserve) expired partitions instead of dropping them.
partitioner register --table events --period monthly \
    --retention "12 months" --strategy detach

# Tiered: tier to cold Iceberg after 1 month, then drop cold data after 5 years.
archiver register --table events --period monthly \
    --hot-period "1 month" --retention "5 years"

# id mode - a real single-column PRIMARY KEY (id) on a snowflake-keyed table.
partitioner register --table events --period monthly \
    --column id --part-mode id --id-scheme snowflake --retention "1 year"

# 2-level LIST(region) → RANGE(ts), tiered; region values come from a table.
archiver register --table regional --period monthly --column ts \
    --hot-period "1 month" --sub-values-source "SELECT region FROM regions"

partitioner list                                   # what's managed
partitioner set    --table events --retention "24 months"
partitioner set    --table events --disable        # pause (keeps the row)
partitioner remove --table events                  # unregister, keep the table
partitioner import --config deploy.yaml            # write a deployment YAML into the server once
partitioner export > managed.yaml                  # active config, git-reviewable (--format sql for INSERTs)
```

Run `partitioner` (or `archiver`) with `help` or `--help` for the command
overview, and with no arguments for its normal run; every subcommand has a
detailed `--help` with worked examples. The write commands accept
`--print-sql` (emit the SQL without running it - review/commit it; `import`
prints its table `INSERT`s); `register` and `import` also accept `--dry-run`.
`set --enable`/`--disable` (mutually exclusive) pause/resume a table without
removing it; a disabled table is skipped by reconcile and omitted from
`export`. Per table, only the cadence and a lifecycle boundary (`hot_period` or
`retention_period`) are required; `partition_column` is auto-detected from
`pg_catalog` for flat tables (required for 2-level). `register` writes a row
whose `CHECK` constraints enforce the lifecycle rules at write time.

The subcommands also take the following connection and table flags:

- `--dsn` takes a PostgreSQL connection string on every subcommand. Without
  it the connection comes from the libpq environment, as for psql.
- `--config` names a deployment YAML. On `import` it is required, since it
  names the file to write into the server. On any other subcommand the file is
  checked against the server, value by value, and refused if it disagrees; its
  `postgres.dsn` connects when `--dsn` is unset.
- `--schema` (default `public`) names the table's schema on `register`, `set`
  and `remove`.
- `--premake` (default `3`) sets on `register` how many future partitions are
  kept ahead of now, stored as `future_partitions`.

`set` changes only the fields whose flags are passed: `--period`, `--column`,
`--premake`, `--hot-period`, `--retention`, `--sub-values-source` and
`--strategy`, each taking the same value as on `register`. An empty value
clears the field, so `--hot-period ""` makes a tiered table partition-only and
hands it to the partitioner. A change that leaves neither a `hot_period` nor a
`retention_period` is refused.

For managing tables, the archiver and partitioner read the managed set only
from `coldfront.partition_config`. `register` adds one table; `import` adds
every table in a YAML `archiver.tables` list. Both write through the same
validation (the PK must cover the partition key; `retention` must exceed
`hot_period`), so an imported table is checked exactly as a registered one.
`export` dumps the active rows back to YAML or SQL for git.

The archiver manages only the rows that have a `hot_period`, and the
partitioner only the rows without one, so each table belongs to one binary. A
run that finds none of its own rows exits non-zero with
`no tables in coldfront.partition_config`, naming the `register` and `import`
commands that add one.

In an `archiver.tables` entry, `source_schema` names the table's schema and
defaults to `public`. `source_table` also accepts the `schema.table` form, and
an explicit `source_schema` takes precedence over that prefix.
`future_partitions` defaults to `3`, as `--premake` does on `register`.

