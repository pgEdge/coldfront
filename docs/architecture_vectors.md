# Vector storage architecture

Reference for maintainers. Embeddings live in the cold (Iceberg) tier as
`list<float>`; PostgreSQL holds the hot rows, the routing centroids, and nothing
proportional to the corpus.

## Type mapping and the two column forms

A `vector(n)` or `halfvec(n)` column maps to Iceberg `FLOAT[]`, and the tiered
view exposes it as `real[]`, because DuckDB has no `vector` type and both arms of
a `UNION ALL` view must agree on one type. `real[]` and `FLOAT[]` are the same
type under two spellings.

pg_duckdb maps PostgreSQL types by OID and has no entry for an extension type.
The refusal lands on the column reference while the plan is built, so no cast in
a projection can rescue it. Any plan carrying a pgvector column fails regardless
of how few rows can match.

The hot table therefore carries a companion:

```sql
_cf_vec_<col> real[] GENERATED ALWAYS AS (<col>::real[]) STORED
```

Every hot-side read goes through it: the view's hot branch, the bulk export's
projection, and the SQL-side view rebuild. `view.Column.HotRef` decides this on
the Go side and `coldfront._vec_companion` derives the same name on the SQL side;
the two must agree. `coldfront._is_vec_companion` keeps the companion out of
every column list that describes the user's table, so the Iceberg schema, the
view, the INSERT lists and the cross-tier move each carry exactly one column per
user column. Teardown drops it.

`STORED` is required: PostgreSQL rejects `VIRTUAL` for a user-defined function's
expression. A hot row therefore stores its embedding twice. Cold rows, which are
all of the data by design, do not.

## The search operators

`coldfront.install_vector_ops()` creates three functions and three operators on
`(real[], real[])` in pgvector's own schema, resolved from the catalog rather
than hardcoded:

| Operator | Function | Metric |
|---|---|---|
| `<=>` | `list_cosine_distance` | cosine |
| `<->` | `list_distance` | Euclidean |
| `<#>` | `list_negative_inner_product` | negative inner product |

pg_duckdb resolves an operator by its implementing function's *name* in DuckDB's
catalog, so the names above are the mechanism, not a convention. The PostgreSQL
bodies are real implementations that delegate to pgvector, because a hot-only
(pre-cutover) view has no Iceberg scan to pull the query into DuckDB and
PostgreSQL executes them itself.

The function runs at onboarding rather than at `CREATE EXTENSION`, and installs
pgvector if it is absent. `CREATE EXTENSION coldfront` never requires pgvector.

A caller's own `vector` literal resolves without substitution: `vector -> real[]`
is an implicit cast, only implicit coercions count during operator resolution,
and pgvector's cast function is immutable so a constant folds. The same cast
makes an `INSERT` of a `vector` value coerce to the column.

## Routing state

Two tables, both name-keyed so a Spock mesh replicates them by value and every
node resolves a vector to the same cluster id without sharing OIDs:

| Table | Holds |
|---|---|
| `coldfront.vector_config` | `nlist`, `nprobe`, the live `generation`, `addition_cap`, per (schema, table, column) |
| `coldfront.vector_centroids` | the centroids themselves, keyed additionally by `(generation, centroid_id)`, with `parent_id` for an adaptive addition |

Both are registered in Spock's `default` replication set by
`coldfront._ensure_vector_state_replicated()`, gated on the spock extension so
vanilla is a no-op, and both are `pg_extension_config_dump`-marked: losing them
makes every stored cluster id uninterpretable and forces a retrain.

`vector_centroids.centroid` is `real[]`, not a pgvector value. These tables are
created with the extension, which must install on a database that has no vectors
and may never have any. Scoring against them goes through the same `<=>` shim a
caller uses.

A generation is immutable. A retrain writes a new one and moves the pointer, so
an assignment already stored keeps meaning what it meant, and the primary key
rejects a repeated `centroid_id` within one generation.

`coldfront.tiered_views.vec_column` records which column is clustered. It cannot
be derived afterwards in either mode: the view exposes `real[]` rather than the
pgvector type, and a decoupled table names its types without holding them.

## The cluster column

