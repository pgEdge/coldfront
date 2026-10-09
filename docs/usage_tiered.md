# Using ColdFront in Tiered Mode

Before you begin, configure PostgreSQL, Lakekeeper, and your object store by
following [Configuring ColdFront](configuration.md), [Configuring Lakekeeper](one_time_setup.md),
and [Configuring your Object Store](object_store.md); tiered mode archives
aging partitions to the cold tier those guides set up. This page walks
through creating a tiered table, registering it with the archiver, running
the archiver, and the lifecycle that follows, then details two restrictions
tiered tables carry: inbound foreign keys and 2-level tiered tables.

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

Then tell the archiver about the table, either with a deployment YAML:

```yaml
s3:
  endpoint: "seaweedfs:8333"
  access_key: "admin"
  secret_key: "adminsecret"
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      hot_period: "1 month"
```

```bash
./bin/archiver import --config config.yaml
```

or by registering the table directly:

```bash
./bin/archiver register --table events \
    --period monthly --hot-period "1 month"
# optional: --retention "5 years" DROPs cold data past that age
# (must exceed --hot-period; omit = keep forever)
```

See [Writing ColdFront's Configuration](configuration.md#writing-coldfronts-configuration)
for how `register` and `import` write this, and what the server checks, and
[Managing Partitioned Tables (CLI)](usage_partitioner.md#managing-partitioned-tables-cli)
for `list`, `set`, `remove`, and `export`, which the archiver shares with the
partitioner.

Run the archiver (typically via cron):

```bash
./bin/archiver
```

`--version` prints the version that `make build` stamps from `git describe`
(the release tag, or the commit it was built from) and exits; a plain
`go build` prints `unknown`. The partitioner and compactor accept the same
flag.

The archiver also accepts `--debug-export-delay`, a test-only Go duration
(such as `5s`) that holds each partition's capture window open between the
bulk export and the replay, so that a test can race concurrent writes into it.
Leave it unset in production.

The first run that finds a partition older than `hot_period` renames `events`
→ `_events`, creates the unified view `events`, and registers it; until then
the archiver only premakes partitions, and the table stays a plain partitioned
table. From then on every cycle (1) tiers partitions older than `hot_period`
from hot PG to cold Iceberg and advances the watermark, and (2) if
`retention_period` is set, drops cold Iceberg rows older than it. The data
lifecycle is **hot → `hot_period` → cold → `retention_period` → gone**;
omit `retention_period` to keep cold data forever.

To remove a tiered table's cold tier entirely rather than waiting out its
retention period, see [Dropping an Iceberg Table](usage_decoupled.md#dropping-an-iceberg-table-both-modes).

## Inbound Foreign Keys

A tiered table cannot be the target of an enforced foreign key from another
table over its archivable range. Archiving physically removes the rows from
PostgreSQL (export to Iceberg, then `DETACH` + `DROP` the partition), and
PostgreSQL cannot enforce a foreign key against the cold tier. So the `DETACH`
is refused (SQLSTATE 23503) and the archiver fails fast, naming the blocking
constraint.

This is inherent, not an edge case: referencing rows rarely have a hot-only
lifecycle. They usually outlive the partition they point at, so the foreign key
still pins those rows in PostgreSQL by the time the partition ages into the
cold tier.

The foreign key is fundamentally incompatible with archiving the rows it
references, so before archiving such a table, drop it:

```sql
ALTER TABLE event_logs DROP CONSTRAINT event_logs_events_fkey;
```

Better still, do not point an enforced foreign key at a tiered table over its
archivable range in the first place.

## 2-Level (LIST → RANGE) Tiered Tables

A table partitioned `LIST (region) → RANGE (ts)` can be tiered too - the same
`sub_partition` block as [Using ColdFront in Standalone Partitioned Mode](usage_partitioner.md),
so a partition-manager-managed table can be "upgraded" to tiered by pointing
the archiver at it:

```yaml
    - source_table: regional
      partition_column: ts          # the RANGE (time) column - required for 2-level
      partition_period: monthly
      hot_period: 1 month
      # retention_period: 5 years   # optional cold expiry (region-agnostic, by ts)
      sub_partition:
        values_source: "SELECT region FROM regions"
```

One Iceberg table holds every region (region is an ordinary column); the
archiver tiers leaves a whole `ts` period at a time across **all** regions
before advancing the shared hot/cold watermark, so a period only becomes cold
once it is cold for every region. `id` mode is not supported in tiered mode
(the cold tier is time-keyed). For why the ordering works that way, see the
[Two-level tiering](architecture_tiered.md#two-level-list-range-tiering)
section of the Tiered Mode page.
