# Vector Storage Architecture

This page is a reference for maintainers. Embeddings live in the cold (Iceberg)
tier as `list<float>`; PostgreSQL holds the hot rows, the routing centroids,
and nothing proportional to the corpus.

## Type Mapping and the Two Column Forms

A `vector(n)` or `halfvec(n)` column maps to Iceberg `FLOAT[]`, and the tiered
view exposes it as `real[]`, because DuckDB has no `vector` type and both arms
of a `UNION ALL` view must agree on one type. `real[]` and `FLOAT[]` are the
same type under two spellings.

pg_duckdb maps PostgreSQL types by OID and has no entry for an extension type.
The refusal lands on the column reference while the plan is built, so no cast
in a projection can rescue it. Any plan that includes a pgvector column fails
regardless of how few rows can match.

The hot table therefore has a companion:

```sql
_cf_vec_<col> real[] GENERATED ALWAYS AS (<col>::real[]) STORED
```

Every hot-side read goes through the companion: the view's hot branch, the bulk
export's projection, and the SQL-side view rebuild. `view.Column.HotRef`
decides this on the Go side and `coldfront._vec_companion` derives the same
name on the SQL side; the two must agree. `coldfront._is_vec_companion` keeps
the companion out of every column list that describes the user's table, so the
Iceberg schema, the view, the INSERT lists and the cross-tier move each have
exactly one column per user column. Teardown drops the companion.

`STORED` is required: PostgreSQL rejects `VIRTUAL` for a user-defined
function's expression. A hot row therefore stores its embedding twice. Cold
rows, which are all of the data by design, do not.

## The Search Operators

`coldfront.install_vector_ops()` creates three functions and three operators on
`(real[], real[])` in pgvector's own schema, resolved from the catalog rather
than hardcoded. The following table shows each operator, its function, and its
metric:

| Operator | Function | Metric |
|---|---|---|
| `<=>` | `list_cosine_distance` | cosine |
| `<->` | `list_distance` | Euclidean |
| `<#>` | `list_negative_inner_product` | negative inner product |

pg_duckdb passes the operator symbol to DuckDB, which resolves `<=>` and `<->`
as its own aliases of `list_cosine_distance` and `list_distance`. DuckDB has no
`<#>`, so that operator fails with a parser error on any query DuckDB runs, and
`list_negative_inner_product(…)` is the spelling that works there. The
PostgreSQL function names match DuckDB's, so the function-call form resolves
too and the probe can recognize the sort expression. The PostgreSQL bodies are
real implementations that delegate to pgvector, because a hot-only
(pre-cutover) view has no Iceberg scan to pull the query into DuckDB and
PostgreSQL executes them itself.

The function runs at onboarding rather than at `CREATE EXTENSION`, and installs
pgvector if it is absent. `CREATE EXTENSION coldfront` never requires pgvector.

A caller's own `vector` literal resolves without substitution:
`vector -> real[]` is an implicit cast, only implicit coercions count during
operator resolution, and pgvector's cast function is immutable so a constant
folds. The same cast makes an `INSERT` of a `vector` value coerce to the
column.

## Routing State

Two tables hold the routing state. Both are name-keyed, so a Spock mesh
replicates them by value and every node resolves a vector to the same cluster
id without sharing OIDs. The following table describes what each one holds:

| Table | Holds |
|---|---|
| `coldfront.vector_config` | The table holds `nlist`, `nprobe`, the live `generation`, and `addition_cap` (reserved, default 0) for each (schema, table, column). |
| `coldfront.vector_centroids` | The table holds the centroids themselves, keyed additionally by `(generation, centroid_id)`, with a `parent_id` column that no code path sets. |

Both are registered in Spock's `default` replication set by
`coldfront._ensure_vector_state_replicated()`, gated on the Spock extension so
vanilla is a no-op, and both are `pg_extension_config_dump`-marked: losing them
makes every stored cluster id uninterpretable and forces a retrain.

`coldfront._unregister_iceberg`, which both `release_iceberg_table` and
`drop_iceberg_table` call, deletes the table's rows from both tables. The
centroids and the configuration describe the table that registration named, so
a relation registered later under the same name must not inherit them. Such a
relation starts with no `vector_config` row, and its first training seeds with
k-means++.

`vector_centroids.centroid` is `real[]`, not a pgvector value. These tables are
created with the extension, which must install on a database that has no
vectors and may never have any. Scoring against them goes through the same
`<=>` shim a caller uses.

