# Using ColdFront

ColdFront offers three operating modes. Pick one per table; tables in
different modes can coexist in the same database. The following table
compares tiered and decoupled modes, which use the cold Iceberg tier:

| | Tiered (hot + cold) | Decoupled (iceberg-only) |
|---|---|---|
| Where rows live | Recent rows are hot in the PG heap, and archived rows are cold in Iceberg. | Every row is in Iceberg. |
| Setup | Create a partitioned table and let the archiver convert it on the first run that finds a partition older than `hot_period`. | One SQL call, `coldfront.create_iceberg_table(...)`, sets up the table. |
| Archiver | The archiver is required; it runs from cron and moves old partitions to cold. | The archiver is not used. |
| Best when | The workload has a recent-row OLTP part that benefits from PG indexes and transactional ergonomics. | The workload is purely analytic or append-mostly, and you want zero PG storage and stateless compute. |

Once a tiered or decoupled table exists, **the SQL surface is identical**:
`SELECT`, `INSERT`, `UPDATE`, `DELETE` all work normally against the relation
name (e.g. `events`), except that a write touching the cold tier rejects
`RETURNING`, as the following examples show:

```sql
-- Reads - pg_duckdb handles the iceberg side; PG handles the heap side
SELECT count(*) FROM events;
SELECT id, status, data->>'k' FROM events WHERE ts >= '2026-04-01';

-- Inserts, updates, and deletes all go through the coldfront C hook,
-- which rewrites the query into one PG-set-based statement (hot side)
-- + duckdb.raw_query calls (cold side). For iceberg-only mode every write
-- goes cold; for tiered mode the hook splits by ts vs the watermark.
INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{"k":1}');
UPDATE events SET status = 'fixed' WHERE id = 123;
DELETE FROM events WHERE ts < '2025-01-01';

-- Bulk INSERT shapes: the source is read once, the hot rows are one
-- set-based INSERT and the cold rows are written in batches:
INSERT INTO events (ts, status, data) VALUES (...), (...), (...);
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM staging;
INSERT INTO events (ts, status, data) SELECT now() + i*'1s'::interval, 'ok', '{}'
                                       FROM generate_series(1, 1000) i;
-- A WITH clause works in both positions; a nested INSERT takes no RETURNING:
WITH moved AS (DELETE FROM staging RETURNING ts, status, data)
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM moved;
WITH i AS (INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{}'))
SELECT 1;
-- COPY FROM loads the same way, one INSERT per cold_write_batch_size rows:
COPY events (ts, status, data) FROM '/path/to/events.csv' WITH (FORMAT csv);

-- Transactions work; ROLLBACK undoes Iceberg writes too
BEGIN;
  UPDATE events SET status = 'pending' WHERE id = 1;
  SELECT status FROM events WHERE id = 1;   -- sees 'pending' if row 1 is hot
ROLLBACK;
SELECT status FROM events WHERE id = 1;     -- back to whatever it was
```

Follow the guide for the mode you want:

- [Using ColdFront in Tiered Mode](../usage_tiered.md) archives aging
  partitions to Iceberg while recent rows stay in the PostgreSQL heap.
- [Using ColdFront in Decoupled Mode](../usage_decoupled.md) keeps every row
  in Iceberg from the start.
- [Using ColdFront in Standalone Partitioned Mode](../usage_partitioner.md)
  manages plain PostgreSQL partitions with no cold tier at all.

Operational topics shared across modes - caveats, vended credentials,
supported types, and distributed (mesh) setup - are documented under
Administration, starting with [Caveats](../caveats.md).

## Dropping an Iceberg Table

`coldfront.drop_iceberg_table()` removes the Iceberg table backing a registered
relation. The function is the only sanctioned way to do so: a plain
`DROP TABLE` or `DROP VIEW` on a registered relation stays blocked, because it
would leave the cold tier behind with nothing pointing at it.

The call takes the schema, the table, and an explicit purge decision:

