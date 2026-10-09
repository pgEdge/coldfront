# Understanding Supported Column Types

The following PostgreSQL column types are supported:

`bigint` · `integer` · `smallint` · `real` · `double precision` ·
`boolean` · `timestamp with time zone` · `timestamp without time zone` ·
`date` · `time without time zone` · `uuid` · `text` · `varchar(N)` ·
`char(N)` · `bytea` · `numeric(P,S)` (P ≤ 38) · `jsonb` / `json` ·
`interval` · `vector(N)` / `halfvec(N)` (pgvector; see
[usage_vectors.md](usage_vectors.md)) · one-dimensional arrays of most of
these types (see [Arrays](#arrays))

Anything else (unbounded `numeric`, `xml`, `tsvector`, range/multirange types,
custom enums, composite types, pgvector's `sparsevec`, and the arrays that
[Arrays](#arrays) lists as refused at registration) is rejected when a tiered
table is registered, and when a decoupled table is created. ColdFront refuses
silent fallback to `varchar` - losing precision/identity is worse than no
support.

Iceberg cannot hold a `numeric` `NaN`, or an `infinity` or `-infinity` in a
`date`, `timestamp` or `timestamptz` column, so ColdFront refuses those values,
as array elements too. A tiered table's hot table has a check constraint named
`coldfront_guard_<column>` on each column of those types and on each array
column; an `INSERT` or `UPDATE` that stores one of the values fails with an
error that names the constraint. A write that goes to the cold tier, in either
mode, is refused by DuckDB.

The archiver adds the constraints at the first archive pass that tiers a
partition of the table, and validates them once that pass's bootstrap
transaction has committed. A value written before then is accepted, and each
archive pass stops with an error that names the constraint until the row is
fixed; the next pass then validates the constraint and tiers the table. A
column that an `ALTER TABLE` adds through the DDL hook gets its constraint in
the same statement, which PostgreSQL validates against every row of the hot
table, so an `ADD COLUMN` whose default the constraint refuses, such as
`DEFAULT 'NaN'`, fails. A renamed column's constraint takes the new column
name, and a column whose name is longer than 47 bytes gets a constraint named
after a hash of the name.

A cold `UPDATE ... FROM`, a `MERGE` whose source is a PostgreSQL table, and an
`INSERT ... SELECT` into a decoupled table read that PostgreSQL table through
DuckDB's postgres extension, which reads a `numeric` `NaN` as `0` and drops an
array's lower bound. ColdFront cannot refuse those values on that path, so
filter them out of such a source.

`char(N)` is stored and read as `varchar`. The data round-trips losslessly:
values, comparisons, and `length()` match a hot PG table, where `length()`
already ignores `char(N)` trailing padding. The only difference is cosmetic: a
cold `char(N)` column reads back unpadded with `pg_typeof varchar`, because
pg_duckdb has no fixed-length `char` type. Use `text` or `varchar` if
blank-padded display matters.

`json`, `jsonb` and `interval` are stored as `varchar` in Iceberg (no native
primitive). On read, `interval` is view-cast back to the rich PG type; `json`
and `jsonb` come back as DuckDB's `json` (the equivalent of PG's `jsonb`), not
the rich PG `jsonb` type, because Iceberg-backed reads run entirely in DuckDB.
Queries like `data->>'key'` and `data->'key'` work, and ColdFront translates
the `::jsonb` cast, `jsonb_array_length`, `jsonb_build_object` / `jsonb_agg`
(and their `json_` twins, which DuckDB also lacks) and `date_bin` on read: the
builders become the `concat` / `to_json` / `array_agg` form both engines
evaluate identically (the result is JSON-equal to jsonb's rendering, in compact
form and in argument order), and `date_bin` becomes DuckDB's `time_bucket`,
which takes the same arguments and agrees on every fixed-width bucket. The
jsonb-only operators (`?`, `@>`, `<@`, `#>`, `#>>`) and most jsonb functions
(`jsonb_typeof`, `jsonb_extract_path`, `jsonb_extract_path_text`, `jsonb_set`,
`jsonb_path_*`, `jsonb_each`, `jsonb_object_keys`) are not supported on tiered
or decoupled data: DuckDB either lacks them or its same-named function differs
in signature or result. Reach into the document with `->`/`->>`.

These limits apply only to reads that go through a tiered or iceberg-only view,
which pg_duckdb plans entirely in DuckDB. Ordinary (non-tiered) PostgreSQL
tables are untouched by ColdFront and keep full jsonb support, as does the hot
partition table itself.

Bound parameters (`$1` from a prepared statement, a driver's extended protocol,
or a plpgsql variable) work in such reads. DuckDB types most placeholders from
their context (`ts > $1`); one that is a direct argument of a DuckDB function
with several overloads (`time_bucket`'s origin, so `date_bin`'s) or any
argument of a table function (`generate_series`) it cannot, so ColdFront plans
such a read from the bound values on every execution instead of caching a
generic plan. Under `plan_cache_mode = force_generic_plan` those reads cannot
run: the forced generic plan has no values and fails with
`only works with DuckDB execution`.

A hot-only read is the exception. When a `SELECT` reads a tiered view directly
(no join, CTE, or sub-query) and its `WHERE` provably restricts to the hot
tier, ColdFront rewrites it to read the hot partition table in plain
PostgreSQL: the full jsonb operator and function set works, and the query skips
DuckDB entirely. Such a read returns `data` as native `jsonb` rather than the
view's `json`. Reads that span tiers, are cold-only, or reach the view through
a join or sub-query stay in DuckDB, where the limits above apply.

`inet`/`cidr`/`oid` are **not supported**: pg_duckdb cannot process them
(`inet` Oid 869, `oid` Oid 26) in any Iceberg-backed query, and every
cross-tier read is planned by pg_duckdb - so no cast makes them readable. Store
IP data as `text` and `oid` values as `bigint` (you can still index/compare
them; cast on the hot side only if needed).

### Arrays

A one-dimensional array of a supported type tiers as an Iceberg list of that
type. The following table shows how each array type is stored and how the view
reads it back:

| PG type | Iceberg/Parquet storage | Reads back as |
|---|---|---|
| `bigint[]`, `integer[]`, `real[]`, `double precision[]`, `boolean[]`, `date[]`, `time[]`, `timestamp[]`, `uuid[]`, `bytea[]`, `numeric(P,S)[]` | A list of the element's storage type. | The same type. |
| `smallint[]` | A list of `INTEGER`. | `integer[]`, as a `smallint` column reads as `integer`. |
| `text[]` | A list of `VARCHAR`. | `text[]`. |
| `varchar(N)[]`, `char(N)[]` | A list of `VARCHAR`. | `character varying[]`, with `char(N)` elements unpadded. |

The following arrays are refused when a tiered table is registered and when a
decoupled table is created, with an error that names the column:

- `timestamptz[]`, because pg_duckdb cannot read a `timestamptz[]` column of a
  PostgreSQL table, which a tiered table's hot tier is; store `timestamp[]` in
  UTC instead.
- `jsonb[]`, `json[]` and `interval[]`, because those types are stored as text
  and read back through a cast that an array element does not get.
- arrays of `vector` or `halfvec`, because a vector is itself stored as a list,
  and ColdFront stores an array as a list of scalar values.

An Iceberg list has one dimension and numbers its elements from 1, so ColdFront
refuses an array with more than one dimension or with a lower bound other than
1, such as `'[0:2]={1,2,3}'`. The hot table's check constraint refuses such an
array when it is written. A write to the cold tier refuses it too: a tiered
`INSERT` with an error that names the column, and a bound parameter with an
error that names no column. A tiered table with a column declared with more
than one dimension, such as `integer[][]`, passes registration and is refused
at its first archive pass, because pg_duckdb reads a column by its declared
dimensions; a decoupled table refuses such a column when it is created. A
decoupled table's array type is spelled as its element type followed by `[]`,
such as `integer[]`; the spellings `integer[3]` and `integer ARRAY` are
refused. `ALTER TABLE ... ADD COLUMN` cannot add an array column to a tiered
table, because duckdb-iceberg does not add a nested column to an Iceberg table.

A tiered `INSERT` accepts an array in any spelling, because its source runs in
PostgreSQL. A cold `UPDATE` and a decoupled `INSERT` run in DuckDB, which does
not read PostgreSQL's brace literal: a `'{a,b}'` literal reaches DuckDB as text
and fails to cast. Write the array as `ARRAY['a', 'b']`, or pass it as a bound
parameter.

Reads through a view run in DuckDB once the table has a cold tier, and the
following array operations work there:

- `x = ANY(arr)`, `arr @> ARRAY[...]` and `arr && ARRAY[...]`.
- subscripts and slices, which count from 1, such as `arr[1]` and `arr[1:2]`.
- `array_length(arr, 1)` and `unnest(arr)`.

A brace literal and a bound array parameter fail in such a read, as they do for
a vector, and so does `cardinality()`, which DuckDB defines for maps only.
