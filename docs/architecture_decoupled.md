# Decoupled (Iceberg-Only) Operating Mode

This document describes an alternate operating mode of the ColdFront project
where a table lives entirely in Iceberg - no PG-native heap, no hot tier, no
archiver. PostgreSQL becomes a stateless compute front-end; storage is owned by
Lakekeeper + the underlying S3-compatible object store. Decoupled mode shares
the same codebase, docker stack and extension as tiered mode. The shared
mechanics - pg_duckdb Iceberg I/O, the rewrite hook, the bakery protocol, the
registry - are in [architecture.md](architecture.md); tiered mode is in
[architecture_tiered.md](architecture_tiered.md). This document covers what is
specific to decoupled mode.

## What "Decoupled" Means

The following table compares tiered mode with the decoupled mode described in
this document, concern by concern:

| Concern | Tiered mode | Decoupled mode (this doc) |
|---|---|---|
| Hot rows | PG heap (`_events`, partitioned) | None |
| Cold rows | Iceberg via Lakekeeper | All rows, in Iceberg |
| Unified view | The `events` view UNION-ALLs hot and cold. | None; users query Iceberg directly. |
| `post_parse_analyze_hook` | The hook rewrites INSERT/UPDATE/DELETE per tier. | The hook rewrites every INSERT/UPDATE/DELETE on the wrapper view to a single `SELECT coldfront._exec_iceberg_with_claim(<ref>, <DuckDB SQL>)`, which takes the table's claim and runs the statement through `duckdb.raw_query`. |
| Archiver | The archiver moves rows from hot to cold on a cron. | None, because there is nothing to archive. |
| `coldfront.tiered_views` row | The row is required for each managed table. | The row is required (with `is_iceberg_only = true`), and `create_iceberg_table()` registers it. |
| Required at runtime | `pg_duckdb`, `coldfront`, Lakekeeper, an S3-compatible store or Azure ADLS Gen2 | `pg_duckdb`, `coldfront` (lazy catalog ATTACH, DML rewrite, and write serialization), Lakekeeper, an S3-compatible store or Azure ADLS Gen2 |

The coldfront extension provides the lazy catalog-attach glue: the C extension
hook intercepts the first query that touches a tiered view (read or write) and,
if the Iceberg catalog `ice` is not yet attached in this session, issues
`duckdb.raw_query('ATTACH IF NOT EXISTS ''wh'' AS ice (TYPE ICEBERG, ENDPOINT ...)')`
against the GUCs `coldfront.warehouse` and `coldfront.lakekeeper_endpoint`.
There is no connect-time setup - the attach happens on demand, transparently,
the first time a session actually queries Iceberg.

For tables registered as iceberg-only via `coldfront.create_iceberg_table()`,
the parse-analyze rewriter is the **primary** dispatch path: it intercepts
every INSERT/UPDATE/DELETE on the wrapper view and emits one
`SELECT coldfront._exec_iceberg_with_claim(<ref>, '…')`, which takes the
table's claim and runs the DuckDB statement against the Iceberg table through
`duckdb.raw_query` - a single Iceberg snapshot per statement. Tables that do
not appear in `coldfront.tiered_views` are invisible to the hook
(`lookup_tiered_view` returns null → fast path-out).

## Bootstrap Sequence

Configure the warehouse GUCs, then create the extensions and storage secret
once per database:

```sql
-- (postgresql.conf or per-database config)
coldfront.warehouse = 'wh'
coldfront.lakekeeper_endpoint = 'http://lakekeeper:8181/catalog'
-- only for INSERT ... SELECT from a PostgreSQL table:
coldfront.local_pg_dsn = 'host=/var/run/postgresql dbname=coldfront user=coldfront'

-- one-time, per database:
CREATE EXTENSION pg_duckdb;
CREATE EXTENSION coldfront;
SELECT coldfront.set_storage_secret('<key>', '<secret>', '<endpoint>');  -- cold-tier S3 creds
```

`set_storage_secret` stores the credentials in the `coldfront.storage_secret`
table - an extension-member table (so its data is excluded from `pg_dump` by
default) that is added to the Spock repset (so it replicates by value to every
mesh node) - and materializes a DuckDB PERSISTENT SECRET, which DuckDB loads at
instance init. The secret is set once; no per-session setup is needed.

`coldfront.local_pg_dsn` is the libpq DSN that DuckDB's `postgres` extension
attaches as `pglocal`. Only an `INSERT ... SELECT` that reads a PostgreSQL
table uses it. The GUC is `PGC_SUSET` and superuser-only, because the DSN can
hold credentials. `set_storage_secret` installs the `postgres` extension when
the GUC is set, and `coldfront.ensure_pg_attached()` attaches `pglocal` when
such an INSERT runs. With the GUC unset, that INSERT fails, because DuckDB has
no `pglocal` catalog to resolve.

After that, the first query touching a tiered view in any session lazily
attaches the catalog and `ice.public.*` becomes available.

## Interface

With the coldfront extension loaded and the storage secret set, the wrapper
view supports the operations below.

### What Works

The following table shows the supported operations, their dispatch path, and
notes:

