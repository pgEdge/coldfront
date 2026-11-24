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
| [1. Creating the demo table](#creating-the-demo-table) | Create a partitioned table with no partitions. |
| [2. Registering and reconciling](#registering-and-reconciling) | Register the table with the partitioner and run one reconcile pass. |
| [3. Verifying the partitions](#verifying-the-partitions) | Confirm that the pass created this month's partition and the next three. |

## Running This Demo in a Codespace

Create the Codespace as described in
[Running the Walkthrough in a Codespace](exploring_coldfront/index.md#running-the-walkthrough-in-a-codespace).
The Codespace opens the Exploring ColdFront page; click Exploring the
Standalone Partitioner to open this page as a notebook. To run a cell, click
the triangle to the left of the cell.

<div class="admonition hint">
<p class="admonition-title">Hint</p>
<p>The first time you start the stack, Docker builds the images, which can take
several minutes. If you start the stack again, Docker reuses the images and the
stack starts within a minute.</p>
</div>

Run the following cell to start the containers:

```bash
docker compose -f examples/walkthrough/docker-compose.yml \
  up -d --build
docker compose -f examples/walkthrough/docker-compose.yml \
  build archiver
```

Then click the triangle beside each cell that follows, in order.

## Running This Demo on Your Own System

Prepare your system as described in
[Running the Walkthrough Manually](exploring_coldfront/index.md#running-the-walkthrough-manually),
and then work from the repository root, or from the `coldfront-walkthrough`
directory if you used the installer.

As you work through the walkthrough:

- paste each shell command into a terminal.
- paste each SQL block into a psql session that you open with
  `psql postgresql://coldfront@localhost:5432/coldfront`.

<div class="admonition hint">
<p class="admonition-title">Hint</p>
<p>The first time you start the stack, Docker builds the images, which can take
several minutes. If you start the stack again, Docker reuses the images and the
stack starts within a minute.</p>
</div>

Use the following commands to start the containers:

```bash {"ignore":"true"}
docker compose -f examples/walkthrough/docker-compose.yml \
  up -d --build
docker compose -f examples/walkthrough/docker-compose.yml \
  build archiver
```

If port 5432, 8181, or 8333 is already in use on your host, see
[Changing the Demo Ports](exploring_coldfront/index.md#changing-the-demo-ports).

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

The partitioner needs no file. It connects from the `PG*` environment that the
Compose service sets, and reads its tables from `coldfront.partition_config`.

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

## When You Finish

When you finish the demo, use the following command to stop the stack and
remove its data. Each demo starts its own stack, so the next demo you run
starts fresh:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  down -v
```

The `-v` flag removes the stack's data volumes; omit the flag to keep the data
for a later session.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Using ColdFront](using_coldfront/index.md) guide compares the tiered,
  decoupled, and standalone partitioned modes, and covers dropping Iceberg
  tables and the partition management CLI.
- The [Architecture](architecture_guides/index.md) overview explains the shared
  mechanics and links to the per-mode deep dives.
