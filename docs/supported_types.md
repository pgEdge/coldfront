# Supported Column Types

The following PostgreSQL column types are supported:

- `bigint`.
- `integer`.
- `smallint`.
- `real`.
- `double precision`.
- `boolean`.
- `timestamp with time zone`.
- `timestamp without time zone`.
- `date`.
- `time without time zone`.
- `uuid`.
- `text`.
- `varchar(N)`.
- `char(N)`.
- `bytea`.
- `numeric(P,S)` (P ≤ 38).
- `jsonb` / `json`.
- `interval`.
- `vector(N)` / `halfvec(N)` (pgvector; see
  [Working with Embeddings](usage_vectors.md)).
- one-dimensional arrays of most of these types (see
  [Supported Array Types](#supported-array-types)).

Other data types (unbounded `numeric`, `xml`, `tsvector`, range/multirange types,
custom enums, composite types, pgvector's `sparsevec`, `inet`, `cidr`, `oid`,
and the arrays that [Supported Array Types](#supported-array-types) lists
as refused at registration) are
rejected when a tiered table is registered, and when a decoupled table is
created. ColdFront refuses silent fallback to `varchar` - losing
precision/identity is worse than no support. `inet`/`cidr`/`oid` are
rejected because pg_duckdb cannot process them in any Iceberg-backed query,
so no cast makes them readable; store IP data as `text` and `oid` values as
`bigint` instead (you can still index/compare them; cast on the hot side
only if needed).

A few supported types need a closer look:

- Iceberg cannot hold a `numeric` `NaN`, or an `infinity` or `-infinity`
  value in a `date`, `timestamp with time zone` or `timestamp without time
  zone` column, as array elements too. The hot tier of a tiered table refuses
  those values with a check constraint named `coldfront_guard_<column>`. The
  cold tier refuses an infinity, and stores a `numeric` `NaN` from PostgreSQL
  as `NULL`. Such a `NaN` comes from the rows that a tiered `INSERT` sends to
  the cold tier, or from a PostgreSQL table that a cold write reads. DuckDB
  refuses a `'NaN'` literal or bound parameter in a statement that DuckDB runs,
  such as a decoupled `INSERT` or a cold `UPDATE`, because DuckDB's decimal has
  no `NaN`.
- `char(N)` is stored and read as `varchar`. Values, comparisons, and
  `length()` round-trip losslessly, but a cold read comes back unpadded as
  `character varying`, because pg_duckdb has no fixed-length `char` type. Use
  `text` or `varchar` if blank-padded display matters.
- `json` and `jsonb` are stored as `varchar` in Iceberg, which has no JSON
  primitive. A read returns a `jsonb` column as `jsonb` and a `json` column
  as `json`.
- `interval` is stored as `varchar` in Iceberg, as `<months> months <days>
  days <seconds> seconds`, the text PostgreSQL and DuckDB both read as the
  same value; it is view-cast back to the rich PG type on read.

The archiver adds the `NaN`/infinity constraints at the first archive pass
that tiers a partition of the table, and validates them once that pass's
bootstrap transaction has committed. A value written before then is accepted,
and each archive pass stops with an error that names the constraint until the
row is fixed; the next pass then validates the constraint and tiers the
table. A column that an `ALTER TABLE` adds through the DDL hook gets its
constraint in the same statement, which PostgreSQL validates against every
row of the hot table, so an `ADD COLUMN` whose default the constraint
refuses, such as `DEFAULT 'NaN'`, fails. A renamed column's constraint takes
the new column name, and a column whose name is longer than 47 bytes gets a
constraint named after a hash of the name.

A cold `UPDATE ... FROM` or `DELETE ... USING`, a `MERGE` whose source is a
PostgreSQL table, and an `INSERT ... SELECT` into a decoupled table read that
PostgreSQL table through DuckDB's `postgres` extension, which reads a `numeric`
`NaN` as `NULL`, also inside an array, and drops an array's lower bound.
ColdFront cannot refuse those values on that path: the write stores `NULL` for
the `NaN` and the array numbered from 1, with no error, and its conditions
compare the changed values. An unbounded `numeric` column reads as `double
precision`, so its `NaN` fails the cast to a `numeric(P,S)` column instead. A
condition that names `'NaN'` fails in such a write, because DuckDB does not
accept `'NaN'` as a `numeric` value. To keep those values out of the cold
tier, check the source table in PostgreSQL before the write, and fix or remove
the rows that hold them.

The following query counts those rows in a source table `staging` with a
`numeric` column `amount`, a `numeric` array `amounts` and an array `tags`:

```sql
SELECT count(*)
  FROM staging
 WHERE amount = 'NaN'
    OR 'NaN' = ANY (amounts)
    OR array_lower(tags, 1) <> 1;
```

List every `numeric` column, `numeric` array and array column of your source
table the same way; a count of `0` means that the write stores those columns
unchanged.

Queries like `data->>'key'` and `data->'key'` work against `jsonb`. In a read
that DuckDB runs, a `jsonb` column, a `::jsonb` cast and the results of `->`,
`#>`, `jsonb_build_object` and `jsonb_agg` are `jsonb`, as they are on a
PostgreSQL table, and PostgreSQL receives each such value as `jsonb`.
PostgreSQL receives an `array_agg` of such values as `jsonb[]`.
ColdFront translates `jsonb_array_length`, `jsonb_build_object` / `jsonb_agg`
(and their `json_` twins, which DuckDB also lacks) and `date_bin` on read: the
builders become a `concat` / `to_json` / `array_agg` form both engines
evaluate, and `date_bin` becomes DuckDB's `time_bucket`, which takes the same
arguments and agrees on every fixed-width bucket. In a read that DuckDB runs,
the `pg_typeof` function names the type PostgreSQL resolved for its argument,
as `text`, so compare it with a string such as `'integer'` rather than a
`regtype`; ColdFront refuses it there over a set-returning expression, such as
`pg_typeof(generate_series(1, 2))`. A read that PostgreSQL runs itself returns
the `regtype` that `pg_typeof` returns on a table.

DuckDB holds a `jsonb` value as JSON text, and ColdFront stores each `jsonb`
value as the text PostgreSQL renders it in. A stored document therefore
compares with another stored document, a constant or a parameter as that text.
A value that DuckDB computes, such as the result of `->`, `#>`,
`jsonb_build_object` or a `::jsonb` cast of text, compares through DuckDB's
`json()` function, which removes the white space between tokens. The `=` and
`<>` operators, `IS DISTINCT FROM`, `NULLIF`, an `IN` list, `IN (SELECT ...)`
and a simple `CASE` return PostgreSQL's answers, with three differences:

- Two numbers that differ only in scale, such as `1` and `1.0`, compare as
  unequal, as they fall in separate groups in `DISTINCT`, `GROUP BY` and
  `UNION`.
- The `json()` function reads a decimal as a double precision number, so
  where one side is a value that DuckDB computes, two decimals that are equal
  at double precision compare as equal.
- An object that DuckDB builds keeps its keys in the order it was given them,
  and keeps a repeated key, where `jsonb` sorts its keys and keeps the last of
  a repeated one. Such an object comes from a `::jsonb` cast of text, or from
  `jsonb_build_object` with a key that is not a constant, so it can compare as
  unequal to a stored document with the same keys and values. A stored
  document, a constant, and a `jsonb_build_object` whose keys are all
  constants compare as PostgreSQL compares them. ColdFront refuses a
  `jsonb_build_object` that repeats a key when a value before the last one is
  not a constant.

A cold write stores only the text PostgreSQL renders. The value that a cold
`INSERT`, `UPDATE` or `MERGE` assigns to a `jsonb` column must therefore be a
constant, a `jsonb` parameter, a `jsonb` column of a table or of a tiered or
decoupled view, or a `CASE` or `COALESCE` that picks one of those. ColdFront
refuses any other value with an error that names the column, because DuckDB
would compute the value and store DuckDB's text. The refused values include
`jsonb_build_object('a', 1)`, `data || '{"seen": true}'` and a `::jsonb` cast
of text. An `UPDATE` of the hot tier and a tiered `INSERT` accept any value,
because PostgreSQL computes the value there.

DuckDB also evaluates the condition of a cold `UPDATE`, `DELETE` or `MERGE`
and the source of a decoupled `INSERT`. These compare `jsonb` values as a read
that DuckDB runs does, and ColdFront refuses in them what it refuses in such a
read, as the following rules describe. A cold write therefore changes the rows
that a read with the same condition returns. ColdFront also refuses an
`ALTER TABLE` that changes a column of a tiered or decoupled table to `jsonb`,
because the cold rows keep the text they were written in.

An adopted JSON column reads as `json`, and ColdFront refuses `jsonb` for an
adopted table. For the reason, see
[Adopting a Table That Already Exists in the Catalog](usage_decoupled.md#adopting-a-table-that-already-exists-in-the-catalog).

The following rules apply to the other statements that compare `jsonb` values:

- `DISTINCT`, `GROUP BY` and `UNION` group values by their text, so two
  stored documents fall in one group when PostgreSQL renders them identically.
  A value that DuckDB computes falls in another group than an equal stored
  document or constant.
- ColdFront refuses every ordering of a value that holds `jsonb`, because
  DuckDB orders such values by their text: an `ORDER BY` at any level, in a
  window or in an aggregate, the `<`, `<=`, `>` and `>=` operators, `GREATEST`
  and `LEAST`, `min` and `max`, and a row comparison. A value holds `jsonb`
  when it is a `jsonb` value, or an array, a row or a domain over one.
- ColdFront refuses `=`, `<>` and `IS DISTINCT FROM` on an array or a row that
  holds `jsonb`, because DuckDB compares its `jsonb` parts by their text;
  compare the `jsonb` values one by one.
- ColdFront refuses a join that names a `jsonb` column in `USING`, and a
  `NATURAL` join over one; write the join condition with `ON`.
- ColdFront refuses `IN (SELECT ...)` over a `UNION` or a `VALUES` list, one
  whose sub-select groups or de-duplicates the compared column and has a
  `HAVING` or an `ORDER BY`, and a row comparison such as
  `(id, doc) IN (SELECT ...)`. ColdFront also refuses `= ANY` of a `jsonb[]`
  value, an `IN` list whose operand is volatile, such as one that calls
  `random()`, and another `jsonb` operator, such as `@>`, under `ANY` or `ALL`.

ColdFront also rewrites the JSON operators that DuckDB lacks into DuckDB's JSON
functions, which return PostgreSQL's answers. The rewrite covers:

- the `#>`, `#>>`, `?`, `?|`, `?&`, `@>` and `<@` operators.
- the `json_extract_path` and `jsonb_extract_path` functions and their `_text`
  forms.
- the `jsonb_exists`, `jsonb_exists_any` and `jsonb_exists_all` functions.
- the `jsonb_contains` and `jsonb_contained` functions.

A path or key for these operators and functions must be a constant or a bound
parameter, not a column, and in a cold write it must be a constant. A path can
hold at most eight negative, signed or zero-padded index elements, such as
`-1`, `+1` or `01`. Two kinds of result differ from PostgreSQL's. The `->>` and
`#>>` operators return a container as DuckDB writes it, such as `{"b":"c"}`,
and DuckDB writes an extracted number in its own form, such as `1.5` for
`1.50`. The `@>` and `<@` operators never match an integer against the same
value written as a decimal. For example, a stored `{"p": 10.0}` does not
contain `{"p": 10}`, because DuckDB compares JSON numbers by kind. Inside the
query, `::text` of an extracted or built value returns DuckDB's compact text,
such as `{"b":1}`; the value PostgreSQL receives is `jsonb` and renders as
PostgreSQL renders it.

ColdFront refuses any other `jsonb` operator or function in a read of tiered
or decoupled data, such as `||`, `-`, `#-`, `jsonb_typeof`, `jsonb_set`,
`jsonb_path_*`, `jsonb_each`, `jsonb_object_keys` and a cast of `jsonb` to a
number or `boolean`, with an error that names the operator or function.
DuckDB either lacks these, or answers differently: its `||` concatenates the
text of the two documents.

These limits apply only to statements that DuckDB runs: the reads of a tiered
or iceberg-only view that reach the cold tier, and the part of a cold write
that DuckDB evaluates. In a read that PostgreSQL runs itself, such as a read
rerouted to the hot partitions or a read of a tiered view before its first
archive, PostgreSQL compares and orders `jsonb` values itself. ColdFront
refuses no ordering in such a read, and none of the operators and functions
in the paragraph above. A read that uses an operator or function the rewrite
turns into DuckDB's, such as `?` or `date_bin`, runs in DuckDB. Ordinary
(non-tiered) PostgreSQL tables are untouched by ColdFront and keep full jsonb
support, as does the hot partition table itself.

Bound parameters (`$1` from a prepared statement, a driver's extended protocol,
or a plpgsql variable) work in such reads. DuckDB types most placeholders from
their context (`ts > $1`); one that is a direct argument of a DuckDB function
with several overloads (`time_bucket`'s origin, so `date_bin`'s) or any
argument of a table function (`generate_series`) it cannot, so ColdFront plans
such a read from the bound values on every execution instead of caching a
generic plan. The rewrite of `#>`, `#>>`, `?`, `?|`, `?&`, `@>` and `<@` also
needs the value of any parameter in an operand, and pg_duckdb cannot hand a
`jsonb` parameter to DuckDB. ColdFront plans such reads from the bound values
on every execution as well. Under
`plan_cache_mode = force_generic_plan` those reads cannot run: the forced
generic plan has no values and fails with `only works with DuckDB execution`.

A hot-only read is the exception. When a `SELECT` reads a tiered view directly
(no join, CTE, or sub-query) and its `WHERE` provably restricts to the hot
tier, ColdFront rewrites it to read the hot partition table in plain
PostgreSQL: the full jsonb operator and function set works, and the query skips
DuckDB entirely. Reads that span tiers, are cold-only, or reach the view
through a join or sub-query stay in DuckDB, where the limits above apply.

## Supported Array Types

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
error that names no column. A write that reads the array from a PostgreSQL
table stores it renumbered from 1 instead. A tiered table with a column
declared with more than one dimension, such as `integer[][]`, passes registration and is refused
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
