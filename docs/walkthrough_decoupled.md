---
cwd: ../
---
# Exploring Decoupled Mode

Decoupled mode stores a table entirely in Iceberg from the first row.
PostgreSQL holds a thin wrapper view and a registry entry. This is a fresh
table - there is no migration from the tiered demo, and tiered and decoupled
tables are independent.

The following table shows the seven steps this demo performs:

| Step | What you will do |
|------|-----------------|
| [1. Create an Iceberg-only table](#creating-an-iceberg-only-table) | Create a table whose rows live in Iceberg from the first row, with one SQL call. |
| [2. Read and write the lake table](#reading-and-writing-the-lake-table) | Insert and query rows as you would in any PostgreSQL table. |
| [3. Stand in for another engine](#standing-in-for-the-external-writer) | Use DuckDB to write an Iceberg table, as another engine would. |
| [4. Adopt the table read-only](#adopting-it-read-only) | Wrap the existing Iceberg table in a read-only PostgreSQL view. |
| [5. Enable writes](#enabling-writes) | Adopt the table again as writable, so INSERT, UPDATE, and DELETE work. |
| [6. Restore a column type](#restoring-a-type-iceberg-cannot-record) | Restore the PostgreSQL type of a column that Iceberg stores as text. |
| [7. Hand the table back](#handing-it-back) | Release the table; its rows stay in the lake. |

## Running This Demo in a Codespace

Create the Codespace as described in
[Preparing a Codespace](exploring_coldfront/index.md#preparing-a-codespace).
The Codespace opens the Exploring ColdFront page; click Exploring Decoupled
Mode to open this page as a notebook. To run a cell, click the triangle to the
left of the cell.

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

Run the following cell to bootstrap Lakekeeper, create the `wh` warehouse
backed by SeaweedFS, and seed the `public` namespace. The cell makes one
attempt, so run it again if the warehouse request fails:

```bash
# Bootstrap Lakekeeper (one-time per fresh stack)
curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' \
  -d '{"accept-terms-of-use":true}'

# Create the warehouse and save its ID (retried by guide.sh until 200)
WID=$(curl -sf -X POST http://localhost:8181/management/v1/warehouse \
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
  }' \
  | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)

# Seed the public namespace
if [ -z "$WID" ]; then
  echo "No warehouse ID - check that the warehouse create succeeded."
else
  curl -sf -X POST \
    "http://localhost:8181/catalog/v1/${WID}/namespaces" \
    -H 'Content-Type: application/json' \
    -d '{"namespace":["public"]}'
fi
```

Then click the triangle beside each cell that follows, in order.

## Running This Demo on Your Own System

Prepare your system as described in
[Preparing Your Own System](exploring_coldfront/index.md#preparing-your-own-system),
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

Use the following commands to start the containers and then bootstrap
Lakekeeper:

```bash {"ignore":"true"}
docker compose -f examples/walkthrough/docker-compose.yml \
  up -d --build
docker compose -f examples/walkthrough/docker-compose.yml \
  build archiver
```

```bash {"ignore":"true"}
# Bootstrap Lakekeeper (one-time per fresh stack)
curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' \
  -d '{"accept-terms-of-use":true}'

# Create the warehouse and save its ID (retried by guide.sh until 200)
WID=$(curl -sf -X POST http://localhost:8181/management/v1/warehouse \
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
  }' \
  | grep -oE '"warehouse-id":"[^"]+"' | cut -d'"' -f4)

# Seed the public namespace
if [ -z "$WID" ]; then
  echo "No warehouse ID - check that the warehouse create succeeded."
else
  curl -sf -X POST \
    "http://localhost:8181/catalog/v1/${WID}/namespaces" \
    -H 'Content-Type: application/json' \
    -d '{"namespace":["public"]}'
fi
```

If port 5432, 8181, or 8333 is already in use on your host, see
[Changing the Demo Ports](exploring_coldfront/index.md#changing-the-demo-ports).

## Preparing the Database

This demo needs the `pg_duckdb` and `coldfront` extensions and the object store
credential. If you ran the tiered demo on this stack, both are already in
place, and running these steps again changes nothing.

Run the following SQL to create both extensions:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
```

Register the local SeaweedFS credentials:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT coldfront.set_storage_secret(
  'admin', 'adminsecret', 'seaweedfs:8333'
);
```

The [tiered demo](walkthrough_tiered.md#enabling-the-extensions) describes
what each extension does and how to use a real object store instead.

## Creating an Iceberg-Only Table

One SQL call provisions the Iceberg table and the PostgreSQL view. The `public`
namespace was seeded during setup, and the call wraps both steps in a single
transaction:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
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

After the call returns, `events_lake` is a view; every row lives in Iceberg on
S3.

## Reading and Writing the Lake Table

`events_lake` behaves like any PostgreSQL table:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
INSERT INTO events_lake VALUES
  (1, now(), 'ok',  '{"a":1}'),
  (2, now(), 'ok',  '{"a":2}');

SELECT count(*) AS rows_in_lake FROM events_lake;

UPDATE events_lake SET status = 'upd' WHERE id = 1;

SELECT id, status FROM events_lake ORDER BY id;

DELETE FROM events_lake WHERE id = 2;

SELECT count(*) AS after_delete FROM events_lake;
```

All four DML operations reach the Iceberg table transparently. The `coldfront`
extension intercepts each statement on the view and rewrites it to the Iceberg
path via pg_duckdb.

## Adopting a Table Already in the Lake

Not every Iceberg table starts in ColdFront. A table another engine wrote needs
no provisioning, only a wrapper view and a registry row. Adoption builds both
from the schema the catalog already holds.

### Standing In for the External Writer

These three statements are the only ones in this walkthrough written in DuckDB
SQL, because they represent what some other engine already did to your lake.
The namespace create commits on its own, ahead of the table create, because
DuckDB defers an Iceberg `CREATE SCHEMA` to commit while posting `CREATE TABLE`
immediately:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT coldfront.ensure_attached();
SELECT duckdb.raw_query('CREATE SCHEMA IF NOT EXISTS ice.lake');
```

The table has a `VARCHAR` column holding JSON, which matters in a moment:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT coldfront.ensure_attached();
SELECT duckdb.raw_query($$
  CREATE TABLE IF NOT EXISTS ice.lake.orders (
    order_id BIGINT, placed_at TIMESTAMP WITH TIME ZONE,
    customer VARCHAR, amount DECIMAL(12,2), meta VARCHAR)$$);
SELECT duckdb.raw_query($$
  INSERT INTO ice.lake.orders VALUES
    (1, now(), 'acme', 19.99, '{"tier":"gold"}'),
    (2, now(), 'globex', 249.50, '{"tier":"silver"}')$$);
```

### Adopting It Read-Only

Adoption takes one call and no column list; the schema comes from the catalog.
The view goes in the PostgreSQL schema `public`; `lake` is the Iceberg
namespace, and no PostgreSQL schema of that name is needed:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake');

SELECT order_id, customer, amount FROM orders ORDER BY order_id;
```

The call reports what it registered:

```text {"ignore":"true"}
NOTICE:  coldfront: adopted "ice"."lake"."orders" as public.orders (5 columns, read-only)
```

Writes are refused, and the message says what to do:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -P pager=off -f"}
UPDATE orders SET amount = 0 WHERE order_id = 1;
```

The refusal reads:

```text {"ignore":"true"}
ERROR:  coldfront: "public.orders" is adopted read-only
HINT:  Release it with coldfront.release_iceberg_table() and adopt again with p_writable => true to arm INSERT/UPDATE/DELETE.
```

### Enabling Writes

Adoption binds the name once, so enabling writes is a release followed by a
second adopt with `p_writable => true`, which gives the view the same DML
rewrite a created table gets. Every write below is one bakery-serialized
Iceberg snapshot:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT coldfront.release_iceberg_table('public', 'orders');
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake',
                                     p_writable => true);

INSERT INTO orders VALUES (3, now(), 'initech', 42.00, '{"tier":"bronze"}');
UPDATE orders SET amount = 21.00 WHERE order_id = 3;
DELETE FROM orders WHERE order_id = 1;

SELECT order_id, customer, amount FROM orders ORDER BY order_id;
```

### Restoring a Type Iceberg Cannot Record

The `meta` column reads as text, because Iceberg stores JSON as `VARCHAR` and
records no PostgreSQL type. `p_types` restores the column's type, and the
override is accepted because it maps to what the catalog stores:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT coldfront.release_iceberg_table('public', 'orders');
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake',
                                     p_writable => true,
                                     p_types    => '{"meta":"jsonb"}'::jsonb);

SELECT order_id, meta->>'tier' AS tier FROM orders ORDER BY order_id;
```

### Handing It Back

Release removes the view and the registry row and performs no Iceberg I/O, so
the table keeps every row and stays in the catalog:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -v ON_ERROR_STOP=1 -P pager=off -f"}
SELECT coldfront.release_iceberg_table('public', 'orders');
```

There are two things to take from this demo. A `VARCHAR` column comes back as
text rather than as `jsonb` unless `p_types` says otherwise, because Iceberg
records no PostgreSQL type. The bakery serializes ColdFront's own writers, not
an external engine writing the same table.

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

- The [Partitioner Demo](walkthrough_partitioner.md) manages PostgreSQL range
  partitions without any cold tier.
- The [Using ColdFront](using_coldfront/index.md) guide compares the tiered,
  decoupled, and standalone partitioned modes, and covers dropping Iceberg
  tables and the partition management CLI.
- The [Architecture](architecture_guides/index.md) overview explains the shared mechanics
  and links to the per-mode deep dives.
