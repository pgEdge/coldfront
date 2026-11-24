---
cwd: ../
---
# Exploring the Standalone Partitioner

The partitioner binary manages PostgreSQL range partitions without any cold
tier. If all you need is automated partition maintenance on stock PostgreSQL,
the partitioner is the whole product - no Iceberg, no DuckDB, no archiver cold
path.

The following table shows the three steps this demo performs:

| Step | What you will do |
|------|-----------------|
| [1. Create the demo table](#creating-the-demo-table) | Create a partitioned table with no partitions. |
| [2. Register and reconcile](#registering-and-reconciling) | Register the table with the partitioner and run one reconcile pass. |
| [3. Verify the partitions](#verifying-the-partitions) | Confirm that the pass created this month's partition and the next three. |

## Running This Demo in a Codespace

Start the stack as described in
[Starting the Stack in a Codespace](exploring_coldfront/index.md#starting-the-stack-in-a-codespace).
Then open this page from the Explorer; Runme opens the page as a notebook.
Click the triangle to the left of each cell, in order, from the first step to
the last.

## Running This Demo on Your Own System

Start the stack as described in
[Starting the Stack on Your Own System](exploring_coldfront/index.md#starting-the-stack-on-your-own-system).
Then run each step in order from the repository root, or from the
`coldfront-walkthrough` directory if you used the installer: paste each shell
command into a terminal, and paste each SQL block into a psql session that you
open with `psql postgresql://coldfront@localhost:5432/coldfront`. To have the
interactive guide run the same steps for you, run
`bash examples/walkthrough/guide.sh` from that directory and choose
`3) Partitioner`.

## Creating the Demo Table

Create a partitioned table with no existing partitions:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SET search_path = public;

CREATE TABLE part_demo (
    id   bigint GENERATED ALWAYS AS IDENTITY,
    ts   timestamptz NOT NULL,
    note text,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
```

## Registering and Reconciling

Register the table with the partitioner (monthly period, 12-month retention)
and run a reconcile pass. Both commands run inside the Compose network against
service name `db`:

```bash
# Register the table.
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  run --rm --no-deps --entrypoint partitioner archiver \
  register \
  --table part_demo \
  --period monthly \
  --retention "12 months"

# Run a reconcile pass to premake forward partitions.
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  run --rm --no-deps --entrypoint partitioner archiver
```

The partitioner needs no file: it connects from the `PG*` environment the
compose service sets and reads its tables from `coldfront.partition_config`.

## Verifying the Partitions

Each reconcile pass premakes the next three monthly partitions ahead of now
(three is the `register --premake` default) and ensures a partition covering
today always exists. Each pass also drops any partition older than the
retention period:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT count(*) AS partitions
FROM pg_inherits
WHERE inhparent = 'part_demo'::regclass;
```

A table registered with `--strategy detach` keeps its expired partitions as
standalone tables instead of dropping them. The
[Managing Partitioned Tables (CLI)](using_coldfront/index.md#managing-partitioned-tables-cli)
section describes the partition CLI and shows more `register` examples.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Distributed Demo](walkthrough_distributed.md) points two PostgreSQL
  nodes at one shared lake.
- The [Using ColdFront](using_coldfront/index.md) guide compares the tiered,
  decoupled, and standalone partitioned modes, and covers dropping Iceberg
  tables and the partition management CLI.
- The [Tearing Down the Stack](exploring_coldfront/index.md#tearing-down-the-stack) section
  describes how to stop the stack and remove its data.