| Operation | Path | Notes |
|---|---|---|
| Lazy catalog ATTACH | The C hook calls `ensure_attached()` on the first query that touches a tiered view. | The ATTACH costs one round-trip on the first Iceberg query per session. |
| CREATE TABLE | `SELECT duckdb.raw_query('CREATE TABLE ice.<ns>.<name> (...)')` | The statement is DuckDB SQL in attached-catalog syntax. |
| INSERT | The C hook rewrites an `INSERT INTO <view>` whose source is `VALUES (…)`, `SELECT … FROM <pg_table>` or `SELECT … FROM generate_series(…)` to one `SELECT coldfront._exec_iceberg_with_claim(<ref>, 'INSERT INTO ice.<ns>.<name> …')`. Source-table references get the prefix `pglocal.<schema>.<table>`, so DuckDB's postgres extension streams the source via libpq into the Iceberg writer. That attachment needs `coldfront.local_pg_dsn` (see [Bootstrap Sequence](#bootstrap-sequence)). | Each INSERT produces a single Iceberg snapshot, regardless of row count. |
| UPDATE | The hook rewrites `UPDATE <view> SET … WHERE …` to `SELECT coldfront._exec_iceberg_with_claim(<ref>, 'UPDATE ice.<ns>.<name> SET ... WHERE ...')`. | Iceberg applies the update as merge-on-read. |
| DELETE | The hook rewrites `DELETE FROM <view> WHERE …` to `SELECT coldfront._exec_iceberg_with_claim(<ref>, 'DELETE FROM ice.<ns>.<name> WHERE ...')`. | Iceberg records the delete in position-delete files. |
| SELECT (function-call form) | `SELECT … FROM iceberg_scan('ice.<ns>.<name>') r WHERE r['col'] = …` | Columns must use the `r['col']` accessor. In a fresh session, run `SELECT coldfront.ensure_attached();` first, or DuckDB treats the argument as a file path. |
| SELECT (raw-query form) | `SELECT duckdb.raw_query('SELECT ... FROM ice.<ns>.<name> WHERE ...')` | The query returns a scalar or text result via pg_duckdb's NOTICE channel. |
| ROLLBACK of writes | `BEGIN; raw_query(...); ROLLBACK;` | pg_duckdb's `XactCallback` ties the DuckDB and PG transactions together, so ROLLBACK undoes pending Iceberg writes. |
| DROP TABLE | `SELECT coldfront.drop_iceberg_table('<schema>', '<name>', <purge>)` | The function removes the wrapper view and every registration row, vector configuration included. A raw `DROP TABLE` through `duckdb.raw_query` drops only the catalog table and leaves those rows behind. |

### What Does Not Work

The following table shows attempts that fail and the reason for each:

| Attempt | Failure |
|---|---|
| `SELECT * FROM ice.public.events` | The PG parser rejects the statement with `cross-database references are not implemented`. PG sees the 3-part name as `database.schema.table` and refuses. There is no "ice is an attached duckdb catalog" handling at the PG parser level. |
| `INSERT INTO ice.public.events VALUES (...)` (PG-native DML on the 3-part name) | The PG parser rejects the statement the same way. |
| Bare-column predicates on `iceberg_scan(...)` | `iceberg_scan` returns a single-column row of struct; columns must be accessed via `r['col']`. Bare `WHERE col = …` fails with "column does not exist". |

The net effect is that every read or write of an Iceberg-only table either goes
through the `iceberg_scan(...)` table-function (with `r['col']` accessor) or
through `duckdb.raw_query('… DuckDB SQL …')`. Neither is as easy to use as a
normal PG table, which is the main drawback of decoupled mode without a PG-side
wrapper view.

## Supported Column Types