A generation is immutable. A retrain writes a new one and moves the pointer, so
an assignment already stored keeps meaning what it meant, and the primary key
rejects a repeated `centroid_id` within one generation.

`coldfront.tiered_views.vec_columns` records which columns are clustered, in
order. The list cannot be derived afterwards in either mode: the view exposes
`real[]` rather than the pgvector type, and a decoupled table names its types
without holding them.

## The Cluster Columns, and Which One Owns the Sort Order

A table may have several vector columns. The Iceberg schema gets one cluster
column per vector column, `_cf_vec_list_<column>`, leading the schema in column
order, and every write path assigns all of them. The registry records the
ordered list in `tiered_views.vec_columns`, and that order is a contract: a
cold INSERT is positional, so the prefix must fill the cluster columns in
exactly the order the schema declares them. `_vec_list_prefix` raises rather
than emitting a short prefix, because a short one would land every following
value in the wrong column.

**Only `vec_columns[1]` appears in `coldfront.sort-key`.** A Parquet file has
one physical row order, and pruning depends on a cluster's rows being adjacent
so the reader can skip row groups on their statistics. Ordering by a second
cluster column after the first would scatter its values inside every band of
the first, leaving its statistics bounding the whole file. So a later column's
probe filters the rows scored and prunes nothing read. Column read and decode
is ~95% of query cost, so that is worth single-digit percent rather than a
multiple. `cf_vector_status.prunes` reports which column is which.

The read path needs no registry lookup to pick between them: it takes the
column name off the `ORDER BY` expression's Var and derives that column's
cluster column from it. A column with no configuration resolves to no probe set
and the rewrite declines.

`_cf_vec_list_<column> integer` exists in the Iceberg schema and nowhere else.
The column is not part of the hot table and neither branch of the view projects
it, so no query written against the view can name it. `_cf_vec_list_<column>`
**leads** the Iceberg schema. Iceberg schema evolution appends, and a cold
INSERT is positional, so a column added later has to land after everything both
sides already agree on. Trailing the cluster column would put a user's
`ADD COLUMN` on the far side of an internal column and silently misalign every
positional write.

`coldfront._vec_list_col(column)` and `view.VecListColumn(column)` are the two
spellings of the name.

Adoption rebuilds `vec_columns` from the Iceberg schema, the only place the
cluster columns' order can come from. `adopt_iceberg_table` reads the schema
with `DESCRIBE`, whose rows arrive in schema order. It records each
`_cf_vec_list_<column>` as a clustered `<column>` instead of projecting it, and
runs `coldfront.install_vector_ops()` when it finds one. The routing state does
not come back with the columns: an adopted column has no `vector_config` row
and no centroids, so its probe declines until a configuration row is inserted
and `vector_train` runs.

## Assignment

`coldfront._vec_list_expr(schema, table, column, vec_expr)` is the only place a
cluster assignment is defined for a write; its formula, `_vec_nearest_expr`, is
shared with the assignment at the end of training. Given the text of an
expression that yields the vector as DuckDB sees it, it returns:

```sql
(SELECT arg_min(c.centroid_id, list_cosine_distance(c.centroid, <vec_expr>))
   FROM pglocal.coldfront.vector_centroids c
  WHERE c.schema_name = … AND c.table_name = … AND c.column_name = …
    AND c.generation = (SELECT vc.generation FROM pglocal.coldfront.vector_config vc
                         WHERE …))
```

A row whose cluster disagrees with its vector is invisible to its own search
and reports no error, which is why every path emits this and none derives its
own.

**Centroids are read over `pglocal`.** Inside `duckdb.raw_query` DuckDB has no
PostgreSQL catalog at all: `duckdb_tables()` is empty and neither
`pgduckdb.public.<t>` nor `public.<t>` resolves. pg_duckdb's in-process reads
of PostgreSQL tables exist only for statements PostgreSQL plans, where the
planner binds the relation and hands the scan down as part of the converted
plan. A cold write is a `raw_query` string that DuckDB binds itself, so an
attachment is the only route in. `coldfront.ensure_pg_attached()` loads
DuckDB's `postgres` extension and attaches the local instance as `pglocal`,
with the DSN from the `coldfront.local_pg_dsn` GUC. As a consequence, the
PostgreSQL table stays the only copy of the centroids, no path inlines a
centroid set, and no path keeps a session copy it has no way to check.

**The generation is resolved by the emitted SQL, not baked into it.** A
statement generated once, such as a trigger body, keeps assigning against the
live generation after a retrain instead of filtering on one that no longer
exists.