`_cf_vec_list integer` exists in the Iceberg schema and nowhere else. It is not a
column of the hot table and neither branch of the view projects it, so no query
written against the view can name it.

It **leads** the Iceberg schema. Iceberg schema evolution appends, and a cold
INSERT is positional, so a column added later has to land after everything both
sides already agree on. Trailing the cluster column would put a user's
`ADD COLUMN` on the far side of an internal column and silently misalign every
positional write.

`coldfront._vec_list_col()` and `view.VecListColumn` are the two spellings of the
name.

## Assignment

`coldfront._vec_list_expr(schema, table, column, vec_expr)` is the only place a
cluster assignment is defined. Given the text of an expression that yields the
vector as DuckDB sees it, it returns:

```sql
(SELECT arg_min(c.centroid_id, list_cosine_distance(c.centroid, <vec_expr>))
   FROM pglocal.coldfront.vector_centroids c
  WHERE c.schema_name = … AND c.table_name = … AND c.column_name = …
    AND c.generation = (SELECT vc.generation FROM pglocal.coldfront.vector_config vc
                         WHERE …))
```

A row whose cluster disagrees with its vector is invisible to its own search and
reports no error, which is why every path emits this and none derives its own.

**Centroids are read over `pglocal`.** Inside `duckdb.raw_query` DuckDB has no
PostgreSQL catalog at all: `duckdb_tables()` is empty and neither
`pgduckdb.public.<t>` nor `public.<t>` resolves. pg_duckdb's in-process reads of
PostgreSQL tables exist only for statements PostgreSQL plans, where the planner
binds the relation and hands the scan down as part of the converted plan. A cold
write is a `raw_query` string that DuckDB binds itself, so an attachment is the
only route in. `coldfront.ensure_pg_attached()` loads DuckDB's `postgres`
extension and attaches the local instance as `pglocal`, with the DSN from the
`coldfront.local_pg_dsn` GUC. Consequences: the PostgreSQL table stays the only
copy of the centroids, no path inlines a centroid set, and no path keeps a
session copy it has no way to check.

**The generation is resolved by the emitted SQL, not baked into it.** A statement
generated once, such as a trigger body, keeps assigning against the live
generation after a retrain instead of filtering on one that no longer exists.

Before any training the config carries no generation, the inner query matches
nothing, and the expression yields `NULL`. Unassigned is a legitimate value: rows
a foreign engine appended straight to Iceberg carry none either, and the read
path handles them explicitly.

A retrain cannot interleave with a cold write, because an operation that rewrites
the table holds the table's claim and every cold write serialises on that same
claim.

### The seven paths

| Path | Where | Shape |
|---|---|---|
| bulk archive | the Iceberg INSERT in `cmd/archiver`, not the staging SELECT | set-based |
| tiered trigger INSERT | `internal/view` (Go) and `coldfront._rebuild_tiered_view` (SQL twin) | per statement |
| slow per-row INSERT | `coldfront._tiered_insert_cold` | per row, cursor loop |
| cross-tier move | `coldfront._move_row_literal` | per row |
| replay drain | `coldfront.replay_archive_delta` | set-based |
| decoupled INSERT | the C rewrite | per statement |
| cold UPDATE that sets the vector | the C rewrite | expression text |

The archiver derives in the statement that writes Iceberg rather than in the
staging SELECT, because only the DuckDB statement can reach the centroids. The
staging table holds the user's own columns.

The decoupled INSERT is targeted, so it is re-emitted over a derived table:

```sql
INSERT INTO <ice> (_cf_vec_list, <cols>)
SELECT <lookup>, <cols> FROM (<source>) AS coldfront_src(<cols>)
```

The cold UPDATE adds one SET item before the statement's own WHERE, or at the end
when it has none. `find_toplevel_where` locates it by tracking quotes before
parens, because a literal can contain the word, a sublink carries its own one
level down, and a literal can hold an unbalanced paren. This lives in
`build_cold_dml` rather than in a caller: the cold path and the dual path both
build their cold half through it, and an ambiguous predicate takes the dual path.

The replay drain casts a vector to `real[]` in its scratch projection, because
DuckDB reads that scratch over libpq and cannot scan the pgvector type.

