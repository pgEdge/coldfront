# Working with Embeddings

ColdFront stores embeddings in the cold tier as Iceberg `list<float>` and keeps
the pgvector interface you already write. A vector column works in both modes:
a tiered table whose recent rows stay in PostgreSQL, and a decoupled table that
lives entirely in Iceberg.

## Creating a Table

Create a tiered table through the archiver's normal configuration:

```sql
CREATE TABLE chunks (
    id        bigserial,
    ts        timestamptz NOT NULL,
    body      text,
    embedding vector(1536),
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
```

Declare a decoupled table in one call:

```sql
SELECT coldfront.create_iceberg_table('public', 'chunks', '[
    {"name": "id",        "type": "bigint"},
    {"name": "ts",        "type": "timestamptz"},
    {"name": "embedding", "type": "vector(1536)"}
]'::jsonb);
```

ColdFront installs pgvector the first time a table declares a vector column.
You do not need pgvector in a database that has none.

A table that already exists in the catalog can be adopted instead, through
`coldfront.adopt_iceberg_table()` (see
[Adopting a Table That Already Exists in the Catalog](usage_decoupled.md#adopting-a-table-that-already-exists-in-the-catalog)).
Adoption registers a clustered vector column for each Iceberg column named
`_cf_vec_list_<column>`, which is where ColdFront keeps each row's cluster. No
`coldfront.vector_config` row and no centroids come back with an adopted
column, so its searches stay exact until you record its settings and train it
(see [Clustering](#clustering)).

Releasing or dropping a table deletes its `vector_config` and
`vector_centroids` rows. A table registered again under the same name, such as
one released and adopted again, needs a new configuration row and a first
training from fresh centroids.

## Writing

Writes use ordinary pgvector syntax, on either tier:

```sql
INSERT INTO chunks (ts, body, embedding)
VALUES (now(), 'hello', '[0.1, 0.2, 0.3, …]'::vector);
```

The value coerces to the column whether the row lands hot or cold, and an
`UPDATE` that sets a new embedding works the same way. Nothing about writes
changes when a table is clustered (below): ColdFront maintains the assignments
in the same statement as the write.

## Reading and Searching

The view exposes the column as `real[]`, which is the same type Iceberg stores.
Read the column like any other:

```sql
SELECT id, body, embedding FROM chunks WHERE id = 42;
```

Search with the pgvector operator you would use anyway, and the query spans
both tiers in one statement:

```sql
SELECT id, body
  FROM chunks
 ORDER BY embedding <=> ARRAY[0.1, 0.2, 0.3, …]::real[]
 LIMIT 10;
```

`<=>` (cosine), `<->` (Euclidean) and `<#>` (negative inner product) work on
both tiers. Use `<=>` unless you have a reason not to. The clustering uses
cosine distance.

### Three Rules for the Query Vector

These are requirements, not style. Each fails clearly if broken.

**Build the vector into the statement text.** A bound parameter does not work,
whether you type it `vector` or `real[]`. Other parameters in the same query
are fine, so only the vector itself has to be inlined:

```sql
-- works
… ORDER BY embedding <=> ARRAY[0.1, 0.2]::real[] LIMIT $1;
-- fails
… ORDER BY embedding <=> $1 LIMIT 10;
```

**Spell the query vector `ARRAY[…]::real[]`.** The `'{0.1,0.2}'::real[]` form
reaches the cold tier as text and fails to cast.

**Do not cast the column.** `embedding <=> ARRAY[…]::real[]` resolves;
`embedding::vector <=> …` fails with `Type with name vector does not exist!`.
Your own `'[…]'::vector` literal on the right-hand side is fine.

## Clustering

Clustering is optional. Without clustering, a search is an exact scan of both
tiers, which is correct and needs no configuration.

To prepare a column for clustering, record its settings and train a centroid
set:

```sql
INSERT INTO coldfront.vector_config
    (schema_name, table_name, column_name, nlist, nprobe)
VALUES ('public', 'chunks', 'embedding', 500, 20);

CALL coldfront.vector_train('public', 'chunks', 'embedding');
```

The `vector_config` row has no default for `nlist` or `nprobe`, so the `INSERT`
names both. Check constraints require `nlist` to be at least 1 and `nprobe` to
lie between 1 and `nlist`. `schema_name` defaults to `'public'`, and
`generation` and `addition_cap` default to `0`. `vector_train` maintains
`generation`, and `addition_cap` is reserved. When training produces fewer
centroids than `nprobe`, it lowers `nprobe` to the trained count.

Run `vector_train` with `CALL`, not `SELECT`: this is a procedure. The
procedure samples the cold tier, trains up to `nlist` centroids (recording the
count actually trained as the column's `nlist`), stores them as a new
generation, and assigns every cold row to its nearest centroid, rewriting the
rows whose cluster changed. After `vector_train` runs, every cold write assigns
the row to a cluster in the same statement, on every write path.

Compact afterwards. The assignment leaves a delete marker per rewritten row and
those rows in rewrite order; compaction is what puts them in cluster order and
clears the markers. Without compaction the rows are assigned but a search still
reads more of the table than it needs to.

The following table describes the parameters of `vector_train`:

| Parameter | Default | Description |
|---|---|---|
| `p_schema` | required | The parameter names the schema that holds the registered table. |
| `p_table` | required | The parameter names the registered table. |
| `p_column` | required | The parameter names the vector column to train. |
| `p_nlist` | the configured `nlist` | The parameter sets the number of centroids to train. |
| `p_sample` | `20000` | The parameter sets how many cold rows with a non-null vector training samples. |
| `p_iterations` | `8` | The parameter sets how many k-means iterations run over the sample. |

`vector_train` stops with an error in each of the following cases:

- The server is a read-only standby, so training must run on the primary.
- The table is not registered with ColdFront, and the error reports that it
  `is not a registered tiered table`.
- The table was adopted read-only. Training rewrites the cold rows, so release
  the table and adopt it again with `p_writable => true`.
- The column has no `coldfront.vector_config` row. Passing `p_nlist` does not
  replace that row, because it holds the generation pointer training writes.
- The cold tier holds no row with a non-null vector, and the error reports that
  the column `has no cold rows to train on`. Training samples only the cold
  tier, so the hot rows of a tiered table do not count.

### Retraining

Call `vector_train` again when the data has grown or you want a different
`nlist`. Without `p_nlist`, the new centroids start from the current ones and
keep their identities, so only the rows whose nearest centroid changed are
rewritten; with a new `nlist`, nearly every row is. Either way the centroids
and the assignments change together, so a search is never wrong in between; it
is only slower until the next compaction.

### Time Partitioning

A tiered vector table is partitioned by time, because its hot table is; a
decoupled one only if it was created with time partitioning
(`p_partition_cols`). On such a table a search with a time filter skips the
months outside it, and a search over all of history reads one row group of each
probed cluster per partition (per month or per day, and per list value on a
two-level table) rather than one, roughly the number of partitions more data. A
decoupled vector table created without time partitioning is unaffected.

### Choosing `nlist`

Choosing `nlist` is a floor rather than a formula: aim for at least one row
group's worth of rows per cluster, roughly 2048. Below that, extra clusters
stop reducing the data read. Above that floor there is a wide plateau.

### Choosing `nprobe`

`nprobe` is how many clusters a search reads, and it is the dial between recall
and speed. The following table shows recall and query time at each `nprobe`,
measured on a 10 million row corpus of 1024-dimension embeddings, `nlist` 1000,
against the exact answer for 100 queries:

| `nprobe` | clusters read | recall | median query |
|---|---|---|---|
| 1 | 0.1% | 56.9% | 49 ms |
| 10 | 1% | 86.8% | 307 ms |
| 20 | 2% | 93.2% | 592 ms |
| 50 | 5% | 96.7% | 1.9 s |
| 100 | 10% | 98.5% | 5.1 s |

The same queries scanned exactly take 32 s each, so `nprobe` 20 is roughly 54
times faster for 93% of the exact answer.

**Start at 2% of `nlist`.** Recall gets rapidly more expensive as you buy more
of it: on that corpus the first 23 points of recall cost 111 ms, and the last
1.8 points cost 3.2 s. The rate worsens from 5 ms per recall point to 1776, and
the knee is at 2% of the clusters. Above the knee you are paying several
hundred milliseconds per point.

That also fixes `nlist`, given the row-group floor above. **Aim for `nlist` ≈
rows / 10,000**, which leaves a few row groups per cluster: 1000 clusters for
10 million rows. Dividing more finely than one row group per cluster costs
latency without buying anything, because a cluster read pulls a whole row group
either way.

The averages hide two things. **Recall is an average over queries, and the tail
is worse**: at `nprobe` 20 the worst of those 100 queries returned 4 of its
true 10. If every query matters, measure the worst case rather than the mean.
**A more finely divided index is not automatically better**: `nlist` 4999
returned more recall per cluster read, but cost more time for it, and only came
out ahead above about 98% recall. Below that, fewer and larger clusters were
faster at the same recall.

Your corpus is not this one. Take these as the shape of the curve, and measure
your own against a sample of queries you have exact answers for.

### What a Clustered Search Does

Once a column has a trained generation, a search that ends in
`ORDER BY <column> <=> <vector> LIMIT n` reads only the `nprobe` clusters
nearest your query vector. The function-call form,
`ORDER BY list_cosine_distance(<column>, <vector>) LIMIT n`, is the same search
and is narrowed the same way. The query you write does not change. The result
becomes approximate, in the same way it does with any vector index: raise
`nprobe` for recall, lower it for speed.

A search that also groups, aggregates, windows or applies `DISTINCT` is
narrowed the same way: the probe restricts which rows are scanned, and
everything in the statement is computed over those rows. A grouped count, for
example, counts probed rows only. There is no approximate-inside, exact-outside
form of one statement: wrapping the search in a subquery makes the whole thing
exact.

Anything that is not that shape stays an exact scan of both tiers, which is
correct. Two cases are worth knowing: a search with no `LIMIT` is answered
exactly, because asking for every row in order is not a request to approximate;
and so is one wrapped in a subquery or CTE, because the clustering is applied
to the statement you write rather than to a nested part of it. The following
two statements show the difference:

```sql
-- narrowed to the nearest clusters
SELECT id, body FROM chunks ORDER BY embedding <=> ARRAY[…]::real[] LIMIT 10;
-- exact: the search is not the statement
SELECT string_agg(body, ',') FROM (
  SELECT body FROM chunks ORDER BY embedding <=> ARRAY[…]::real[] LIMIT 10) t;
```

Rows with no cluster, such as rows another engine appended straight to Iceberg,
are returned by every search regardless of which clusters it reads. So is every
hot-tier row. Training assigns every cold row written before it, and an
unassigned row never goes missing on that account.

Two settings change this behavior per session:

```sql
-- read every cluster: exact, and the reference to compare recall against
SET coldfront.vector_nprobe = 500;    -- at or above nlist
-- or turn the narrowing off entirely
SET coldfront.vector_probe = off;
```

Leave `coldfront.vector_nprobe` at its default of `0` to use the `nprobe` you
recorded for the column.

### Checking Whether the Clustering Is Worth Having

Call `vector_status` and query its results table:

```sql
CALL coldfront.vector_status();
SELECT table_name, rows_total, rows_unassigned, clusters_occupied,
       probe_fraction, advice
  FROM cf_vector_status;
```

`probe_fraction` is the number to watch: the share of the cold rows a search
reads on average. Lower is faster. `vector_status` fills in `advice` only when
a specific cause keeps that number high. The following table shows what each
message means and what to do:

| What it says | What to do |
|---|---|
| no trained generation | Run `CALL coldfront.vector_train(...)`. |
| over half the rows have no assignment | Rows another engine appended straight to Iceberg have no assignment. Run `CALL coldfront.vector_train(...)` to assign them, then compact. |
| over half the occupied clusters hold less than one row group | Retrain with a smaller `nlist`. |
| the largest clusters hold over 4x the median | Expect some queries to be slower than `probe_fraction` suggests. Uneven clusters are mostly a property of the embeddings, and a retrain rarely changes that. |

Pass a schema and table to report on one table:
`CALL coldfront.vector_status('public', 'chunks')`. Pass the schema alone,
`CALL coldfront.vector_status('public')`, to report on every clustered table in
that schema. The results land in a temporary table that lasts for your session,
and each call replaces the last. When no table with a clustered vector column
matches the arguments, `cf_vector_status` is empty and the call raises the
notice `coldfront: no registered table has a clustered vector column`.

The following table describes the columns of `cf_vector_status`, one row per
clustered vector column:

| Column | Description |
|---|---|
| `schema_name` | The column holds the schema of the registered table. |
| `table_name` | The column holds the name of the registered table. |
| `column_name` | The column holds the name of the clustered vector column. |
| `prunes` | The value is true for the vector column that owns the physical sort order (see [More than One Vector Column](#more-than-one-vector-column)). |
| `generation` | The column holds the live centroid generation, or NULL when nothing has been trained. |
| `nlist` | The column holds the configured `nlist`, or NULL when the column has no `vector_config` row. |
| `nprobe` | The column holds the configured `nprobe`, or NULL when the column has no `vector_config` row. |
| `clusters_trained` | The column counts the centroids in the live generation. |
| `clusters_occupied` | The column counts the clusters that hold at least one cold row. |
| `additions` | The column counts the centroids in the live generation that have a `parent_id`; ColdFront sets none, so the value is 0. |
| `addition_cap` | The column holds the configured `addition_cap`, which is reserved. |
| `rows_total` | The column counts the rows in the cold tier. |
| `rows_unassigned` | The column counts the cold rows with no cluster, which every search reads. |
| `rows_per_cluster_min` | The column holds the fewest cold rows in any occupied cluster. |
| `rows_per_cluster_max` | The column holds the most cold rows in any occupied cluster. |
| `rows_per_cluster_p50` | The column holds the median number of cold rows per occupied cluster. |
| `rows_per_cluster_p99` | The column holds the 99th percentile of cold rows per occupied cluster. |
| `clusters_below_row_group` | The column counts the occupied clusters that hold fewer than 2,048 rows, which is one row group. |
| `probe_fraction` | The column holds the average share of the cold rows a search reads, including every unassigned row. |
| `advice` | The column names the first condition holding `probe_fraction` up, or is NULL when none does. |

## More than One Vector Column

A table may have as many vector columns as you like. Each gets its own
configuration, its own centroids and its own generation, and each is assigned
on every write path:

```sql
INSERT INTO coldfront.vector_config (schema_name, table_name, column_name, nlist, nprobe)
VALUES ('public', 'docs', 'body_embedding',  1000, 20),
       ('public', 'docs', 'title_embedding', 1000, 20);
CALL coldfront.vector_train('public', 'docs', 'body_embedding');
CALL coldfront.vector_train('public', 'docs', 'title_embedding');
```

**Only the first vector column's searches get the full speedup.** This is not a
policy choice: a Parquet file has one physical row order, and the clustering
works by putting a cluster's rows next to each other so the reader can skip
whole row groups. The first column in table order gets that order. A second
column's clusters are scattered through it, so its row-group statistics cover
most of the file and the reader skips no row groups.

What a later column still gets is the filter. Its predicate cuts the rows that
have to be *scored*, but not the rows that have to be *read*, and reading is
about 95% of the cost. Expect single-digit percent rather than the 54x the
first column gets.

`vector_status` reports which is which:

```sql
SELECT table_name, column_name, prunes, probe_fraction FROM cf_vector_status;
```

`prunes` is true for the one column that owns the sort order. For the others,
`probe_fraction` describes the rows scored rather than the rows read.

If a second vector column needs to be fast, the honest answer is a second table
holding that column and a key, ordered by its own clustering. That is what a
secondary index is, and Iceberg offers no way to have two orders in one file.

## What a Clustered Table Needs from the Deployment

The assignment lookup reads the centroid tables through a local connection, so
`coldfront.local_pg_dsn` must be set. The shipped container image sets that
parameter. On bare metal, add the setting to `postgresql.conf`:

```ini

coldfront.local_pg_dsn = 'host=/var/run/postgresql dbname=<db> user=<role>'
```

Without that setting, a cold write to a clustered table fails with
`Catalog "pglocal" does not exist!` rather than writing an unassigned row. A
retrain at the same `nlist` reads the live centroids through the same
connection, so it fails with the same error.

## Compaction

Compaction stays mandatory on these tables, as it is on any ColdFront table:
every small write makes a file and query cost grows with file count. Run the
compactor as you already do.

On a clustered table, compaction does more than consolidate. Each batch write
leaves a file sorted within itself, and a search has to look in every one of
them; compaction merges them on the sort column, one ordered run per
size-bounded merge group, so the number of places a search looks is set by data
volume rather than by write count. There is nothing to configure: the table
records its own sort column at creation and the compactor reads it.

## Limits Worth Knowing

The following limits apply to vector columns:

- A hot pgvector index is optional and capped by pgvector itself: HNSW refuses
  a `vector` column beyond 2,000 dimensions and a `halfvec` beyond 4,000, while
  storage tops out at 16,000 for both. A 3,072-dimension model gets no hot HNSW
  as a plain `vector`, and searches do not assume one exists.
- One vector column per table owns the physical sort order. Every vector column
  gets centroids, assignments and a probe filter, but only the sorted column's
  probes skip row groups; the others cut the rows scored, not the rows read.
- `SELECT *` returns your own columns. The cluster assignment is internal and
  no branch of the view projects it, so no query can reference it.
- A hot row stores its embedding twice, once as `vector` and once in a
  generated `real[]` column that the cold reader can scan. Cold rows, which are
  the bulk of the data, store it once.

## Next Steps

To go further with ColdFront, consult the following documents:

- The [Vector Storage](architecture_vectors.md) deep dive describes the routing
  state, cluster assignment, and probe rewrite behind this guide.
- The [Compaction](compaction.md) guide covers the maintenance that keeps
  clustered tables in cluster order.
- The [Using ColdFront](using_coldfront/index.md) guide covers the table setup both modes
  share.