Before any training the config has no generation, the inner query matches
nothing, and the expression yields `NULL`. Unassigned is a legitimate value:
rows a foreign engine appended straight to Iceberg have none either, and the
read path handles them explicitly.

A retrain cannot interleave with a cold write, because an operation that
rewrites the table holds the table's claim and every cold write serializes on
that same claim.

### The Eight Paths

Every path that can put a row into a clustered table's Iceberg storage must
derive that row's cluster assignment. The following table shows the eight paths
that do so, where each one lives, and its shape:

| Path | Where | Shape |
|---|---|---|
| bulk archive | the Iceberg INSERT in `cmd/archiver`, not the staging SELECT | set-based |
| tiered INSERT, cold half | the C rewrite (`build_cold_bulk_call`) | per statement |
| tiered trigger INSERT | `coldfront._rebuild_write_trigger` (called by the archiver and by `_rebuild_tiered_view`) | per row |
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
INSERT INTO <ice> (_cf_vec_list_<col>, <cols>)
SELECT <lookup>, <cols> FROM (<source>) AS coldfront_src(<cols>)
```

The cold UPDATE adds one SET item per clustered vector column it sets, before
the statement's own WHERE, or at the end when it has none.
`find_toplevel_where` locates that WHERE by tracking quotes before parens,
because a literal can contain the word, a sublink has its own WHERE one level
down, and a literal can hold an unbalanced paren. This lives in
`build_cold_dml` rather than in a caller: the cold path and the dual path both
build their cold half through it, and an ambiguous predicate takes the dual
path.

The replay drain casts a vector to `real[]` in its scratch projection, because
DuckDB reads that scratch over libpq and cannot scan the pgvector type.

`pglocal` is attached only where a lookup will run: `_exec_iceberg_with_claim`
attaches when the statement names it, the generated triggers emit the attach
only for a clustered table, and the per-row paths guard on
`coldfront._types_have_vector`.

The generated trigger's placeholder list is apostrophe-escaped, because the
INSERT template is itself a single-quoted string and the assignment expression
contains the literals that name its configuration row.

## Training

Training computes a fresh set of centroids for one column and reassigns every
cold row's cluster against them, through this signature:

`CALL coldfront.vector_train(schema, table, column, nlist, sample, iterations)`.

It is a `PROCEDURE`, not a function. pg_duckdb refuses to execute a DuckDB
query inside a function (`DuckDB execution is not supported inside functions`)
unless `duckdb.unsafe_allow_execution_inside_functions` is on; a procedure and
a `DO` block need no unsafe setting. `raw_query` does run inside a function,
but it is a bare DuckDB channel with no PostgreSQL catalog.

Lloyd iterations run as DuckDB statements over a reservoir sample. The sample
and the first k-means++ seed use fixed `REPEATABLE` seeds, but later k-means++
draws use DuckDB's unseeded `random()`, so a fresh training is not
reproducible; a retrain at the same `nlist` continues from the live centroids
instead. The mean recompute unnests the vector against a matching `range` so
the two lists advance together, because DuckDB has no `WITH ORDINALITY`. The
sample and the working tables are DuckDB temporary tables, session-scoped, so
the whole loop must run in one call; temporary rather than `memory.main`
because a DuckDB transaction may write one attached database, the temporary
database is exempt, and the assignment at the end writes `ice`.

The centroids return through a temporary heap table. A single
`INSERT … SELECT FROM duckdb.query(…)` fails with
`DuckDB does not support modifying Postgres tables`, because a DuckDB source
makes the whole statement DuckDB's, so the read and the write are separate
statements.

Empty clusters do not come back from the mean, so the stored count can be below
`nlist`. Rather than padding, `vector_train` stores the trained count in
`vector_config.nlist` and lowers `nprobe` to it if needed. Both change in one
`UPDATE`, because a row with `nprobe` above `nlist` fails the `vc_nprobe_fit`
check and would abort the whole training transaction. A `vector_config` row
must exist first, since it holds the generation pointer the procedure writes.

A retrain at the same `nlist` (a call without `p_nlist`, or with the trained
count) starts the iterations from the live centroids instead of fresh seeds, so
each centroid keeps its id and moves with its data. It reads the live centroids
over `pglocal`, so it needs `coldfront.local_pg_dsn` like a cold write. A first
training, or a changed `nlist`, has no set to start from and seeds with
k-means++. Neither reads anything over `pglocal`, because the assignment at the
end scores against the session's copy of the new centroids.

Training ends with the loop's final step applied to the table rather than the
sample: every cold row is assigned to its nearest centroid of the generation
just written, in one claimed `UPDATE` whose `WHERE` is
`cluster IS DISTINCT FROM nearest`, so only a row whose cluster changed is
rewritten and a row with no cluster counts as changed. The UPDATE scores rows
against the session's copy of the new centroids (`temp.main.cf_gen`), because
the rows inserted into `vector_centroids` in this transaction are invisible
over `pglocal` until commit; the formula is `_vec_nearest_expr`, the same one
every write path uses. The pointer and the assignments commit together, so no
search ever reads a row against centroids it was not assigned under. The claim
is held from the sample to the commit, as the compactor holds it across its
read and rewrite, so a cold write cannot land between the two with an
assignment against the replaced set. What the pass leaves behind is a
merge-on-read delete per rewritten row, and those rows in update order;
compaction resolves both.

Seeds come from k-means++: one sample row at random, then each next drawn with
probability proportional to its squared distance from the nearest seed already
chosen, by an exponential race (the minimum of `-ln(u)/w` is a weighted draw,
in one pass and with no cumulative sum). The running distance folds in only the
seed just added, keyed on an insertion sequence rather than a row id, so a
round is one pass over the sample.

Seeding costs about 46 ms per seed on a 20,000-row sample, so `nlist` 1000 adds
roughly 45 seconds and `nlist` 10,000 about eight minutes, on top of Lloyd's
iterations. Training is a one-time operation and nothing a query pays.

What the spread start defends against is seeds clumping in a dense region,
which Lloyd cannot repair because it only moves centroids locally. That matters
most at the lower dimensionalities many embedding models produce; above about
1000 dimensions distances concentrate and the starting spread makes little
difference either way.

## Layout

Three table properties are set at `CREATE TABLE`. The following table shows
each property, its value, and what reads it:

| Property | Value | Read by |
|---|---|---|
| `write.parquet.row-group-limit` | `2048` | iceberg-go |
| `write.target-file-size-bytes` | `536870912`, unpartitioned only | DuckDB writes |
| `coldfront.sort-key` | the cluster column, then the primary key on a tiered table (the cluster column alone on a decoupled one) | the compactor |

Row groups are the pruning granularity: the Parquet reader skips a row group
whose statistics cannot match the filter. The two writers each read one
row-group property and ignore the other. iceberg-go honors the 2048-row limit,
so a compacted file's groups hold a median of one cluster. DuckDB ignores
`write.parquet.row-group-limit`. It honors `write.parquet.row-group-size`, a
row count ColdFront does not set, and it refuses every write to a table that
sets `write.parquet.row-group-size-bytes`
(`ROW_GROUP_SIZE_BYTES does not work while preserving insertion order` when
unpartitioned, and a not-supported error when partitioned), so that property is
not set either: a DuckDB write emits its own row groups of up to 122,880 rows,
each a contiguous slice of the ordered stream, and compaction is what cuts them
down.

The file target is large because on object storage every file a query touches
is a billed round trip. A partitioned table (every tiered table, and a
decoupled one created with `p_partition_cols`) is created without it: DuckDB
refuses the property on a partitioned table and does not split a partitioned
write by size anyway. The compactor ignores the property on every table and
takes its target from `--target-size-mb` (default 128 MiB).

The compactor sorts on the sort key's leading column only. The key after it is
a tiebreak for determinism in the archiver's own `ORDER BY`, not a pruning aid:
sorting by cluster scatters a cluster's rows through key space.

ColdFront sets these properties only at `CREATE TABLE` and never alters them,
so a table that predates its vector column keeps the defaults.

**Batch cold writes order by cluster.** The archiver's Iceberg INSERT appends
`ORDER BY 1` (the cluster leads the projection) plus the key, and the C bulk
INSERT and the decoupled INSERT append `ORDER BY 1`, so each new file is
internally sorted and its own row groups prune. No existing file is touched:
sorted regions accumulate, and a probe reads the matching row groups in each of
them.

**Compaction merges those regions rather than appending them.** A table with
`coldfront.sort-key` is rewritten group by group through `rewriteSorted`
(`cmd/compactor/compact.go`), which reads the group with `Scan.ReadTasks`,
sorts it on the sort column, and writes it back with `WriteRecords`. Appending
the files in key order, which is what the compactor did while the only
clustered files came from a single sorted pass, preserves order only while
their ranges are disjoint, and an incremental write's file spans the whole of
cluster space by construction. What that would cost is a run count: a probe
reads at least one row group per sorted run, so bounding file count without
merging the runs bounds the wrong thing.

**A partition is a run boundary.** Compaction merges within a partition, never
across, so a table partitioned by month holds at least one sorted run per
month. A search with a time filter skips the months outside it at the manifest
level; a search over all of history reads about one row group per probed
cluster per month instead of one.

The two halves are iceberg-go's own, which is what makes the merge safe rather
than merely correct on a good day. Reading through the scan applies the
position deletes a cold UPDATE or DELETE left behind; writing through
`WriteRecords` produces files with field ids, column statistics and the table's
row-group limit. Touching the Parquet directly would have none of that, and
would reinstate every deleted row. Nulls sort last, so rows another engine
appended without an assignment stay contiguous instead of appearing in every
row group.

Each group is bin-packed to the file-size target, so a merge holds one group in
memory rather than one table.

## Reading: The Probe

`cf_maybe_inject_probe` runs on the read path, alongside the hot-tier reroute
and the jsonb normalization, and it is what makes the layout worth maintaining.
`cf_maybe_inject_probe` rewrites a query only when all of the following hold:

- the query is a single-relation `SELECT` on a registered view with a clustered
  vector column.
- the query is ordered by exactly one cosine distance between that column and a
  constant, written as `<=>` or as a call to `list_cosine_distance`, with the
  column as either argument.
- the query has a `LIMIT`.
- the query is at the top level of the statement.

The hook sees one `Query`, so a top-k nested in a subquery or a CTE is not the
query it is looking at. Wrapping a search to aggregate over it therefore makes
it exact.

Grouping, aggregation, window functions and `DISTINCT` above that `ORDER BY`
are accepted, and they compute over the narrowed scan: the probe restricts
rows, and the statement's own semantics apply to what was read. The structural
declines are joins, CTEs, set operations, sublinks and row-marks. On PostgreSQL
18 a grouped query has an `RTE_GROUP` entry and its sort expression references
grouping expressions as Vars of that RTE; the hook counts that entry as no
second relation and resolves such Vars through `groupexprs` before matching the
shape.

Everything else is left byte-identical. That is an exact scan over both tiers,
which is correct, and it is what the product did before there was a layout.

The rewrite depends on three of those conditions. **The `LIMIT`** is part of
the shape because a probe trades recall for reads: that is the bargain a top-k
asks for, and not one to impose on a query that asked for every row in order.
**Cosine only**, because the centroids were trained under cosine, and ordering
by `<->` or `<#>` would route to clusters chosen under a different metric and
quietly return the wrong rows. **A constant query vector**, because pg_duckdb
converts neither a `vector` nor a `real[]` bound parameter, so a search that
could only be resolved from a parameter could not have run at all.

