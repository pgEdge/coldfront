---
cwd: ../
---
# ColdFront guided walkthrough

New here? Run the guided walkthrough.

The walkthrough is a self-contained, step-by-step tour of ColdFront's
three operating modes - tiered storage (hot PostgreSQL + cold Iceberg),
decoupled mode (Iceberg-only from the first row), and the standalone
partitioner - plus a distributed demo that runs two nodes over one
shared lake. This page mirrors the interactive guide as copy-pasteable
commands for reference.

!!! tip "Run the commands as you read"

    Every code block in this walkthrough is executable. Open the
    walkthrough in
    [GitHub Codespaces](https://github.com/codespaces/new?repo=pgEdge/coldfront)
    for a ready-to-go environment, or install the
    [Runme extension](https://marketplace.visualstudio.com/items?itemName=stateful.runme)
    in VS Code to run commands directly from the markdown.

!!! warning "Pre-release beta software"

    ColdFront is pre-release beta software under active development. Do
    not use it in production. Interfaces, on-disk formats, and behaviour
    may change without notice, and data loss is possible.

## Prerequisites

The walkthrough requires the following:

- Docker 24+ with Docker Compose V2 (the `docker compose` plugin, not
  the legacy `docker-compose` binary).
- At least 500 MB of free disk inside Docker's virtual disk (1.5 GB
  recommended for the standard data volume).
- `curl`, `bash`, and `psql` on the host (the psql commands connect to
  the published port).

## Run it

The fastest path is the one-liner, which downloads the walkthrough
files and launches the interactive guide:

```bash
curl -fsSL \
  https://raw.githubusercontent.com/pgEdge/ColdFront/main/examples/walkthrough/install.sh \
  | bash
```

If you already have the repository cloned, run the guide directly:

```bash
bash examples/walkthrough/guide.sh
```

!!! note "Codespaces users"

    Prerequisites are already installed and checked - skip the
    one-liner (it detects Codespaces and exits without doing
    anything). Run the code blocks in this page as you read, or run
    `bash examples/walkthrough/guide.sh` in the terminal for the
    interactive guide.

The guide builds the Docker images on first run (two to five minutes
for the base compile), brings up the stack, and walks through each
demo interactively. The rest of this page covers the same steps as
copy-pasteable commands.

## What setup does

Setup runs before the demos begin. It starts the containers, waits for
each service to become healthy, and creates the Lakekeeper warehouse
and namespace. The stack includes the following services:

- PostgreSQL 16, 17, or 18 with the pg_duckdb and coldfront extensions.
- SeaweedFS, a local S3-compatible object store standing in for a real
  cloud bucket.
- Lakekeeper, the Iceberg REST catalog that tracks table metadata and
  file locations.

Start the containers:

```bash
docker compose -f examples/walkthrough/docker-compose.yml \
  up -d --build
```

Bootstrap Lakekeeper, create the `wh` warehouse backed by SeaweedFS,
and seed the `default` namespace. The warehouse POST retries until
SeaweedFS is ready, and the namespace creation is idempotent:

```bash
# Bootstrap Lakekeeper (one-time per fresh stack)
curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' \
  -d '{"accept-terms-of-use":true}'

# Create the warehouse (retried by guide.sh until 200)
curl -sf -X POST http://localhost:8181/management/v1/warehouse \
  -H 'Content-Type: application/json' \
  -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "s3",
      "bucket": "iceberg",
      "region": "us-east-1",
      "endpoint": "http://seaweedfs:8333",
      "path-style-access": true,
      "flavor": "s3-compat",
      "sts-enabled": false,
      "remote-signing-enabled": false
    },
    "storage-credential": {
      "type": "s3",
      "credential-type": "access-key",
      "aws-access-key-id": "admin",
      "aws-secret-access-key": "adminsecret"
    }
  }'

# Seed the default namespace
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' \
  | head -1 | cut -d'"' -f4)
curl -sf -X POST \
  "http://localhost:8181/catalog/v1/${WID}/namespaces" \
  -H 'Content-Type: application/json' \
  -d '{"namespace":["default"]}'
```

### Using a cloud object store

The walkthrough hero path uses SeaweedFS. To use a cloud store
instead, replace the warehouse JSON above and the `set_storage_secret`
call in Step 5 below.

The following table shows the `set_storage_secret` signature for each
supported store:

| Store | set_storage_secret call |
|-------|------------------------|
| SeaweedFS (local) | `SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');` |
| AWS S3 | `SELECT coldfront.set_storage_secret('key-id', 'secret-key', null, 'ap-south-2');` |
| GCS (HMAC) | `SELECT coldfront.set_storage_secret(p_key_id => '<hmac-key>', p_secret => '<hmac-secret>', p_endpoint => 'storage.googleapis.com', p_region => 'us-east-1', p_url_style => 'path', p_use_ssl => true);` |
| Azure Blob | `SELECT coldfront.set_storage_secret_azure('AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net');` |

For the matching warehouse JSON for each store, see the
[Object Store Setup](object_store.md) guide.

## Demo 1: tiered storage

Tiered storage is a brownfield retrofit: you begin with a plain
PostgreSQL database full of data, add ColdFront to it, and let the
archiver relocate the cold majority to object storage - without
migrating to a new database or changing a line of application SQL.

The following table shows the eleven steps this demo covers:

| Step | What you will do |
|------|-----------------|
| 1. Start the stack | Bring up Postgres, Lakekeeper, and the object store |
| 2. Create a table and load history | An ordinary partitioned table with months of data |
| 3. See the problem | All rows in hot Postgres storage, and it only grows |
| 4. Enable the extensions | Two extensions retrofit tiering onto the existing database |
| 5. Point at object storage | Tell ColdFront where cold data lives |
| 6. Show the archiver policy | `hot_period: 30 days` - the hot/cold boundary |
| 7. Run the archiver | Move everything older than 30 days to object storage |
| 8. Where it lives now | The hot/cold split: rows and space in each tier |
| 9. Query across tiers | One table, one query, hot + cold together |
| 10. Write to cold data | UPDATE an archived row in place - no rehydration |
| 11. Prove it stuck | Reconnect and confirm the edit persisted in cold storage |

### Step 1 - Start the stack (setup)

Setup starts the infrastructure: PostgreSQL (your database), plus
Lakekeeper and SeaweedFS. The cold-storage side sits idle until you
point ColdFront at it in Step 5. Run the `docker compose up` command
shown in the setup section above and confirm that all services are
healthy:

```bash
docker compose -f examples/walkthrough/docker-compose.yml ps
```

PostgreSQL is your existing database. The catalog and object store are
also running - that is the cold-storage side, unused until Step 5.
Locally the store is SeaweedFS; in production it is your AWS S3, Azure
Blob, or GCS bucket.

### Step 2 - Create a table and load months of history

This step stands in for the database you already run: an ordinary
range-partitioned PostgreSQL table, filled with months of accumulated
data. Nothing here is ColdFront-specific.

Connect to PostgreSQL with the walkthrough credentials and suppress
pg_duckdb's informational notices so the output stays clean:

```bash
PGOPTIONS='-c client_min_messages=warning' \
  psql -h localhost -p 5432 -U coldfront -d coldfront
```

Create the partitioned table with seven monthly partitions covering a
six-month historical window plus the current month:

```sql
SET search_path = public;

CREATE TABLE events (
    id     bigint GENERATED BY DEFAULT AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text,
    data   jsonb,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

DO $do$
DECLARE m date;
BEGIN
  FOR i IN 0..6 LOOP
    m := (
      date_trunc('month', now())
      - make_interval(months => 6 - i)
    )::date;
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS %I'
      ' PARTITION OF events'
      ' FOR VALUES FROM (%L) TO (%L)',
      'events_p_' || to_char(m, 'YYYY_MM'),
      m,
      (m + interval '1 month')
    );
  END LOOP;
END $do$;
```

The loop creates seven monthly partitions: six historical months plus
the current month. The older months will tier to cold; the current
month stays hot.

Insert approximately one million rows spread evenly across the
partition window (roughly 150 days from `now()`):

```sql
INSERT INTO events (id, ts, status, data)
SELECT i,
       now() - ((1000000 - i) * (interval '150 days' / 1000000)),
       (ARRAY['ok','warn','error'])[1 + i % 3],
       '{}'::jsonb
FROM generate_series(1, 1000000) i;
```

Confirm all rows landed:

```sql
SELECT count(*) FROM events;
```

```
  count
---------
 1000000
```

Months of data now live in an ordinary PostgreSQL table - no ColdFront
involved yet.

### Step 3 - See the problem

This step measures how much hot Postgres storage that data occupies and
confirms that none of it is anywhere cheaper yet. This is the baseline
you will compare against after tiering in Step 8.

`pg_total_relation_size()` on a partitioned parent counts only the
empty parent itself and reports zero. Sum across `pg_partition_tree`
to get the true heap size:

```sql
SELECT pg_size_pretty(
    pg_total_relation_size('events') +
    COALESCE((
        SELECT sum(pg_total_relation_size(relid))
        FROM pg_partition_tree('events')
        WHERE relid <> 'events'::regclass
    ), 0)
) AS hot_size;
```

```
 hot_size
----------
 150 MB
```

Every row - all one million - occupies hot, expensive primary storage,
and the table only grows. Remember this figure; Step 8 shows where it
goes after tiering.

### Step 4 - Enable the extensions

This step retrofits tiering onto the database you already have, using
two extensions. `pg_duckdb` gives PostgreSQL an in-process engine that
can read Parquet in object storage. `coldfront` adds the layer that
routes each query to the right tier and rewrites DML. No migration, no
new database - these install onto the running one.

Run the following SQL to create both extensions:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
```

Confirm both are installed:

```sql
\dx
```

```
   Name    | Version |   Schema   |            Description
-----------+---------+------------+------------------------------------
 coldfront | 1.0     | coldfront  | transparent PG <-> Iceberg tiering
 pg_duckdb | 1.5.x   | public     | DuckDB engine inside PostgreSQL
```

Two extensions - that is the entire ColdFront install. No sidecar, no
proxy, no data movement yet.

### Step 5 - Point ColdFront at the object store

This step tells ColdFront where cold data goes and how to authenticate
to it. The credentials below are throwaway values for the local
SeaweedFS emulator. In production, pass your real bucket's key, secret,
and endpoint here - application SQL is unchanged when you swap stores.

Register the local SeaweedFS credentials:

```sql
SELECT coldfront.set_storage_secret(
  'admin', 'adminsecret', 'seaweedfs:8333'
);
```

The cold-storage warehouse is now wired. Confirm the catalog the
stack pre-created (`wh`) is reachable:

```bash
curl -s localhost:8181/management/v1/warehouse \
  | grep -o '"warehouse-name":"wh"'
```

```
"warehouse-name":"wh"
```

### Step 6 - Show the archiver policy

The archiver policy is one rule in a YAML file: data older than 30
days belongs in cheap object storage; the current month stays hot in
PostgreSQL. Nothing moves yet - this step just shows the boundary.

Inspect the archiver configuration:

```bash
cat examples/walkthrough/config/archiver.yaml
```

```yaml
postgres:
    dsn: "host=db port=5432 dbname=coldfront user=coldfront
          password=coldfront sslmode=disable"
iceberg:
    warehouse: "wh"
    lakekeeper_endpoint: "http://lakekeeper:8181/catalog"
    namespace: "default"
s3:
    endpoint: "seaweedfs:8333"
    region: "us-east-1"
    access_key: "admin"
    secret_key: "adminsecret"
    use_ssl: false
    url_style: "path"
archiver:
    tables:
        - source_table: events
          partition_period: monthly
          hot_period: "30 days"
```

The `hot_period: 30 days` value is the hot/cold line. Any partition
whose data is entirely older than 30 days will move to object storage
when the archiver runs.

### Step 7 - Run the archiver

The archiver moves every partition older than 30 days out of the
PostgreSQL heap and into Parquet files in object storage, then rebuilds
`events` as a unified view over the hot remainder and the cold data.

Run the archiver container against the stack:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  run --rm archiver --config /config/archiver.yaml
```

The archiver connects inside the Compose network (service name `db`,
not `localhost`), detaches the partitions older than 30 days from
PostgreSQL, exports them to Iceberg via pg_duckdb, and replaces the
`events` table with a unified view that queries both tiers.

**Proof (a) - the cold rows are really in S3 as Parquet.** The
`iceberg_metadata()` table function resolves its argument as a
filesystem path, so a REST-catalog table cannot be addressed by name
directly. Resolve the table's `metadata.json` S3 location from the
Lakekeeper catalog first, then point `iceberg_metadata()` at that path:

```bash
# Resolve the warehouse id and the table's metadata location.
WH_ID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -o '"warehouse-id":"[^"]*"' \
  | head -1 | cut -d'"' -f4)

META_LOC=$(curl -s \
  "http://localhost:8181/catalog/v1/${WH_ID}/namespaces/default/tables/events" \
  -H 'accept: application/json' \
  | grep -o '"metadata-location":"[^"]*"' \
  | head -1 | cut -d'"' -f4)

echo "$META_LOC"
```

```
s3://iceberg/wh/.../metadata/00001-....metadata.json
```

Query the Parquet data files registered in that Iceberg snapshot:

```sql
SELECT file_path
FROM iceberg_metadata('<paste META_LOC here>')
WHERE file_path LIKE '%.parquet'
LIMIT 3;
```

```
 file_path
----------------------------------------------------------
 s3://iceberg/.../data/019eb6d0-....parquet
 s3://iceberg/.../data/019eb6d1-....parquet
 s3://iceberg/.../data/019eb6d2-....parquet
```

Real `.parquet` objects are in the bucket. The cold rows are no longer
in PostgreSQL - they are objects in object storage.

**Proof (b) - the table changed shape.** Inspect the relation type:

```sql
\d events
```

`events` is now a view. The `_events` table holds only the hot
remainder. Run the following query to see the recorded hot/cold cutoff:

```sql
SELECT * FROM coldfront.archive_watermark;
```

### Step 8 - Where the data lives now

This step accounts for every row after tiering: how many are still hot
in PostgreSQL, how many are now cold in object storage, and how much
space each tier uses. This is the direct payoff against the Step 3
baseline.

Count the hot rows still in the PostgreSQL heap:

```sql
SELECT count(*) AS hot_rows FROM _events;
```

Measure the hot heap size (sum over the partition tree, as in Step 3):

```sql
SELECT pg_size_pretty(
    pg_total_relation_size('_events') +
    COALESCE((
        SELECT sum(pg_total_relation_size(relid))
        FROM pg_partition_tree('_events')
        WHERE relid <> '_events'::regclass
    ), 0)
) AS hot_size;
```

Count the total rows across both tiers and derive the cold count:

```sql
SELECT count(*) AS total_rows FROM events;
```

The interactive guide renders the result as an explicit hot/cold
summary:

```
  Tier                    Rows         Postgres heap
  ----------------------  -----------  ----------------
  Hot  (Postgres)             ~85,000  ~12 MB
  Cold (Parquet in S3)       ~915,000  0 bytes in PG
  ----------------------  -----------  ----------------
  Total                     1,000,000
```

Before tiering (Step 3): one million rows, all hot, approximately
150 MB of Postgres heap. After tiering: only the current month's
rows remain in PostgreSQL; roughly 90% of the hot storage is gone
while the total row count is unchanged.

### Step 9 - Query across tiers

This step runs one ordinary query against `events` that spans both
tiers, then queries the hot-only table for contrast. The application
issuing this query cannot tell which rows came from the heap and which
came from object storage.

Query the whole table - hot and cold together:

```sql
SELECT count(*) AS total FROM events;
```

Query only the hot heap:

```sql
SELECT count(*) AS hot FROM _events;
```

Retrieve specific rows from a cold month:

```sql
SELECT id, ts, status
FROM events
WHERE ts < date_trunc('month', now()) - interval '3 months'
ORDER BY ts
LIMIT 3;
```

```
  id  |           ts            | status
------+-------------------------+--------
    1 | 2025-12-...             | ok
    2 | 2025-12-...             | warn
    3 | 2025-12-...             | error
```

One table, one query, no application change required.

### Step 10 - Write to cold data

This step takes a specific row from a cold (archived) month and updates
it through the same `events` view. Watch for what does not happen: no
rehydration of the partition back into PostgreSQL, no ETL job, no
restore from archive, and no second tool.

Capture a cold row's id in a separate query. A sub-select over the
tiered view inside the same DML statement is rejected by the extension,
because the rewrite retargets the leading reference:

```sql
SELECT id, ts, status
FROM events
WHERE ts < date_trunc('month', now()) - interval '2 months'
ORDER BY ts
LIMIT 1;
```

```
  id |           ts            | status
-----+-------------------------+--------
   1 | 2025-12-...             | ok
```

Update the archived row through the same table using the captured id:

```sql
UPDATE events SET status = 'corrected' WHERE id = 1;
```

Read the row back immediately:

```sql
SELECT id, ts, status FROM events WHERE id = 1;
```

```
  id |           ts            |  status
-----+-------------------------+-----------
   1 | 2025-12-...             | corrected
```

The row's status flipped `ok` to `corrected`. That row is still
sitting in object storage - ColdFront wrote through to it directly.

### Step 11 - Prove it stuck

This step opens a fresh `psql` connection (nothing cached from the
session that did the write) and re-checks the row, the total row count,
and the hot heap size. This confirms that the cold edit is durable
persistent state and that the data did not quietly return to PostgreSQL
to make the edit possible.

Open a new terminal and connect with a fresh session:

```bash
PGOPTIONS='-c client_min_messages=warning' \
  psql -h localhost -p 5432 -U coldfront -d coldfront
```

Confirm the archived row is still `corrected`:

```sql
SELECT id, status FROM events WHERE id = 1;
```

```
  id |  status
-----+-----------
   1 | corrected
```

Confirm the total row count is unchanged:

```sql
SELECT count(*) AS total_rows FROM events;
```

```
 total_rows
------------
    1000000
```

Confirm the hot heap is still small (the data did not rehydrate):

```sql
SELECT pg_size_pretty(
    pg_total_relation_size('_events') +
    COALESCE((
        SELECT sum(pg_total_relation_size(relid))
        FROM pg_partition_tree('_events')
        WHERE relid <> '_events'::regclass
    ), 0)
) AS hot_size;
```

```
 hot_size
----------
 ~12 MB
```

Fresh connection: the archived row is still `corrected`, all one
million rows are present, and the hot heap is still small. The data
never came back to PostgreSQL. Approximately 90% of the original
storage now lives at a fraction of the cost, and that data is still a
normal, writeable part of the table - corrected in place, no
rehydration, no separate system.

## Demo 2: decoupled (Iceberg-only)

Decoupled mode stores a table entirely in Iceberg from the first row.
PostgreSQL holds a thin wrapper view and a registry entry. This is a
fresh table - there is no migration from the tiered demo, and the two
modes are independent.

### Create an Iceberg-only table

One SQL call provisions the Iceberg table and the PostgreSQL view. The
`default` namespace was seeded during setup, and the call wraps both
steps in a single transaction. A short retry loop guards against a
timing edge where the warehouse is still warming up:

```sql
SELECT coldfront.create_iceberg_table(
  'public',
  'events_lake',
  '[
    {"name":"id",     "type":"bigint"},
    {"name":"ts",     "type":"timestamptz"},
    {"name":"status", "type":"text"},
    {"name":"data",   "type":"jsonb"}
  ]'::jsonb
);
```

After the call returns, `events_lake` is a view; every row lives in
Iceberg on S3.

### Read and write the lake table

`events_lake` behaves like any PostgreSQL table:

```sql
INSERT INTO events_lake VALUES
  (1, now(), 'ok',  '{"a":1}'),
  (2, now(), 'ok',  '{"a":2}');

SELECT count(*) AS rows_in_lake FROM events_lake;

UPDATE events_lake SET status = 'upd' WHERE id = 1;

SELECT id, status FROM events_lake ORDER BY id;

DELETE FROM events_lake WHERE id = 2;

SELECT count(*) AS after_delete FROM events_lake;
```

All four DML operations reach the Iceberg table transparently. The
coldfront extension intercepts each statement on the view and rewrites
it to the Iceberg path via pg_duckdb.

## Demo 3: standalone partitioner

The partitioner binary manages PostgreSQL range partitions without any
cold tier. If all you need is automated partition maintenance on stock
PostgreSQL, the partitioner is the whole product - no Iceberg, no
DuckDB, no archiver cold path.

### Create the demo table

Create a partitioned table with no existing partitions:

```sql
SET search_path = public;

CREATE TABLE part_demo (
    id   bigint GENERATED ALWAYS AS IDENTITY,
    ts   timestamptz NOT NULL,
    note text,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
```

### Register and reconcile

Register the table with the partitioner (monthly period, 12-month
retention) and run a reconcile pass. Both commands run inside the
Compose network against service name `db`:

```bash
# Register the table.
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  run --rm --entrypoint partitioner archiver \
  register \
  --config /config/partitioner.yaml \
  --table part_demo \
  --period monthly \
  --retention "12 months"

# Run a reconcile pass to premake forward partitions.
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  run --rm --entrypoint partitioner archiver \
  --config /config/partitioner.yaml
```

The partitioner config at
`examples/walkthrough/config/partitioner.yaml` uses a partition-only
configuration with no `iceberg` or `s3` sections:

```yaml
postgres:
    dsn: "host=db port=5432 dbname=coldfront user=coldfront
          password=coldfront sslmode=disable"
archiver:
    tables:
        - source_table: part_demo
          partition_column: ts
          partition_period: monthly
          retention_period: 12 months
```

### Verify the partitions

Each reconcile pass premakes the next three monthly partitions ahead
of now and ensures a partition covering today always exists. It also
drops any partition older than the retention period:

```sql
SELECT count(*) AS partitions
FROM pg_inherits
WHERE inhparent = 'part_demo'::regclass;
```

## Demo 4: distributed

Distributed mode points two or more PostgreSQL nodes at the *same*
lake. The nodes form an active-active
[Spock](https://github.com/pgEdge/spock) mesh; the table data lives
once, in Iceberg, and each node adds query and write capacity over that
one shared copy. A write on one node is readable on the other with
nothing copied between them, and concurrent cold writes from different
nodes are serialized cluster-wide so they never collide.

This demo uses a different stack from the single-node walkthrough - two
`MESH=on` nodes (`db1`, `db2`) plus a shared Lakekeeper and object
store. The interactive guide automates the whole switch (it stops the
single-node stack first, since a laptop rarely has room for both):

```bash
bash examples/walkthrough/guide.sh   # then choose: 4) Distributed
```

The sections below show what that option does, so you can follow along
or reproduce it by hand.

### Bring up the two-node mesh

Start the mesh stack, then form the Spock mesh - create a node on each
member, subscribe each to the other, and arm the cold-write
coordination substrate on both:

```bash
docker compose -f examples/walkthrough/docker-compose.mesh.yml up -d
```

```sql
-- On db1:
SELECT spock.node_create('db1', 'host=db1 user=coldfront dbname=coldfront port=5432');
SELECT spock.sub_create('sub_db1_from_db2', 'host=db2 user=coldfront dbname=coldfront port=5432');
-- On db2:
SELECT spock.node_create('db2', 'host=db2 user=coldfront dbname=coldfront port=5432');
SELECT spock.sub_create('sub_db2_from_db1', 'host=db1 user=coldfront dbname=coldfront port=5432');

-- On BOTH nodes - replicate the bakery's claim tables and set the cold-store
-- secret, before any cold write:
SELECT coldfront._ensure_claims_replicated();
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
```

The nodes reach each other over the Compose network (service names
`db1`/`db2`, port 5432). The bakery replicates only small coordination
metadata between nodes - never the table data, which stays in the lake. The
`set_storage_secret` call is what lets each node's DuckDB write Parquet to the
shared object store; without it, cold writes fail to authenticate.

### See the mesh

Both nodes are present, each subscribed to the other:

```sql
SELECT node_name FROM spock.node ORDER BY node_name;   -- db1, db2
SELECT sub_name  FROM spock.subscription;              -- one per node
```

### Write on one node, read on the other

Create a lake-native table on `db1` and register it on `db2` as well
(the call is idempotent and the registry is keyed by name, so each node
ends up with an identical local view):

```sql
-- On db1, then on db2 - same call:
SELECT coldfront.create_iceberg_table(
  'public', 'events_lake',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},
    {"name":"status","type":"text"},{"name":"data","type":"jsonb"}]'::jsonb
);
```

Write three rows on `db1`, then read them back on `db2`:

```sql
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

`db2` returns every row `db1` wrote and stores zero bytes for the table
- it reads straight from the shared lake. That is the point of
distributed mode: add a node for compute over one copy of the data,
with no storage to replicate.

### Concurrent writes serialize (the bakery)

Two nodes committing the same Iceberg table at once would normally
collide - the catalog rejects the second commit with a `409 Conflict`
and the application has to retry. ColdFront's bakery protocol prevents
that: each cold write takes a globally-ordered ticket (replicated via
Spock, verified in the TLA+ model under `docs/formal/`) and waits its
turn. Fire many writers at once - several on each node, on both nodes,
all into the same table:

```sql
-- concurrently, on BOTH nodes at the same instant:
INSERT INTO events_lake VALUES (101, now(), 'storm', '{"n":"db1"}');   -- db1
INSERT INTO events_lake VALUES (201, now(), 'storm', '{"n":"db2"}');   -- db2
-- ...5 concurrent on db1 (101-105) and 5 on db2 (201-205)
```

Every write lands, with no conflicts and no application-level retry.
Two layers serialize them: a node-local advisory lock keeps one cold
writer per node in the bakery at a time, and the cross-node
Ricart-Agrawala claim protocol orders writers across nodes. The durable
proof is the claim ledger - each ticket, the node that issued it, and
the peer that acknowledged it before the commit:

```sql
SELECT ticket,
       snowflake.get_node(ticket) AS issued_by,
       ack_from_node              AS acked_by
FROM coldfront.claim_acks ORDER BY ticket;
```

## Teardown

To stop the stack and remove all data volumes, run the following
command:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  down -v
```

The `-v` flag removes the named volumes (`pgdata` and `s3data`). Omit
it to keep the data for a later session.

If you ran the distributed demo, tear down its separate mesh stack too:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.mesh.yml \
  down -v
```

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Using ColdFront](usage.md) guide covers both modes in depth,
  including the full one-time setup, supported column types, the
  partition manager CLI, and tuning options.
- The [Object Store Setup](object_store.md) guide takes you from an
  empty bucket to a working cold tier on cloud S3, GCS, or Azure.
- The [Architecture](architecture.md) overview explains the shared
  mechanics and links to the per-mode deep dives.
- The [Compaction](compaction.md) guide covers cold-tier maintenance:
  compaction, snapshot expiry, and orphan-file removal.
