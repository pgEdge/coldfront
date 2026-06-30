# ColdFront guided walkthrough

New here? Run the guided walkthrough.

The walkthrough is a self-contained, step-by-step tour of ColdFront's
three operating modes: tiered storage (hot PostgreSQL + cold Iceberg),
decoupled mode (Iceberg-only from the first row), and the standalone
partitioner. This page mirrors the interactive guide as copy-pasteable
commands for reference.

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
- Apple Silicon (M1/M2/M3): the PostgreSQL image runs as
  `linux/amd64` via Rosetta 2 emulation. Enable it in Docker Desktop
  under Settings > General > "Use Rosetta for x86/amd64 emulation on
  Apple Silicon".

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

The guide builds the Docker images on first run (two to five minutes
for the base compile), brings up the stack, and walks through each
demo interactively. The rest of this page covers the same steps as
copy-pasteable commands.

## What setup does

Setup runs in two phases before the demos begin.

### Phase A - infrastructure

Phase A starts the containers, waits for each service to become
healthy, and creates the Lakekeeper warehouse and namespace. The stack
includes the following services:

- PostgreSQL 16, 17, or 18 with the pg_duckdb and coldfront extensions.
- SeaweedFS, a local S3-compatible object store standing in for a real
  cloud bucket.
- Lakekeeper, the Iceberg REST catalog that tracks table metadata and
  file locations.

Start the containers and wait for PostgreSQL to accept connections:

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

### Phase B - ColdFront setup

Phase B installs the PostgreSQL extensions and registers the storage
secret. These are the only ColdFront-specific setup steps; everything
above is generic Iceberg infrastructure:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- Register the local SeaweedFS credentials.
-- In production, pass your real bucket keys + endpoint here.
-- Nothing in your application SQL changes when you swap stores.
SELECT coldfront.set_storage_secret(
  'admin', 'adminsecret', 'seaweedfs:8333'
);
```

Run the SQL above in psql:

```bash
psql -h localhost -p 5432 -U coldfront -d coldfront
```

### Using a cloud object store

The walkthrough hero path uses SeaweedFS. To use a cloud store
instead, replace the warehouse JSON in Phase A and the
`set_storage_secret` call in Phase B.

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

Tiered storage keeps recent data in native PostgreSQL partitions and
archives older partitions to Iceberg on a watermark. The archiver runs
once and the table name never changes.

### Create the partitioned table

Create an `events` table with monthly range partitions covering a
six-month window. The walkthrough seeds rows across approximately 150
days from `now()`, so the partitions use `now()`-relative bounds
rather than fixed literal dates:

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

### Inspect the archiver config

The archiver config at `examples/walkthrough/config/archiver.yaml`
configures the tiering job for this demo. The `hot_period` of 30 days
keeps the current month hot and tiers the older months to Iceberg:

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

### Generate data and tier

Insert approximately one million rows spread across the partition
window, then run the archiver:

```sql
-- Generate ~1 M rows spread evenly over now-150d to now.
INSERT INTO events (id, ts, status, data)
SELECT i,
       now() - ((1000000 - i) * (interval '150 days' / 1000000)),
       (ARRAY['ok','warn','error'])[1 + i % 3],
       '{}'::jsonb
FROM generate_series(1, 1000000) i;
```

Run the archiver to move the cold partitions to Iceberg:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  run --rm archiver --config /config/archiver.yaml
```

The archiver connects inside the Compose network (service name `db`,
not `localhost`), detaches the partitions older than 30 days from
PostgreSQL, exports them to Iceberg via pg_duckdb, and replaces the
`events` table with a unified view that queries both tiers.

### Query hot and cold together

The `events` relation is now a view over the hot partition and the
Iceberg cold tier. The SQL surface is unchanged:

```sql
-- Total row count: hot + cold in one query.
SELECT count(*) AS total FROM events;

-- Count rows that have moved to the cold tier.
SELECT count(*) AS cold_rows
FROM events
WHERE ts < date_trunc('month', now());
```

### Write to archived rows

Cold data is writeable through the same view. Capture a cold row's id
in a separate query first - a sub-select over the tiered view inside
the same DML is rejected by the extension, because the rewrite
retargets the leading reference:

```sql
-- Capture the id in a separate query.
SELECT id
FROM events
WHERE ts < date_trunc('month', now()) - interval '2 months'
ORDER BY ts
LIMIT 1;

-- Then UPDATE by that id (substitute the actual value from above).
UPDATE events SET status = 'corrected' WHERE id = <captured_id>;

-- Confirm the change is visible through the unified view.
SELECT count(*) AS corrected
FROM events
WHERE status = 'corrected';

-- DELETE an archived row through the same table.
DELETE FROM events WHERE id = <captured_id>;

SELECT count(*) AS total_after_delete FROM events;
```

An archived row is updated and deleted through ordinary SQL with no
application change.

## Demo 2: decoupled (Iceberg-only)

Decoupled mode stores a table entirely in Iceberg from the first row.
PostgreSQL holds a thin wrapper view and a registry entry. This is a
fresh table - there is no migration from the tiered demo, and the two
modes are independent.

### Create an Iceberg-only table

One SQL call provisions the Iceberg table and the PostgreSQL view. The
`default` namespace was seeded during Phase A setup, and the call
wraps both steps in a single transaction. A short retry loop guards
against a timing edge where the warehouse is still warming up:

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
`examples/walkthrough/config/partitioner.yaml` uses a
PARTITION-ONLY configuration with no `iceberg` or `s3` sections:

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

## Teardown

To stop the stack and remove all data volumes:

```bash
docker compose \
  -f examples/walkthrough/docker-compose.yml \
  down -v
```

The `-v` flag removes the named volumes (`pgdata` and `s3data`). Omit
it to keep the data for a later session.

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