The rewrite resolves the nearest `nprobe` centroid ids
(`coldfront._vec_probe_ids`), turns them into a predicate
(`coldfront._vec_probe_qual`), and substitutes the view reference for the
view's own definition with its cold arm twice: once with that predicate, and
once with `IS NULL` on the cluster column for the rows with no assignment
(`coldfront._vec_probed_viewdef`):

```sql
… WHERE r['ts'] < <cutoff>
  AND (r['_cf_vec_list_embedding']::integer IN (3, 17))
UNION ALL
… WHERE r['ts'] < <cutoff>
  AND r['_cf_vec_list_embedding']::integer IS NULL
```

The substitution exists because the predicate has nowhere else to go: the
cluster column is in no branch of the view, so no query written against the
view can name it. Adding the test inside the definition puts it where the
column exists and leaves the user's column list alone. The substitution is a
range-table entry swapped for a subquery, not text surgery on the caller's SQL,
and PostgreSQL deparses the result.

The hot arm is untouched: hot rows have no assignment and every one of them is
returned.

**The unassigned arm is not optional, and it is a second arm rather than an
OR.** Rows another engine appended straight to Iceberg have no assignment, and
a bare `IN` drops them silently. The separate unassigned arm is also not
expensive: the reader prunes it on each file's null count, so unassigned rows
are read in proportion to their own size, and a table with none reads nothing
for it. The unassigned arm is not an `OR` on the first arm because DuckDB
pushes an `IN` into the scan and to the manifest bounds, but not an `OR` that
contains `IS NULL`.