```sql
-- drop the catalog entry and delete the stored objects
SELECT coldfront.drop_iceberg_table('public', 'events', true);

-- drop the catalog entry and leave the objects in the object store
SELECT coldfront.drop_iceberg_table('public', 'events', false);
```

What remains afterwards depends on the mode, and the call reports which path it
took:

- in decoupled mode the Iceberg table is the whole relation, so nothing remains
  in PostgreSQL.
- in [tiered mode](../usage_tiered.md) the Iceberg table is the cold tier, so the
  cold tier is removed and the hot table returns under the relation's own
  name, as an ordinary partitioned table holding the data that had not yet
  aged out.

In tiered mode the call also deletes the table's `partition_config` row, which
stops the archiver from tiering it again on the next run.

There is no default for the purge argument, because the two outcomes are
irreversible in opposite directions. Passing `true` deletes the Parquet and
metadata objects, which for the cold tier are the only copy of that data.
Passing `false` keeps those objects but removes the catalog entry that
ColdFront would need to reach them again, so nothing reclaims them afterwards;
use it when another system is taking ownership of the files.

ColdFront has no guard of its own against dropping the wrong table. The
preventive control lives in Lakekeeper: table protection has to be enabled
manually, per table, and a protected table cannot be dropped at all, whether or
not purge is requested. This function cannot override a hold.

Deletion is not instantaneous. The catalog entry disappears with the call, and
Lakekeeper's own background queue removes the objects shortly afterwards, so a
listing taken immediately after the call can still show them.

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
`register` and `import` run the full
validation. `set` checks every value of the row that it would leave; it re-runs
the rest of the validation only when it changes the partition period or column,
`hot_period`, `retention_period` or the sub-partition source.

The data lifecycle is **hot PG → `hot_period` → cold Iceberg →
`retention_period` → dropped** (tiered) or **hot PG → `retention_period`
→ dropped** (partition-only). Setting `hot_period` makes a table tiered;
omitting it makes it partition-only.

### What Registration Refuses

`register` and `import` run the same validation, so a table that one rejects
cannot be added by the other; `set` re-runs it when it changes a validated
field. Registration fails when:

- a setting has a value that the table's `CHECK` constraints refuse. The
  refusal names the flag, or on `import` the key, and the values that the
  setting accepts; `set` checks the row that its change would leave.
  Registration refuses:

    - a `--period` other than `monthly` or `daily`.
    - a `--premake` below 1.
    - a `--part-mode` other than `timestamp` or `id`.
    - an `--id-scheme` other than `uuidv7` or `snowflake`, or one without
      `--part-mode id`.
    - `--part-mode id` without an `--id-scheme`.
    - a `--strategy` other than `drop` or `detach`.
    - `--part-mode id` or `--strategy detach` with a `--hot-period`.
    - a `--sub-values-source` without a `--column`.
    - a table with neither a `--hot-period` nor a `--retention`.

- `--column`, or `partition_column` on `import`, names a column that is not the
  table's partition key. On a two-level table, registration refuses only a
  column that the table lacks. The refusal names the flag or key and, for a
  flat table, the table's partition key.
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
  [Supported Column Types](../supported_types.md)). Every column
  goes through the same type map the cold tier itself uses, so the answer
  comes back at the prompt rather than hours later from cron, and the
  refusal names the column. Partition-only tables are exempt: nothing about
  them reaches Iceberg, so their column types are PostgreSQL's business
  alone.
- a tiered table's name, or the name of one of its columns, is one DuckDB
  parses as a keyword, such as `by`, `at` or `show` (see [Caveats](../caveats.md)).
  The archiver checks the column names again before it tiers or expires data;
  it refuses a column added after registration before any table or data reaches
  Iceberg.

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
`pg_catalog` for flat tables (required for 2-level). `register` checks the
lifecycle rules before it writes the row, and the table's `CHECK` constraints
enforce them again at write time.

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