`pglocal` is attached only where a lookup will run: `_exec_iceberg_with_claim`
attaches when the statement names it, the generated triggers emit the attach only
for a clustered table, and the per-row paths guard on
`coldfront._types_have_vector`.

The generated trigger's placeholder list is apostrophe-escaped, because the
INSERT template is itself a single-quoted string and the assignment expression
carries the literals that name its configuration row.

## Training

`CALL coldfront.vector_train(schema, table, column, nlist, sample, iterations)`.

A `PROCEDURE`, not a function, and this is a hard requirement. pg_duckdb refuses
to execute a DuckDB query inside a function (`DuckDB execution is not supported
inside functions`); a procedure and a `DO` block are exempt. `raw_query` does run
inside a function but is a bare DuckDB channel with no PostgreSQL catalog, so a
function can move data in neither direction.

Lloyd iterations run as DuckDB statements over a reservoir sample, with fixed
`REPEATABLE` seeds so a retrain on unchanged data reproduces the same centroids.
The mean recompute unnests the vector against a matching `range` so the two lists
advance together, because DuckDB has no `WITH ORDINALITY`. The sample and the
working tables live in `memory.main`, which is session-scoped, so the whole loop
must run in one call.

The centroids return through a temporary heap table. A single
`INSERT … SELECT FROM duckdb.query(…)` fails with `DuckDB does not support
modifying Postgres tables`, because a DuckDB source makes the whole statement
DuckDB's, so the read and the write are separate statements.

Empty clusters do not come back from the mean, so the stored count can be below
`nlist`; the actual count is recorded rather than padded. A `vector_config` row
must exist first, since it holds the generation pointer the procedure writes.

## Layout

Three properties, set at `CREATE TABLE`:

| Property | Value | Read by |
|---|---|---|
| `write.parquet.row-group-limit` | `2048` | iceberg-go |
| `write.target-file-size-bytes` | `536870912` | both |
| `coldfront.sort-key` | the cluster column, then the key | the compactor |

Row groups are the pruning granularity: the Parquet reader skips a row group
whose statistics cannot match the filter, and at 2048 rows a group holds a median
of one cluster. The two writers each read one row-group property and ignore the
other. DuckDB reads only `write.parquet.row-group-size-bytes`, and a table
carrying that property refuses every DuckDB write to it (`ROW_GROUP_SIZE_BYTES
does not work while preserving insertion order`), so it is not set. A DuckDB
write therefore emits one row group per file and compaction is what cuts them.

The file target is large because on object storage every file a query touches is
a billed round trip.

The sort key's leading column is what a compaction orders its inputs by. The key
after it is a tiebreak for determinism, not a pruning aid: sorting by cluster
scatters a cluster's rows through key space.

Properties cannot be altered after creation on this build, so a table that
predates its vector column keeps the defaults.

**Batch cold writes order by cluster.** The archiver's Iceberg INSERT and the C
bulk INSERT append `ORDER BY 1` (the cluster leads the projection) plus the key,
so each new file is internally sorted and its own row groups prune. No existing
file is touched: sorted regions accumulate, and a probe reads the matching row
group in each of them.

## Reading: the probe

`cf_maybe_inject_probe` runs on the read path, alongside the hot-tier reroute and
the jsonb normalisation, and it is what makes the layout worth maintaining. It
recognises one shape and rewrites it:

- a single-relation `SELECT` on a registered view with a clustered vector column,
- ordered by exactly one cosine distance between that column and a constant,
- with a `LIMIT`,
- and at the top level of the statement: the hook sees one `Query`, so a top-k
  nested in a subquery or a CTE is not the query it is looking at. Wrapping a
  search to aggregate over it therefore makes it exact.

Everything else is left byte-identical. That is an exact scan over both tiers,
which is correct, and it is what the product did before there was a layout.

Three of those conditions are load-bearing. **The `LIMIT`** is part of the shape
because a probe trades recall for reads: that is the bargain a top-k asks for, and
not one to impose on a query that asked for every row in order. **Cosine only**,
because the centroids were trained under cosine, and ordering by `<->` or `<#>`
would route to clusters chosen under a different metric and quietly return the
wrong rows. **A constant query vector**, because pg_duckdb converts neither a
`vector` nor a `real[]` bound parameter, so a search that could only be resolved
from a parameter could not have run at all.