**Declining is total and silent.** No centroid generation, an empty probe set,
a view with no cold arm: each keeps today's query. This is the one place in the
vector path that fails open, and deliberately so. A read that loses its
predicate is slower, never wrong. A write with no trained generation stores no
cluster, and every probe still reads it. A write that cannot reach the
centroids (pglocal not attached) fails instead, because a wrong cluster id
would make a row invisible to its own probe.

Two session settings, both `PGC_USERSET`, control the probe. The following
table shows their defaults and effects:

| GUC | Default | Effect |
|---|---|---|
| `coldfront.vector_probe` | `on` | `off` gives the exact scan that a recall measurement compares against. |
| `coldfront.vector_nprobe` | `0` | `0` uses the column's configured `nprobe`; a value at or above `nlist` is exhaustive. |

## Reporting

`CALL coldfront.vector_status([schema, table])` fills a session-lifetime
temporary table `cf_vector_status`, one row per registered clustered column. A
procedure writing a table rather than a function returning rows, for the reason
`vector_train` is one: pg_duckdb refuses to execute a DuckDB query inside a
function unless an unsafe setting is on, and a single `INSERT … SELECT` over a
DuckDB scan is planned as DuckDB's, which cannot write a PostgreSQL table.
Session lifetime rather than `ON COMMIT DROP` because a bare `CALL` is its own
transaction.

