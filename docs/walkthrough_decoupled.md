---
cwd: ../
---
# Exploring Decoupled Mode

Decoupled mode stores a table entirely in Iceberg from the first row.
PostgreSQL holds a thin wrapper view and a registry entry. This is a fresh
table - there is no migration from the tiered demo, and the two modes are
independent.

Run the steps in [Setting Up the Stack](walkthrough.md#setting-up-the-stack)
before you start this demo. The demo also needs the extensions and storage
secret from [Step 4](walkthrough_tiered.md#enabling-the-extensions) and
[Step 5](walkthrough_tiered.md#pointing-coldfront-at-the-object-store) of the
tiered demo. If you start here, run those two steps first.

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

All four DML operations reach the Iceberg table transparently. The coldfront
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

```text
NOTICE:  coldfront: adopted "ice"."lake"."orders" as public.orders (5 columns, read-only)
```

Writes are refused, and the message says what to do:

```sql {"interpreter":"psql postgresql://coldfront@localhost:5432/coldfront?options=-cclient_min_messages%3Dwarning -P pager=off -f"}
UPDATE orders SET amount = 0 WHERE order_id = 1;
```

The refusal reads:

```text
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

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Partitioner Demo](walkthrough_partitioner.md) manages PostgreSQL range
  partitions without any cold tier.
- The [Using ColdFront](using_coldfront/index.md) guide covers both modes in depth, including
  the full one-time setup, supported column types, the partition manager CLI,
  and tuning options.
- The [Architecture](architecture_guides/index.md) overview explains the shared mechanics
  and links to the per-mode deep dives.
- The [Tearing Down the Stack](walkthrough.md#tearing-down-the-stack) section
  describes how to stop the stack and remove its data.