The supported column types are exactly the set that round-trips cleanly between
PG and Iceberg (shared with tiered mode; see `pgFormatTypeToDuckDB` in
[cmd/archiver/main.go](https://github.com/pgEdge/ColdFront/blob/main/cmd/archiver/main.go)).
Anything outside this list is rejected at table-creation time.

The following table shows the supported types, their Iceberg/Parquet storage,
and how each reads back:

| PG type | Iceberg/Parquet storage | Round trip |
|---|---|---|
| `bigint` / `integer` | `BIGINT` / `INTEGER` | Identical |
| `smallint` | `INTEGER` (Iceberg has no 16-bit integer) | The column reads back as `integer`. |
| `real` / `double precision` | `REAL` / `DOUBLE` | Identical |
| `boolean` | `BOOLEAN` | Identical |
| `timestamp with time zone` | `TIMESTAMPTZ` | Identical |
| `timestamp without time zone` | `TIMESTAMP` | Identical |
| `date` / `time without time zone` | `DATE` / `TIME` | Identical |
| `uuid` | `UUID` | Identical |
| `bytea` | `BLOB` | Identical |
| `text` / `varchar(N)` / `char(N)` | `VARCHAR` | The value is unbounded, the declared length is not enforced, and `char(N)` returns unpadded (`pg_typeof varchar`). |
| `numeric(P,S)` (P ≤ 38) | `DECIMAL(P,S)` | Identical |
| `jsonb` / `json` | `VARCHAR` | The view casts the value back to `json` (not `jsonb`, because Iceberg has no JSON primitive). |
| `interval` | `VARCHAR` | The view casts the value back to `interval`. |
| `vector(N)` / `halfvec(N)` | `FLOAT[]` (list of float) | The column reads back as `real[]`. |

The following types are rejected rather than silently downgraded to `VARCHAR`,
which would lose precision or identity:

- `inet`, `cidr` and `oid`, because pg_duckdb cannot process them (`inet` Oid
  869, `oid` Oid 26) in any query it plans, and every Iceberg-backed read is
  planned by pg_duckdb. No cast makes them readable; store IP data as `text`
  and `oid` values as `bigint`.
- `numeric` without explicit `(P,S)`, because Iceberg requires bounded
  decimals.
- custom enums, `xml`, `tsvector`/`tsquery`, range types, and multirange types.
- composite types and arrays. (Arrays would map to Parquet `LIST<…>` only if
  the element type is itself supported; that mapping is not yet implemented for
  decoupled mode.)
- pgvector's `sparsevec`.
- any type not enumerated above.

The narrowing is deliberate: a type that cannot round-trip exactly is rejected
rather than silently downgraded, because data that appears stored but changes
shape on read is worse than no support.

## Wrapper Helper: `coldfront.create_iceberg_table()`

Raw_query / iceberg_scan are functional but ergonomically poor - every read
needs `r['col']` accessor, every write needs a
`duckdb.raw_query('… DuckDB SQL …')` envelope. To make an Iceberg-only table as
easy to use as a PG table, ColdFront ships a single helper that provisions an
Iceberg-only table together with a PG-side wrapper view and a registry row that
makes the C hook to handle every DML on the view. After that, applications use
**plain PG syntax** against the named relation:

```sql
SELECT coldfront.create_iceberg_table(
    'public', 'events',
    '[
      {"name":"id",     "type":"bigint"},
      {"name":"ts",     "type":"timestamptz"},
      {"name":"status", "type":"text"},
      {"name":"data",   "type":"jsonb"}
    ]'::jsonb,
    '{month(ts)}'
);

INSERT INTO events VALUES (1, now(), 'ok', '{"k":1}');
SELECT id, status, data->>'k' FROM events WHERE id = 1;
UPDATE events SET status = 'done' WHERE id = 1;
DELETE FROM events WHERE id = 1;
```

The fourth argument, `p_partition_cols`, is the table's Iceberg partitioning as
a `text[]` of `PARTITIONED BY` terms, passed to DuckDB as written; the terms,
and how a term with a comma or a quoted name is written in the array literal,
are in [usage.md → Mode 2](usage.md#mode-2-decoupled-iceberg-only). DuckDB
refuses an unknown transform, a bad argument or a column outside the schema at
`CREATE TABLE`. The one check DuckDB leaves to the first INSERT, a time
transform on a column that is not a timestamp or date (for `hour`, not a
timestamp), `coldfront._partition_clause()` makes at the same point, while no
table exists yet.

The helper performs the following steps:

1. Creates the Iceberg namespace against Lakekeeper, idempotently, with
   `duckdb.raw_query('CREATE SCHEMA IF NOT EXISTS ice."public"')`.
2. Creates the Iceberg table with
   `duckdb.raw_query('CREATE TABLE ice.public.<name> (col1 STORAGE_TYPE, …) PARTITIONED BY (…)')`.
   Column types are validated by `coldfront._iceberg_storage_type()`, which
   mirrors the canonical map in `cmd/archiver/main.go pgFormatTypeToDuckDB`.
   Anything outside the supported set (see
   [Supported Column Types](#supported-column-types) above) raises before any
   DDL is issued.
3. Creates the wrapper view with
   `CREATE OR REPLACE VIEW <schema>.<name> AS SELECT r['col']::<view type> AS col, … FROM duckdb.query('SELECT * FROM ice.public.<name>') AS t(r)`.
   The projection wraps the struct accessor so applications see flat columns.
   Each column is cast to its view type where one exists (`json` for `jsonb`,
   `interval`, `double precision`, `bytea`, `real[]` for vectors), and to its
   storage type otherwise, so a `text` column reads as `character varying`. The
   view reads via `duckdb.query()` so read-your-own-write inside an explicit
   transaction works; pg_duckdb's planner folds it into the same `ICEBERG_SCAN`
   plan with identical Parquet predicate pushdown, so there is no performance
   cost.
4. Registers the row in `coldfront.tiered_views` with `is_iceberg_only = true`.
   The C-side `post_parse_analyze_hook` reads this flag and short-circuits
   `classify_tier()` to `TIER_COLD` for any INSERT/UPDATE/DELETE on the wrapper
   view, regardless of WHERE clause or watermark - so every write rewrites
   cleanly into a single
   `SELECT coldfront._exec_iceberg_with_claim(<ref>, 'INSERT/UPDATE/DELETE ice.public.<name> …')`.
   The hook is the dispatch path.

Writes through the wrapper view behave as follows:

- An INSERT adds the row to Iceberg, and a fresh session's SELECT sees it.
- A `COPY <view> FROM` adds its rows the same way, one INSERT per
  `coldfront.cold_write_batch_size` rows.
- An UPDATE changes the row in Iceberg, and a fresh session's SELECT sees the
  new value.
- A DELETE removes the row from Iceberg.
- A ROLLBACK of an INSERT/UPDATE inside `BEGIN` undoes the Iceberg snapshot, so
  the row count after the transaction matches the count before it.
- A jsonb column round-trips through Parquet `VARCHAR` storage and reads as PG
  `json` via the wrapper view's cast (`data->>'k'` works).

The helper inherits the following limit from the platform:

- The mixed-write guard is relaxed: the helper sets
  `duckdb.unsafe_allow_mixed_transactions = on` LOCAL during provisioning
  (Iceberg DDL + coldfront registry row both happen). The hook does the same
  for tiered INSERT splits and dual-tier UPDATE/DELETE, where PG-side and
  DuckDB-side writes share one transaction; iceberg-only DML does not need it.
  ROLLBACK still works via XactCallback; the flag only bypasses the pre-commit
  guard.

The helper does not add capability over raw_query - it composes the existing
primitives into a single call so applications get a normal-looking PG table.

## Wrapper Helper: `coldfront.adopt_iceberg_table()`

Adoption registers a table that already exists in the Iceberg catalog. The
wrapper view and the registry row are built from the schema the catalog holds,
and nothing is provisioned:

```sql
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake');
```

The following table describes the parameters:

| Parameter | Meaning |
|---|---|
| `p_schema` | Names the PostgreSQL schema that holds the wrapper view; the schema must exist. |
| `p_table` | Names both the view and the Iceberg table. |
| `p_namespace` | Names the Iceberg namespace the table lives in; NULL means `p_schema`. The namespace need not exist as a PostgreSQL schema. |
| `p_writable` | False registers the read path alone; true also enables the DML rewrite. |
| `p_types` | Overrides the types the columns read as, given as `{"column": "pg_type"}`. |

The schema is read with `DESCRIBE` through `duckdb.query()`, with
`duckdb.unsafe_allow_execution_inside_functions = on` set LOCAL for the call.
`DESCRIBE` is a metadata-only read: it scans no Parquet and works on a table
with no snapshot. Its rows arrive in Iceberg schema order, which fixes a
clustered table's cluster-column order.

Adoption differs from creation in three places: types map from Iceberg to
PostgreSQL, no `CREATE SCHEMA` or `CREATE TABLE` reaches the catalog, and the
registry row records writability. The C hook emits `tiered_views.iceberg_table`
verbatim, so a reference outside `ice.<pg_schema>.<pg_relname>` needs no
further handling.

### Types an Adopted Column Reads As

Iceberg records no PostgreSQL type, so the PostgreSQL types that share one
storage type all come back as the type that storage type reads as natively. The
following table shows the mapping, and which PostgreSQL types collapse onto
each row:

| Iceberg | DuckDB `column_type` | PostgreSQL type | Collapsed inputs |
|---|---|---|---|
| boolean | `BOOLEAN` | `boolean` | |
| int | `INTEGER` | `integer` | `smallint` |
| long | `BIGINT` | `bigint` | |
| float | `FLOAT` | `real` | |
| double | `DOUBLE` | `double precision` | |
| decimal(P,S) | `DECIMAL(P,S)` | `numeric(P,S)` | |
| date | `DATE` | `date` | |
| time | `TIME` | `time` | |
| timestamp | `TIMESTAMP` | `timestamp` | |
| timestamptz | `TIMESTAMP WITH TIME ZONE` | `timestamptz` | |
| string | `VARCHAR` | `text` | `varchar(N)`, `char(N)`, `jsonb`, `json`, `interval` |
| uuid | `UUID` | `uuid` | |
| binary, fixed[n] | `BLOB` | `bytea` | |
| list of float | `FLOAT[]` | `real[]` | `vector(N)`, `halfvec(N)` |

Nanosecond timestamps are refused, because PostgreSQL stores microseconds; so
are variant, geometry, struct, map, and lists of anything but float. The
refusal names the column and the Iceberg type, except for `timestamptz_ns` and
`geography`, which duckdb-iceberg refuses itself, with its own error, when the
table loads.

`p_types` sets the type a column reads as, so a `jsonb` column that ColdFront
created adopts as `jsonb` rather than `text`:

```sql
SELECT coldfront.adopt_iceberg_table(
    'public', 'orders', 'lake',
    p_writable => true,
    p_types    => '{"meta":"jsonb"}'::jsonb);
```

An override is accepted only where it maps to the storage type the catalog
holds. Both sides run through the same reverse map, so `timestamptz` matches
`TIMESTAMP WITH TIME ZONE` and `numeric(12, 2)` matches `DECIMAL(12,2)`, while
`bigint` over a `DECIMAL(12,2)` column is refused. An override cannot
reinterpret the stored bytes.

A `FLOAT[]` column whose Iceberg schema has a `_cf_vec_list_<column>` sibling
is recorded in `vec_columns`, and the cluster columns stay out of the view's
projection. Without the sibling the column is a plain `real[]`.

### Writability

The registry row has an `is_writable` flag, and the parse-analyze hook refuses
INSERT, UPDATE and DELETE on a relation whose flag is false:

```text
ERROR:  coldfront: "public.orders" is adopted read-only
HINT:  Release it with coldfront.release_iceberg_table() and adopt again with p_writable => true to arm INSERT/UPDATE/DELETE.
```

Reads never consult the flag. `vector_train()` and `drop_iceberg_table()`
refuse a read-only relation too, since each rewrites or destroys the Iceberg
table. The archiver and `create_iceberg_table()` set the flag; adoption
defaults it to false.

### One Relation per Iceberg Table

`coldfront.tiered_views` has a unique constraint on `iceberg_table`, and
adoption refuses a reference that is already registered. The cluster-column
lookups resolve a table by its reference, so two rows sharing one would
concatenate both tables' cluster columns into the first's INSERT list and fail
the second outright.

The archiver, `create_iceberg_table()` and adoption all store the reference
with every part quoted, such as `"ice"."lake"."orders"`, and the compactor
claims under that same spelling. The constraint and the bakery compare
references as strings, so each Iceberg table has exactly one.

### Adoption Binds the Name Once

A second `adopt_iceberg_table()` under a registered name is refused whatever
its arguments, as is a tiered relation's name. To enable writes, change an
override, or pick up an evolved schema, release the table and adopt it again;
the new view is built from the schema the catalog holds then.

In a Spock mesh one node adopts. The `CREATE VIEW` replicates through the
`ddl_sql` repset (`spock.allow_ddl_from_functions` is on) and the registry row
through the `default` repset, which enables the parse-analyze hook on every
peer; a peer's own adopt is refused as already registered. A release
unregisters everywhere, because the registry `DELETE` precedes the `DROP VIEW`
in the same transaction and disarms the peer's DDL hook before the drop is
applied there.

### Handing a Table Back

`coldfront.release_iceberg_table()` removes the wrapper view, the registry row
and the relation's vector configuration, and performs no Iceberg I/O, so the
Iceberg table keeps every row:

```sql
SELECT coldfront.release_iceberg_table('public', 'orders');
```

A plain `DROP VIEW` stays blocked by the DDL hook. A tiered registration is
refused, because releasing one would leave its cold rows unreachable while the
hot table returned under the relation's name.

### Limits

Adoption inherits three limits:

- writers outside ColdFront are outside the bakery, so Spark or any other
  engine on the same catalog can still collide with a ColdFront write at
  Lakekeeper. An in-house tool joins the protocol through
  `coldfront._claim_iceberg_external()`, as the Go compactor does.
- nested Iceberg namespaces are not reachable. The pinned duckdb-iceberg build
  joins the parts of a nested namespace with an unencoded separator byte in the
  request path, so a table under `lake.eu` cannot be loaded, from adoption or
  from `duckdb.query()`. A namespace that merely needs quoting, such as
  `Lake-EU`, works.
- adopting a table as the cold tier of an existing hot table is out of scope;
  the watermark and the partition configuration would have to be reconciled
  with data ColdFront did not write.

## Wrapper Helper: `coldfront.drop_iceberg_table()`

Drops the Iceberg table backing a registered relation, in either mode:

```sql
-- catalog entry and stored objects both go
SELECT coldfront.drop_iceberg_table('public', 'events', true);

-- catalog entry goes; Parquet and metadata objects stay in the bucket
SELECT coldfront.drop_iceberg_table('public', 'events', false);
```

One verb covers both modes because in both the thing being dropped is the
Iceberg table. What that means for PostgreSQL differs, because the modes
differ, and the function says which path it took in a NOTICE:

- For an iceberg-only table, the Iceberg table is the whole relation, so
  nothing remains. This is the inverse of `create_iceberg_table()`.
- For a tiered table, the Iceberg table is the cold tier, so the cold tier goes
  and the hot table returns under the relation's own name. This is the inverse
  of tiering, so the table ends up an ordinary partitioned Postgres table
  again, holding the data that had not yet aged out.

`p_purge` has no default, because the two outcomes are irreversible in opposite
directions. `true` deletes the data and metadata objects, which for the cold
tier are the only copy of that data. `false` leaves those objects in the object
store with no catalog entry, where no ColdFront component reclaims them, since
the compactor's expiry and orphan passes walk the snapshots of a table that
still exists. The caller states which one they mean.

The function performs the following steps:

1. Refuses a relation that is not registered in `coldfront.tiered_views`, so a
   drop never targets a relation ColdFront does not manage. A call on a
   physical standby is refused as well, through `coldfront._reject_on_standby`.
2. Takes the same per-table claim every other cold write takes, before it
   changes anything, so the drop keeps the global lock order. When
   `lock_timeout` is 0, the PostgreSQL default, the function sets it to 100 ms
   for the transaction, the same limit the archiver's cutover uses. A contended
   `ACCESS EXCLUSIVE` request then fails fast instead of queueing while the
   claim stalls cold writes on every node. A nonzero `lock_timeout` the
   operator set is kept.
3. Deletes the registration. For a tiered table that includes the
   `partition_config` and `archive_watermark` rows, because the archiver
   resolves its work from `partition_config` and a surviving row would re-tier
   the table into a catalog entry that no longer exists. Deleting the
   `tiered_views` row also disarms the C DDL hook for the relation, which is
   what permits step 4.
4. Drops the wrapper view, and for a tiered table renames the hot table back,
   reversing the rename the archiver's first run performed.
5. Drops the Iceberg table: through a separate attachment created with
   `PURGE_REQUESTED true` when `p_purge` is true, and through `ice` otherwise.
   Lakekeeper performs the object deletion itself, with the warehouse
   credential, so purge works unchanged under vended credentials.

Plain `DROP TABLE` and `DROP VIEW` on a registered relation stay blocked by the
DDL hook; this function is the sanctioned path. Destroying a cold tier is
deliberate, and a habitual statement is the wrong trigger for it.

Three properties are worth knowing:

- The purge decision is an ATTACH option in duckdb-iceberg rather than a
  statement clause, so a purging drop runs through a separate attachment,
  `ice_drop_purge`, which stays attached for the session. A non-purging drop
  runs through the long-lived `ice` attachment, which never has the option set.
- Purge is asynchronous. The catalog entry disappears with the drop, but the
  objects are removed by Lakekeeper's own background purge queue shortly
  afterwards, so a check made immediately after the call can still see them.
- Whether a purged table is recoverable is a property of the Lakekeeper
  warehouse, not of coldfront. Under the soft delete profile the dropped table
  stays restorable for the warehouse's expiration window before its objects are
  deleted; under the hard profile, which is Lakekeeper's default, there is no
  recovery window and the purge is queued as soon as the table is dropped. A
  table on which a Lakekeeper hold (`set_table_protection`) is set cannot be
  dropped at all, and this function cannot override that: the drop request
  sends `PURGE_REQUESTED` but never `force`.

## ACID Model

(This section summarizes material from [architecture.md](architecture.md)
§Concurrency and §Known Limitations applied to the decoupled scenario.)

The following table shows the status of each ACID property in decoupled mode:

| Property | Status |
|---|---|
| Atomicity (single statement) | Yes. One `duckdb.raw_query('INSERT/UPDATE/DELETE …')` is one DuckDB transaction and produces one Iceberg snapshot commit. |
| Atomicity (multi-statement tx, graceful) | Yes. pg_duckdb's `XactCallback` ties the DuckDB transaction to PG's, so PG `ROLLBACK` undoes pending Iceberg writes. |
| Atomicity (multi-statement tx, backend crash) | Partial. pg_duckdb commits the Iceberg snapshot at PRE_COMMIT, so a backend crash after that but before the PG commit record leaves the Iceberg write committed and the PG side lost. A crash after the Parquet upload but before the commit POST leaves unreferenced objects, which the compactor's orphan pass reclaims. |
| Consistency | Yes, within a snapshot: Iceberg's serializable model and Lakekeeper's optimistic concurrency provide it. |
| Isolation | Read-your-own-write within a tx works. Both the wrapper view, which reads through `duckdb.query('SELECT * FROM ice.…')`, and the plain `iceberg_scan('ice.…')` form read one Iceberg snapshot for the whole transaction: pg_duckdb runs one DuckDB transaction per PostgreSQL transaction, and duckdb-iceberg resolves the table as of that transaction's start. A commit by another session after the transaction's first read therefore stays invisible until the transaction ends, at READ COMMITTED as well as REPEATABLE READ (see [Limitations](#limitations)). pg_duckdb's planner folds the view's `duckdb.query(...)` into the same `ICEBERG_SCAN` plan as `iceberg_scan`, with identical predicate pushdown. |
| Durability | Yes. Iceberg commits are durable on the object store once Lakekeeper acknowledges them, which is stronger than PG WAL on local disk for many production setups. |

## Concurrency / Horizontal Scaling - The Bakery Protocol

Decoupled mode makes the data layer fully shared between any number of PG nodes
pointing at the same Lakekeeper endpoint and S3 bucket:

- Reads scale out because each PG node queries Lakekeeper and S3 independently.
  New nodes start in seconds, with no data sync.

- Writes are serialized PG-side by the bakery protocol so they never collide at
  Lakekeeper. The implementation is Lamport's 1978 distributed mutual exclusion
  with the Ricart-Agrawala (1981) deferred-reply optimization. Claims and acks
  travel as Spock-replicated rows (the two repset tables below); a writer
  commits only when it holds the minimum outstanding ticket and every live peer
  has acked (a peer defers its ack while it holds a smaller ticket). This stays
  safe under Spock's *asymmetric* apply - each node applies peers' rows on its
  own independent queue, so it never assumes a peer has applied its concurrent
  claim; the Snowflake-ticket total order and the ack barrier serialize
  commits, not any global apply ordering. The protocol is modeled in
  [docs/formal/Bakery.tla](https://github.com/pgEdge/ColdFront/blob/main/docs/formal/Bakery.tla);
  the safety properties are verified via TLA+ (`Bakery.cfg`).

    The protocol uses two tables, both in Spock's `default` repset:

    - Each writer inserts `(iceberg_table, ticket)` into `coldfront.claims`,
      and the row is deleted on release.
    - Peers insert `(ticket, ack_from_name, iceberg_table)` into
      `coldfront.claim_acks` to acknowledge an originator's claim, keyed by the
      acker's Spock node name. The ack replicates back to the originator and is
      deleted with the claim: only the originator's own wait loop ever reads
      its acks, so a row has no reader once the claim is gone.

    Locally on every node, `coldfront.deferred_acks` queues acks the node has
    *deferred* because it has its own pending claim with a smaller ticket on
    the same table. This table is not replicated.

    Each writer follows these steps:

    1. Take a fresh globally-unique ticket from `snowflake.nextval()`.
    2. Insert `(iceberg_table, ticket)` into `coldfront.claims` over the node's
       loopback, a libpq connection the extension's C code keeps (autonomous
       tx; replicates async via Spock). SQL reaches the loopback only through
       `coldfront._loopback()`, which PUBLIC cannot execute. Only a superuser
       can set its connection string, `coldfront.dblink_self`, and the loopback
       resolves names in `pg_catalog` only. The ticket is taken inside that
       transaction, under the table's claim key, and every lock it takes ends
       with it.
    3. Wait until both (a) no same-node writer has a smaller ticket on this
       table, and (b) every alive peer has acked the ticket (its row appears in
       `coldfront.claim_acks`).
    4. Issue the iceberg `duckdb.raw_query(...)` write, which is exactly one
       uncontested commit at Lakekeeper.
    5. Release the claim at PG outer-transaction end (COMMIT or ABORT): the
       ticket is enqueued at claim time (`_enqueue_release`) and the C
       `XactCallback` deletes the claim over a loopback connection at the
       COMMIT event. pg_duckdb commits the Iceberg transaction earlier, at
       PRE_COMMIT, so the snapshot is committed before the claim is released;
       on ABORT the claim is deleted before pg_duckdb discards the uncommitted
       Iceberg work. The release trigger drains `coldfront.deferred_acks` for
       that ticket, emitting any acks the node had been holding back.

    This is the stock ordering. With `coldfront.iceberg_async_parquet` and
    `coldfront.iceberg_bakery_patch` both on, as the shipped image sets them, a
    mesh writer stages the Parquet upload through `duckdb.raw_query` first and
    takes the claim afterwards; only the commit POST runs under the claim, with
    the parent snapshot re-stamped by the bakery-aware patch. With
    `coldfront.iceberg_async_parquet` on and `coldfront.iceberg_bakery_patch`
    off, `coldfront._iceberg_async_active()` returns false, and the writer
    keeps the stock ordering and logs the downgrade once per session.

    A transaction takes one claim per table and holds it until it ends, so a
    second cold write to the same table in that transaction rides the first
    claim.

    Peer-side, when Spock applies an incoming claim INSERT, an `ENABLE REPLICA`
    trigger (`coldfront._on_claim_apply`) decides:

    - If the peer has its own pending claim with a *smaller* ticket on the same
      table, it first asks whether that claim can have a live owner (see
      *Orphan reaping* below); if it can, the trigger defers the ack, queueing
      it in `coldfront.deferred_acks` to emit later when the smaller claim is
      released.
    - Otherwise, the trigger acks immediately by inserting into
      `coldfront.claim_acks` over the loopback, so the row is tagged with the
      local node as origin and Spock replicates it back to the originator.

    The same trigger fires on UPDATE, for the waiter's poke described under
    *Orphan reaping*.

    The protocol works across **any number of writers per node** - each call
    holds its own unique ticket; release deletes by ticket only, so concurrent
    backends on the same node coexist cleanly. Same-node writers serialize on a
    node-local advisory transaction lock per Iceberg table, held across the
    whole claim + commit, so at most one same-node writer is inside the bakery
    at a time; the wait loop also requires that no same-node claim with a
    smaller ticket exists on the table (Snowflake tickets are per-node
    monotonic + timestamped, so a smaller ticket means `nextval` was called
    earlier on this node).

    **Orphan reaping.** A claim row whose owner is gone (a hard backend crash;
    an ERROR takes the ABORT callback, which releases normally) would otherwise
    strand its own node's later writers, through rule (a), and any peer that
    deferred behind it, through the deferral it can no longer drain. The proof
    that a same-node claim is ownerless is the per-table advisory transaction
    lock: a live writer holds `coldfront_iceberg:<table>` from its claim INSERT
    until its transaction ends, and the release runs in the COMMIT callback
    before PostgreSQL drops that lock, so whoever holds it knows every other
    same-node claim on the table has no owner. Three paths use that proof, each
    riding a statement the bakery already executes, with no timeout, scheduler
    or background worker:

    - On the claim path, `_claim_iceberg_lock` already holds the lock for its
      own table. Its claim transaction on the loopback (`_insert_claim`) tries
      the lock of every other table this node has a claim on; a lock the
      claimant's own transaction holds makes the try fail, so a transaction
      never reaps its own claims. The claim transaction then deletes every
      same-node claim on those tables (and, after a restart, any claim from
      before `pg_postmaster_start_time()`) together with their acks before
      inserting the new claim, so any cold write on the node clears every
      orphan the node left. The DELETE fires the release trigger, which
      forwards whatever peers had deferred behind the orphan.
    - On the apply path, when a peer's claim arrives and a smaller same-node
      claim exists, `_on_claim_apply` tries the lock
      (`pg_try_advisory_xact_lock`). Success means no live local writer, so it
      deletes the same-node claims and their acks through the loopback and acks
      the arrival instead of deferring it. A live writer's lock makes the try
      fail at once, and the trigger defers as before.
    - The waiter's poke covers a peer that deferred while the lock was held and
      whose holder then vanished, because that peer sees no further event. A
      writer in the wait loop therefore re-touches its own claim row about once
      a second (a no-op UPDATE); the UPDATE replicates, the peer's trigger runs
      the apply path again for that ticket, and the orphan is reaped. A poke
      that reaps nothing is silent, so no ack is ever issued after its claim is
      gone.

    A node only ever deletes its own claims: a peer's claim that looks
    abandoned may belong to a partitioned node mid-write, and it enters neither
    wait condition anyway. Orphan reaping is modeled as the `Reaper` constant,
    the `Applier`'s reap branch and the `Poker` process in `Bakery.tla`:
    `Bakery_wedge.cfg` shows the stranding without it, and `Bakery_reaper.cfg`
    and `Bakery_reaper_quiet.cfg` show liveness and all four safety invariants
    holding with it, the second in the case where nothing but the poke ever
    reaches the crashed node.

    The wait phase has no explicit timeout. R-A's only failure mode is a dead
    peer (would block forever), and ColdFront closes it via a liveness check on
    `pg_stat_replication.reply_time`: a peer whose walsender has been silent
    longer than `coldfront.peer_alive_window_ms` (default 5000 ms; tune up on
    slow/lossy WAN links) is implicitly treated as already-acked. An *alive*
    peer that has not acked is either deferring (R-A's defer rule, legitimate)
    or about to ack - either way, waiting is correct. A same-node claim is
    released by the C XactCallback in
    [extension/coldfront/src/coldfront.c](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/src/coldfront.c)
    at commit or abort, and one whose writer is gone is removed by the reaper.

    The mechanics live in
    [extension/coldfront/coldfront--1.0.sql](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--1.0.sql)
    (`_claim_iceberg_lock`, `_insert_claim`, `_on_claim_apply`,
    `_on_claim_release`, `_exec_iceberg_with_claim`) and the C-side rewrite and
    loopback in
    [extension/coldfront/src/coldfront.c](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/src/coldfront.c)
    (`cold_exec_call`, `cf_loopback_exec`).

    Because every commit is uncontested, the duckdb-iceberg writer never has to
    deal with a 409 - no rebase-retry loop needed at all. (Upstream
    `duckdb-iceberg` does not implement one; the bakery sidesteps the
    requirement.)

- For DDL, Spock's `ddl_sql` repset replicates `CREATE/ALTER/DROP` of the
  wrapper view, and the `default` repset replicates the
  `coldfront.tiered_views` registry row (see
  [Distributed Setup](usage.md#distributed-setup-3-node-mesh-decoupled-mode)),
  so one node provisions the table and replication enables every peer's hook.

### Throughput Characterization

The commit-rate ceiling sits at Lakekeeper, not at the PG side, so scale
throughput with larger per-INSERT batches or by partitioning the Iceberg table.

### Required Configuration on Every PG Node

Apply the following settings on every PG node, starting with the server-wide
settings:

```ini
# postgresql.conf - server-wide
wal_level = logical
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'

# Spock's apply worker does not read this setting: on an idle link,
# pg_stat_replication.reply_time refreshes only on the walsender's
# reply-requested keepalive, every wal_sender_timeout/2 (30 s by default).
wal_receiver_status_interval = 1s

# Sync-rep is NOT required by the bakery - R-A's ack barrier replaces it.
```

Then apply the per-node settings:

```ini
# postgresql.conf - per-node. snowflake.node is any integer 1..1023, unique per
# node; the value is otherwise arbitrary. The bakery matches acks by spock node
# name (dead-peer detection joins claim_acks.ack_from_name to spock.node), so it
# imposes no relationship between snowflake.node and the node name.
snowflake.node = 1     # node1
# snowflake.node = 2   # node2
# snowflake.node = 3   # node3

# DSN of the loopback that runs the bakery's autonomous claim/ack/release statements (unix socket).
coldfront.dblink_self = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_dblink'

# Optional - peer-liveness window for R-A's dead-peer escape; a peer
# whose reply_time is older than this is treated as already-acked.
coldfront.peer_alive_window_ms = 5000
```

The bakery runs only on a node where both `snowflake.node` and
`coldfront.dblink_self` are set, which `coldfront._bakery_armed()` checks on
every cold write. A node missing either setting serializes its cold writes on a
transaction-scoped local advisory lock instead. That lock orders the writers on
one node only, so every mesh node needs both settings.

The bakery has no peer-ack timeout knob. Dead peers are caught by the
`pg_stat_replication.reply_time` liveness check inside the wait-loop (a stale
walsender is treated as already-acked); alive peers that have not acked are
either deferring legitimately or about to ack.

For the per-node bootstrap, after Spock mesh setup, register the bakery tables
in each node's default repset. This step is required because
`spock.repset_add_table` needs the local Spock node to exist (it cannot run at
`CREATE EXTENSION` time):

```sql
-- run on every node, after spock.node_create + spock.sub_create:
SELECT coldfront._ensure_claims_replicated();
```

The helper is idempotent. If the helper has not run on a peer, that peer's ack
INSERTs are local-only and never replicate back to the originating writer:
every claim on the originator waits forever at the ack barrier.

`coldfront.create_iceberg_table()` and
`coldfront.adopt_iceberg_table(p_writable => true)` call
`_ensure_claims_replicated()` on the node they run on, but that only registers
the repset on *that* node. Peers receive the wrapper-view DDL via Spock's
`ddl_sql` repset but do *not* re-run the helper - so the explicit per-node call
above is mandatory in any multi-node setup.

## When to Use Decoupled vs Tiered

The two modes suit different workloads; the guidance below summarizes when each
one fits.

Decoupled (iceberg-only) is the right choice when:

- The application's read path is dominated by analytic OLAP queries (cold-tier
  analytic reads run substantially faster than PG heap on shape-matched
  workloads).
- Operational simplicity outweighs ergonomics: no archiver cron, no watermark,
  no autovacuum-vs-cutover lock conflict (see
  [architecture_tiered.md → Tiered-Specific Limitations](architecture_tiered.md#tiered-specific-limitations)),
  no PK rebuild after bulk load, no partition-management script.
- You can accept that cold reads in one transaction share one Iceberg snapshot,
  even at READ COMMITTED (see [Limitations](#limitations)). Tables created via
  `create_iceberg_table()` are queried with plain SQL through the wrapper view;
  the verbose `iceberg_scan` / `raw_query` syntax applies only to tables used
  without the helper.
- You want true storage/compute decoupling: adding compute means starting a new
  PG node with `docker run`, with no data sync.

Tiered (the default) is the right choice when:

- The workload has a strong recent-row OLTP component that needs PG-native
  point lookups, indexes, and transactional UPDATE/DELETE ergonomics.
- The application queries through a stable named relation (`events`). Decoupled
  tables created via `create_iceberg_table()` also provide this through the
  wrapper view; only tables used without the helper need the
  `iceberg_scan(...)` or `raw_query(...)` forms.
- You need full PG ACID isolation across the whole table.

## Limitations

Decoupled mode has the following limitation:

- The cold tier keeps one Iceberg snapshot for the whole transaction, even at
  READ COMMITTED: a commit by another session after the transaction's first
  cold read stays invisible until the transaction ends, where PostgreSQL would
  show it to the next statement.

## Next Steps

To go further with ColdFront, consult the following documents:

- The [Architecture](architecture.md) overview describes the mechanics both
  modes share.
- The [Formal Verification](formal/README.md) document describes the TLA+ model
  of the bakery protocol and how to check it.
- The [Using ColdFront](usage.md) guide covers creating decoupled tables and
  setting up a distributed mesh.