Nothing is staged on the way. DuckDB groups the table by cluster and aggregates
that grouping in one query, so a row of scalars crosses back per table, read
through `EXECUTE format(...)`: `duckdb.query` needs a constant at plan time,
not a literal in the source, and a dynamic table name built into the executed
text is one again. The work list is a pair of key arrays walked by index,
because a `FOR` over a query would hold a portal open for its body and
pg_duckdb refuses a DuckDB read while one is. `vector_train`'s DuckDB temporary
tables are its algorithm's own state, not a way to move a result across, and
nothing else here needs one.

The headline is `probe_fraction`: the share of the corpus a probe reads on
average, which is the cost the layout exists to lower. Everything beside
`probe_fraction` explains that number when it disappoints. `rows_unassigned` is
the part no probe can skip, since a row with no cluster is read by every one of
them. `clusters_below_row_group` counts occupied clusters holding fewer rows
than a row group, which is the measured floor on `nlist`. `advice` names the
first condition that holds, or is NULL.

File count, bytes and row-group structure are deliberately absent. Reaching
them means resolving a table's metadata location, which is a Lakekeeper HTTP
call, and the SQL layer makes no HTTP calls. The compactor reports files and
bytes on every pass, and file count is the wrong health signal regardless: a
merge bounds it without changing what a probe reads.

## Current Limitations

The following are properties of the code as it stands, not plans:

- `coldfront._tiered_insert_cold` writes unsorted: its cursor loop appends in
  cursor order and would need buffering to sort. The function is the fallback
  path for a tiered INSERT that omits an IDENTITY column.
- The replay drain (`coldfront.replay_archive_delta`) and the cross-tier move
  also write without ordering by cluster.

## Constraints That Are Correctness

These are not implementation quirks to work around; violating any of them
produces silently wrong results or a hard failure:

- The query vector is a literal, never a bound parameter. A parameter typed
  `vector` fails to convert, and so does one typed `real[]`, on a custom plan
  as much as a generic one. A scalar parameter elsewhere in the same query is
  fine.
- `'{…}'::real[]` does not work as the query vector. That form reaches DuckDB
  as a VARCHAR and fails to cast. The spelling is `ARRAY[…]::real[]`.
- `embedding::vector <=> …` fails with `Type with name vector does not exist!`,
  and materializing the read does not help. The unadorned form resolves, so
  nothing needs the cast.
- There is no PostgreSQL-side fallback. When a view embeds `iceberg_scan`,
  DuckDB owns the whole query and a function it lacks is a hard error rather
  than a slow path. Every expression the product wants users to write has to
  resolve in DuckDB.
- Assignment and search both use cosine distance everywhere. `list_distance` is
  Euclidean and would be silently wrong against cosine centroids.
- None of this plpgsql uses an `EXCEPTION` block, because pg_duckdb rejects
  subtransactions outright.
- `coldfront.local_pg_dsn` must be set for a clustered table, or the assignment
  lookup fails with `Catalog "pglocal" does not exist!`. The shipped container
  configuration sets it.

## Next Steps

To go further with ColdFront, consult the following documents:

- The [Embeddings](usage_vectors.md) guide covers declaring, training, and
  searching vector columns.
- The [Compaction](compaction.md) guide covers the maintenance that restores
  cluster order.
- The [Architecture](architecture.md) overview describes the mechanics both
  modes share.
