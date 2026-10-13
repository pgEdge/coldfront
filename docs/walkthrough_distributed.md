---
cwd: ../
---
# Exploring Distributed Mode

Distributed mode points two or more PostgreSQL nodes at the *same* lake. The
nodes form an active-active [Spock](https://github.com/pgEdge/spock) mesh; the
table data lives once, in Iceberg, and each node adds query and write capacity
over that one shared copy. A write on one node is readable on the other with
nothing copied between them, and concurrent cold writes from different nodes
are serialized cluster-wide so they never collide.

This demo uses a different stack from the single-node walkthrough - two
`MESH=on` nodes (`db1`, `db2`) plus a shared Lakekeeper and object store. The
interactive guide automates the whole switch. It first removes the single-node
stack and its volumes with `docker compose down -v`, since a laptop rarely has
room for both, so the data from the single-node demos does not survive the
switch:

> **This demo is not click-runnable.** It needs a different two-node stack and
> separate psql sessions against each node (`db1` on port 5442, `db2` on 5443),
> so the blocks below are shown for reading and hand-pasting. The easiest way
> to run it is the interactive guide:

```bash {"ignore":"true"}
bash examples/walkthrough/guide.sh   # then choose: 4) Distributed
```

The sections below show what that option does, so you can follow along or
reproduce it by hand.

## Bringing Up the Two-Node Mesh

Start the mesh stack, then form the Spock mesh - create a node on each member,
subscribe each to the other, and set up the cold-write coordination on both.
First, start the mesh stack and build its images:

```bash {"ignore":"true"}
docker compose -f examples/walkthrough/docker-compose.mesh.yml up -d --build
```

If port 5442, 5443, 8191, or 8343 is already in use on your host, set
`COLDFRONT_MESH_PG1_PORT`, `COLDFRONT_MESH_PG2_PORT`, `COLDFRONT_MESH_LK_PORT`,
or `COLDFRONT_MESH_S3_PORT` before `up`.

Next, run the `curl` block from
[Setting Up the Stack](walkthrough.md#setting-up-the-stack) with port 8191 in
place of 8181. That creates the `wh` warehouse and `public` namespace on the
mesh's own Lakekeeper.

Then create the extensions and form the mesh, running each statement on the
node its comment names:

```sql {"ignore":"true"}
-- On BOTH nodes - create the extensions. The container preloads the libraries
-- (shared_preload_libraries) but does not run CREATE EXTENSION, so the SQL
-- objects (the spock schema, coldfront functions) do not exist until you do:
CREATE EXTENSION IF NOT EXISTS snowflake;
CREATE EXTENSION IF NOT EXISTS spock;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- Create BOTH nodes first: a subscription can only be created once its
-- provider is already a spock node, so both node_create calls must run
-- before either sub_create.
-- On db1:
SELECT spock.node_create('db1', 'host=db1 user=coldfront dbname=coldfront port=5432');
-- On db2:
SELECT spock.node_create('db2', 'host=db2 user=coldfront dbname=coldfront port=5432');
-- Then subscribe each node to the other (order between these two does not matter):
-- On db1:
SELECT spock.sub_create('sub_db1_from_db2', 'host=db2 user=coldfront dbname=coldfront port=5432');
-- On db2:
SELECT spock.sub_create('sub_db2_from_db1', 'host=db1 user=coldfront dbname=coldfront port=5432');

-- On BOTH nodes - wait for the subscription to sync, then put the replicated
-- ColdFront tables in the repset and set the cold-store secret, before any
-- cold write:
SELECT spock.sub_wait_for_sync(sub_name) FROM spock.subscription;
SELECT coldfront.ensure_replicated();
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
```

The nodes reach each other over the Compose network (service names `db1`/`db2`,
port 5432). The bakery replicates only small coordination metadata between
nodes - never the table data, which stays in the lake. The `set_storage_secret`
call is what lets each node's DuckDB write Parquet to the shared object store;
without it, cold writes fail to authenticate.

## Seeing the Mesh

Both nodes are present, each subscribed to the other:

```sql {"ignore":"true"}
SELECT node_name FROM spock.node ORDER BY node_name;   -- db1, db2
SELECT sub_name  FROM spock.subscription;              -- one per node
```

## Writing on One Node, Reading on the Other

Create a lake-native table on `db1` and register it on `db2` as well (the call
is idempotent and the registry is keyed by name, so each node ends up with an
identical local view):

```sql {"ignore":"true"}
-- On db1, then on db2 - same call:
SELECT coldfront.create_iceberg_table(
  'public', 'events_lake',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},
    {"name":"status","type":"text"},{"name":"data","type":"jsonb"}]'::jsonb
);
```

Write three rows on `db1`, then read them back on `db2`:

```sql {"ignore":"true"}
-- db1:
INSERT INTO events_lake VALUES
  (1, now(), 'ok',   '{"n":"db1"}'),
  (2, now(), 'ok',   '{"n":"db1"}'),
  (3, now(), 'warn', '{"n":"db1"}');

-- db2 - a different node, which stored none of this data:
SELECT id, status, data->>'n' AS written_by FROM events_lake ORDER BY id;
SELECT relkind, pg_size_pretty(pg_relation_size('events_lake')) AS pg_bytes
FROM pg_class WHERE relname = 'events_lake';   -- v, 0 bytes
```

`db2` returns every row `db1` wrote and stores zero bytes for the table - it
reads straight from the shared lake. That is the point of distributed mode: add
a node for compute over one copy of the data, with no storage to replicate.

## Serializing Concurrent Writes (The Bakery)

Two nodes committing the same Iceberg table at once would normally collide -
the catalog rejects the second commit with a `409 Conflict` and the application
has to retry. ColdFront's bakery protocol prevents that: each cold write takes
a globally-ordered ticket (replicated via Spock, verified in the TLA+ model
under `docs/formal/`) and waits its turn.

The bookkeeping is ordinary rows in `coldfront.claims` and
`coldfront.claim_acks`, and a write's commit clears them, so the way to read
them is to hold a transaction open. In one session on `db1`:

```sql {"ignore":"true"}
BEGIN;
INSERT INTO events_lake VALUES (301, now(), 'held', '{"n":"db1"}');
-- leave the transaction open
```

In a second session, the claim is on `db1`, keyed by a ticket that also names
the issuing node (a Snowflake id), and it is already on `db2`: the claim is
written over its own connection and committed at once, so it replicates while
the transaction that took it is still open:

```sql {"ignore":"true"}
-- On db1, then on db2 - the same row on both:
SELECT ticket, snowflake.get_node(ticket) AS issued_by_node, iceberg_table
FROM coldfront.claims;
```

`db2` acknowledges the ticket and the ack replicates back. A writer commits
only once every peer has acked its ticket, which is what orders writers across
nodes (the Ricart-Agrawala rule):

```sql {"ignore":"true"}
-- On db1:
SELECT ticket, ack_from_name AS acked_by FROM coldfront.claim_acks;
```

The row itself is not in the lake yet: the Iceberg snapshot is written when the
transaction commits, under the claim, so on `db2` the count of rows with
`id = 301` is still 0. Now `COMMIT` in the first session. The release deletes
the claim and its acks, both deletes replicate, and the row is readable from
`db2`:

```sql {"ignore":"true"}
-- On db2:
SELECT (SELECT count(*) FROM coldfront.claims)           AS claims,
       (SELECT count(*) FROM coldfront.claim_acks)       AS acks,
       (SELECT count(*) FROM events_lake WHERE id = 301) AS rows_with_id_301;
-- 0 | 0 | 1
```

Tickets are never reused, so an empty ledger is the steady state between
writes. Now fire many writers at once - several on each node, on both nodes,
all into the same table:

```sql {"ignore":"true"}
-- concurrently, on BOTH nodes at the same instant:
INSERT INTO events_lake VALUES (101, now(), 'storm', '{"n":"db1"}');   -- db1
INSERT INTO events_lake VALUES (201, now(), 'storm', '{"n":"db2"}');   -- db2
-- ...5 concurrent on db1 (101-105) and 5 on db2 (201-205)
```

Every write lands, with no conflicts and no application-level retry. Two layers
serialize them: a node-local advisory lock keeps one cold writer per node in
the bakery at a time, and the cross-node Ricart-Agrawala claim protocol orders
writers across nodes. The durable record is the lake's own: every commit adds
one snapshot to the table's metadata, in a single chain of sequence numbers.
Resolve the table's metadata location from the mesh stack's Lakekeeper (port
8191), as in the tiered demo, and list the history from either node:

```bash {"ignore":"true"}
WH_ID=$(curl -s http://localhost:8191/management/v1/warehouse \
  | grep -o '"warehouse-id":"[^"]*"' | head -1 | cut -d'"' -f4)
META_LOC=$(curl -s \
  "http://localhost:8191/catalog/v1/${WH_ID}/namespaces/public/tables/events_lake" \
  -H 'accept: application/json' \
  | grep -o '"metadata-location":"[^"]*"' | head -1 | cut -d'"' -f4)

psql "postgresql://coldfront@localhost:5443/coldfront" -P pager=off <<SQL
SELECT sequence_number, snapshot_id, timestamp_ms
FROM iceberg_snapshots('${META_LOC}')
ORDER BY sequence_number;
SQL
```

Twelve writes from two nodes produce twelve snapshots, with no missing sequence
number and no fork.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Using ColdFront](using_coldfront/index.md) guide covers both modes in depth, including
  the full one-time setup, supported column types, the partition manager CLI,
  and tuning options.
- The [Architecture](architecture_guides/index.md) overview explains the shared mechanics
  and links to the per-mode deep dives.
- The [Compaction](compaction.md) guide covers cold-tier maintenance:
  compaction, snapshot expiry, and orphan-file removal.
- The [Tearing Down the Stack](walkthrough.md#tearing-down-the-stack) section
  describes how to stop the stack and remove its data.
