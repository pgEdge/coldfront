# Using ColdFront in Decoupled Mode

Before you begin, configure PostgreSQL, Lakekeeper, and your object store by
following [Configuring ColdFront](configuration.md), [Configuring Lakekeeper](one_time_setup.md),
and [Configuring your Object Store](object_store.md); every row of a
decoupled table lives in the cold tier those guides set up, from the first
row. This page walks through creating a decoupled table with
`coldfront.create_iceberg_table()`, changing its columns, and adopting a
table that another engine already wrote into the catalog.

A single call creates a decoupled table:

```sql
SELECT coldfront.create_iceberg_table(
    p_schema  => 'public',
    p_table   => 'events',
    p_columns => '[
      {"name":"id",     "type":"bigint"},
      {"name":"ts",     "type":"timestamptz"},
      {"name":"status", "type":"text"},
      {"name":"data",   "type":"jsonb"}
    ]'::jsonb,
    p_partition_cols => '{month(ts)}'
);
```

`p_partition_cols` partitions the Iceberg table, here by the month of `ts`:
each month's rows land in their own data files, and a query with a time filter
skips the months outside it before reading anything. Each element is one term
as DuckDB's `PARTITIONED BY` takes it: a column name, `year(col)`, `month(col)`
or `day(col)` on a timestamp or date column, `hour(col)` on a timestamp column,
`bucket(N, col)` or `truncate(W, col)`; `'{month(ts), region}'` partitions by
both. The argument is a PostgreSQL array literal, so a term that contains a
comma is double-quoted inside it, the comma being the array's delimiter:
`'{"bucket(16, id)"}'`. A column name that itself needs double quotes has them
backslashed inside such an element: `'{"month(\"Event Time\")"}'`. Leave the
argument out for an unpartitioned table.

That single statement provisions:

- `ice.public.events` on the attached Iceberg catalog.
- a PG-side wrapper view `public.events` with proper PG-typed columns.

- a `coldfront.tiered_views` registry row, so that the coldfront C hook
  intercepts every `INSERT`, `UPDATE`, `DELETE`, and `MERGE` on the view and
  rewrites each one to a single `duckdb.raw_query(...)` against
  `ice.public.events`.


In a mesh one node provisions: Spock's `ddl_sql` repset replicates the
`CREATE VIEW`, and the `default` repset replicates the name-keyed registry row,
which enables the write hook on every peer. Each node also needs the
one-time setup call `coldfront.ensure_replicated()` - see
[Distributed Setup](distributed_setup.md).

## Changing a Decoupled Table's Columns

An `ALTER TABLE` on the wrapper view adds, drops, renames or widens a column
of the Iceberg table, and the view follows, with its owner and table-level
grants kept; a column-level grant on the view is not kept. Only the view's
owner, or a role holding its privileges, can change its columns, and that role
needs the cold access `grant_app_access` gives, since the Iceberg change runs
as that role. The following statements change the columns of the table created
above:

```sql
ALTER TABLE public.events ADD COLUMN qty integer;
ALTER TABLE public.events ALTER COLUMN qty TYPE bigint;
ALTER TABLE public.events RENAME COLUMN qty TO quantity;
ALTER TABLE public.events DROP COLUMN quantity;
```

A column takes the same type map as at creation, though an array column cannot
be added, because duckdb-iceberg does not add a nested column to an Iceberg
table. A type change is limited to the widening Iceberg accepts: `integer` to
`bigint`, `real` to `double precision`, `date` to `timestamp`, and a wider
`numeric` precision. An added column takes a name and a type only: a default,
a constraint, a collation, or a storage or compression option is refused, as
is a `USING` or `COLLATE` clause on a type change, and a column change shares
an `ALTER TABLE` only with other column changes. A vector column is neither
added nor changed, a table adopted read-only refuses every column change, and
an object built on the view, such as another view, makes a column change
fail. In a mesh, the change runs on one node: the Iceberg table is shared, and
the rebuilt view and registry row replicate.

## Adopting a Table That Already Exists in the Catalog

A table another engine wrote needs no provisioning, only a wrapper view and a
registry row. `coldfront.adopt_iceberg_table()` reads the schema from the
catalog and builds both, so the call names the relation and nothing else:

```sql
SELECT coldfront.adopt_iceberg_table(
    p_schema    => 'public',
    p_table     => 'orders',
    p_namespace => 'lake'
);
```

`p_schema` is the PostgreSQL schema the wrapper view goes in, and it must
exist. `p_namespace` is the Iceberg namespace the table lives in, which need
not exist as a PostgreSQL schema; it defaults to `p_schema` when omitted. The
view takes the table's name.

Adoption is read-only by default, so reading someone else's lake table cannot
become writing it by accident. Passing `p_writable => true` enables the same
`INSERT`, `UPDATE`, `DELETE` and `MERGE` rewrite a created table gets:

```sql
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake',
                                     p_writable => true);
```

Because Iceberg records no PostgreSQL type, an adopted column reads as whatever
its storage type maps to; a `jsonb` column comes back as `text`. Pass `p_types`
to restore one, provided the override maps to the type the catalog already
stores:

```sql
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake',
                                     p_writable => true,
                                     p_types    => '{"meta":"jsonb"}'::jsonb);
```

Adoption binds the name once. A second call under a registered name is refused
whatever its arguments; to enable writes or change an override, release the
table with `coldfront.release_iceberg_table()` and adopt it again. A
non-superuser deployment runs `coldfront.grant_app_access()` after adopting,
because the grant reads the registry at call time.

In a mesh one node adopts. The wrapper view replicates through Spock's
`ddl_sql` repset and the registry row through the `default` repset (see
[Distributed Setup](distributed_setup.md)),
so every peer reads and writes the table under the same name, and a peer's own
adopt is refused as already registered. Adoption takes the table's bakery
claim around that check and the registry write, so two nodes adopting the
same table at the same moment are serialized: the second waits, then reads
the first's row and refuses, rather than both registering the one table. A
writer outside ColdFront is outside the bakery and can still collide at
Lakekeeper.

One relation can be registered per Iceberg table. A namespace that needs
quoting, such as `Lake-EU`, works.

## Dropping an Iceberg Table (Both Modes)

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
- in [tiered mode](usage_tiered.md) the Iceberg table is the cold tier, so the
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

### Handing an Adopted Table Back

An adopted table is released rather than dropped, because ColdFront does not
own it. `coldfront.release_iceberg_table()` removes the wrapper view, the
registry row and the relation's vector configuration, and performs no Iceberg
I/O, so the table keeps every row and stays in the catalog:

```sql
SELECT coldfront.release_iceberg_table('public', 'orders');
```

Release refuses a tiered registration, because removing one would leave its
cold rows unreachable while the hot table returned under the relation's name.
`drop_iceberg_table()` refuses a relation adopted read-only, for the mirrored
reason: read access gives no authority to destroy.