The rewrite resolves the nearest `nprobe` centroid ids
(`coldfront._vec_probe_ids`), turns them into a predicate
(`coldfront._vec_probe_qual`), and substitutes the view reference for the view's
own definition carrying that predicate on its cold arm
(`coldfront._vec_probed_viewdef`):

```sql
… WHERE r['ts'] < <cutoff>
  AND (r['_cf_vec_list']::integer IN (3, 17) OR r['_cf_vec_list']::integer IS NULL)
```

The substitution exists because the predicate has nowhere else to go: the cluster
column is in no branch of the view, so no query written against the view can name
it. Adding the test inside the definition puts it where the column exists and
leaves the user's column list alone. It is a range-table entry swapped for a
subquery, not text surgery on the caller's SQL, and PostgreSQL deparses the
result.

The hot arm is untouched: hot rows carry no assignment and every one of them is
returned.

**The null disjunct is not optional.** Rows another engine appended straight to
Iceberg carry no assignment, and a bare `IN` drops them silently. It is also not
expensive, because the reader prunes on each row group's null count: unassigned
rows are read in proportion to their own size rather than the table's.

**Declining is total and silent.** No centroid generation, an empty probe set, a
view with no cold arm: each keeps today's query. This is the one place in the
vector path that fails open, and deliberately so. A read that loses its predicate
is slower, never wrong. A *write* that cannot resolve a generation fails loudly
instead, because a wrong cluster id makes a row invisible to its own probe.

Two session knobs, both `PGC_USERSET`:

| GUC | Default | Effect |
|---|---|---|
| `coldfront.vector_probe` | `on` | `off` gives the exact scan a recall measurement compares against |
| `coldfront.vector_nprobe` | `0` | `0` uses the column's configured `nprobe`; a value at or above `nlist` is exhaustive |

## Current gaps

These are properties of the code as it stands, not plans.

- **Compaction degrades a clustered layout.** The compactor concatenates files
  ordered by their lower bound, which preserves order only when the input ranges
  do not overlap. Two internally sorted files of mixed clusters always overlap,
  so folding them produces row groups that straddle cluster junctions. A
  clustered table's layout holds until its first compaction. Closing this needs a
  sort-merge on the sort column, whose inputs are each already sorted.
- **`coldfront._tiered_insert_cold` writes unsorted.** Its cursor loop appends in
  cursor order and would need buffering to sort. It is the fallback path for a
  tiered INSERT that omits an IDENTITY column.
- **There is no operation that establishes clustering on an existing corpus.**
  Training writes centroids, and writes after it are assigned, but rows written
  before it stay unassigned until they are rewritten.
- **There is no `vector_status`.** Rows per cluster against the one-row-group
  floor, and row groups touched per probe over the clustered ideal, are the
  signals a retrain decision needs and nothing reports them.

## Constraints that are correctness

- **The query vector is a literal, never a bound parameter.** A parameter typed
  `vector` fails to convert, and so does one typed `real[]`, on a custom plan as
  much as a generic one. A scalar parameter elsewhere in the same query is fine.
- **`'{…}'::real[]` does not work as the query vector.** It reaches DuckDB as a
  VARCHAR and fails to cast. The spelling is `ARRAY[…]::real[]`.
- **`embedding::vector <=> …` fails** with `Type with name vector does not
  exist!`, and materialising the read does not help. The unadorned form resolves,
  so nothing needs the cast.
- **There is no PostgreSQL-side fallback.** Once a view embeds `iceberg_scan`,
  DuckDB owns the whole query and a function it lacks is a hard error rather than
  a slow path. Every expression the product wants users to write has to resolve
  in DuckDB.
- **Cosine everywhere.** Assignment and search both use cosine. `list_distance`
  is Euclidean and would be silently wrong against cosine centroids.
- **No `EXCEPTION` block in any of this plpgsql.** pg_duckdb rejects
  subtransactions outright.
- **`coldfront.local_pg_dsn` must be set** for a clustered table, or the
  assignment lookup fails with `Catalog 'pglocal' does not exist`. The shipped
  container configuration sets it.
