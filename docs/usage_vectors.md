# Working with embeddings

ColdFront stores embeddings in the cold tier as Iceberg `list<float>` and keeps
the pgvector interface you already write. A vector column works in both modes: a
tiered table whose recent rows stay in PostgreSQL, and a decoupled table that
lives entirely in Iceberg.

## Creating a table

Tiered, through the archiver's normal configuration:

```sql
CREATE TABLE chunks (
    id        bigserial,
    ts        timestamptz NOT NULL,
    body      text,
    embedding vector(1536)
) PARTITION BY RANGE (ts);
```

Decoupled, declared in one call:

```sql
SELECT coldfront.create_iceberg_table('public', 'chunks', '[
    {"name": "id",        "type": "bigint"},
    {"name": "ts",        "type": "timestamptz"},
    {"name": "embedding", "type": "vector(1536)"}
]'::jsonb);
```

pgvector is installed for you the first time a table declares a vector column.
You do not need it in a database that has none.

## Writing

Ordinary pgvector syntax, on either tier:

```sql
INSERT INTO chunks (ts, body, embedding)
VALUES (now(), 'hello', '[0.1, 0.2, 0.3, …]'::vector);
```

The value coerces to the column whether the row lands hot or cold, and an
`UPDATE` that sets a new embedding works the same way. Nothing about writes
changes when a table is clustered (below): assignments are maintained for you in
the same statement as the write.

## Reading and searching

The view exposes the column as `real[]`, which is the same type Iceberg stores.
Read it like any column:

```sql
SELECT id, body, embedding FROM chunks WHERE id = 42;
```

Search with the pgvector operator you would use anyway, and the query spans both
tiers in one statement:

```sql
SELECT id, body
  FROM chunks
 ORDER BY embedding <=> ARRAY[0.1, 0.2, 0.3, …]::real[]
 LIMIT 10;
```

All three pgvector operators are available: `<=>` cosine, `<->` Euclidean, `<#>`
negative inner product. Use `<=>` unless you have a reason not to; clustering is
built on cosine.

### Three rules for the query vector

These are requirements, not style. Each fails clearly if broken.

**Build the vector into the statement text.** A bound parameter does not work,
whether you type it `vector` or `real[]`. Other parameters in the same query are
fine, so only the vector itself has to be inlined:

```sql
-- works
… ORDER BY embedding <=> ARRAY[0.1, 0.2]::real[] LIMIT $1;
-- fails
… ORDER BY embedding <=> $1 LIMIT 10;
```

**Spell it `ARRAY[…]::real[]`.** The `'{0.1,0.2}'::real[]` form reaches the cold
tier as text and fails to cast.

**Do not cast the column.** `embedding <=> ARRAY[…]::real[]` resolves;
`embedding::vector <=> …` fails with `Type with name vector does not exist!`. Your
own `'[…]'::vector` literal on the right-hand side is fine.

## Clustering

Clustering is optional. Without it, a search is an exact scan of both tiers,
which is correct and needs no configuration.

To prepare a column for clustering, record its settings and train a centroid set:

```sql
INSERT INTO coldfront.vector_config
    (schema_name, table_name, column_name, nlist, nprobe)
VALUES ('public', 'chunks', 'embedding', 500, 20);

CALL coldfront.vector_train('public', 'chunks', 'embedding');
```

`CALL`, not `SELECT`: this is a procedure. It samples the cold tier, trains
`nlist` centroids, and stores them as a new generation. Every cold write after it
stamps the row's nearest cluster in the same statement, on every write path, and a
retrain does not require regenerating anything.

**Rows already in the cold tier are not clustered by training.** Training only
writes the centroids; the rows that predate it carry no cluster, and every search
reads all of them. If you are clustering a column that already has cold data, give
those rows a cluster and then compact:

```sql
CALL coldfront.vector_assign('public', 'chunks', 'embedding');
```

That rewrites the unassigned rows in one operation, serialised like any other cold
write. Compacting afterwards is what puts them in cluster order and clears the
delete markers the rewrite leaves; without it the rows are assigned but a search
still reads more of the table than it needs to. On a column clustered before any
data arrives there is nothing to assign and nothing to run.

Choosing `nlist` is a floor rather than a formula: aim for at least one row
group's worth of rows per cluster, roughly 2048. Below that, extra clusters stop
reducing the data read. Above it there is a wide plateau.

### Choosing `nprobe`

`nprobe` is how many clusters a search reads, and it is the dial between recall and
speed. Measured on a 10 million row corpus of 1024-dimension embeddings, `nlist`
1000, against the exact answer for 100 queries:

| `nprobe` | clusters read | recall | median query |
|---|---|---|---|
| 1 | 0.1% | 57% | 49 ms |
| 10 | 1% | 87% | 307 ms |
| 20 | 2% | 93% | 592 ms |
| 50 | 5% | 97% | 1.9 s |
| 100 | 10% | 98.5% | 5.1 s |

The same queries scanned exactly take 32 s each, so `nprobe` 20 is roughly 54 times
faster for 93% of the exact answer.

**Start at 2% of `nlist`.** Recall gets rapidly more expensive as you buy more of
it: on that corpus the first 23 points of recall cost 111 ms, and the last 1.8
points cost 3.2 s. The rate worsens from 5 ms per recall point to 1776, and the
knee is at 2% of the clusters. Above it you are paying several hundred milliseconds
per point.

That also fixes `nlist`, given the row-group floor above. **Aim for `nlist` ≈ rows
/ 10,000**, which leaves a few row groups per cluster: 1000 clusters for 10 million
rows. Dividing more finely than one row group per cluster costs latency without
buying anything, because a cluster read pulls a whole row group either way.

Two things the averages hide. **Recall is an average over queries, and the tail is
worse**: at `nprobe` 20 the worst of those 100 queries returned 4 of its true 10.
If every query matters, measure the worst case rather than the mean. **A more finely
divided index is not automatically better**: `nlist` 4999 returned more recall per
cluster read, but cost more time for it, and only came out ahead above about 98%
recall. Below that, fewer and larger clusters were faster at the same recall.

Your corpus is not this one. Take these as the shape of the curve, and measure your
own against a sample of queries you have exact answers for.

### What a clustered search does

Once a column has a trained generation, a search that ends in `ORDER BY <column>
<=> <vector> LIMIT n` reads only the `nprobe` clusters nearest your query vector.
The query you write does not change. The result becomes approximate, in the same
way it does with any vector index: raise `nprobe` for recall, lower it for speed.

A search that also groups, aggregates, windows or applies `DISTINCT` is narrowed
the same way: the probe restricts which rows are scanned, and everything in the
statement is computed over those rows. A grouped count, for example, counts probed
rows only. There is no approximate-inside, exact-outside form of one statement:
wrapping the search in a subquery makes the whole thing exact.

Anything that is not that shape stays an exact scan of both tiers, which is
correct. Two cases worth knowing: a search with no `LIMIT` is answered exactly,
because asking for every row in order is not a request to approximate; and so is
one wrapped in a subquery or CTE, because the clustering is applied to the
statement you write rather than to a nested part of it.

```sql
-- narrowed to the nearest clusters
SELECT id, body FROM chunks ORDER BY embedding <=> ARRAY[…]::real[] LIMIT 10;
-- exact: the search is not the statement
SELECT string_agg(body, ',') FROM (
  SELECT body FROM chunks ORDER BY embedding <=> ARRAY[…]::real[] LIMIT 10) t;
```

Rows written before the column was trained have no cluster, and they are returned
by every search regardless of which clusters it reads. So is every hot-tier row.
Nothing goes missing because it predates the clustering.

Two settings, per session:

```sql
-- read every cluster: exact, and the reference to compare recall against
SET coldfront.vector_nprobe = 500;    -- at or above nlist
-- or turn the narrowing off entirely
SET coldfront.vector_probe = off;
```

Leave `coldfront.vector_nprobe` at its default of `0` to use the `nprobe` you
recorded for the column.

### Checking whether the clustering is earning its keep

```sql
CALL coldfront.vector_status();
SELECT table_name, rows_total, rows_unassigned, clusters_occupied,
       probe_fraction, advice
  FROM cf_vector_status;
```

`probe_fraction` is the number to watch: the share of the cold rows a search reads
on average. Lower is faster. `advice` is filled in only when something specific is
holding that number up, and says which:

| What it says | What to do |
|---|---|
| no trained generation | `CALL coldfront.vector_train(...)` |
| over half the rows predate training | `CALL coldfront.vector_assign(...)`, then compact |
| over half the clusters hold less than one row group | retrain with a smaller `nlist` |
| the largest clusters hold over 4x the median | expect some queries to be slower than `probe_fraction` suggests; uneven clusters are mostly a property of the embeddings and a retrain rarely changes it |

Pass a schema and table to report on one column: `CALL
coldfront.vector_status('public', 'chunks')`. The results land in a temporary table
that lasts for your session, and each call replaces the last.

## More than one vector column

A table may carry as many vector columns as you like. Each gets its own
configuration, its own centroids and its own generation, and each is assigned on
every write path:

```sql
INSERT INTO coldfront.vector_config (schema_name, table_name, column_name, nlist, nprobe)
VALUES ('public', 'docs', 'body_embedding',  1000, 20),
       ('public', 'docs', 'title_embedding', 1000, 20);
CALL coldfront.vector_train('public', 'docs', 'body_embedding');
CALL coldfront.vector_train('public', 'docs', 'title_embedding');
```

**Only the first vector column's searches get the full speedup.** Not a policy
choice: a Parquet file has one physical row order, and the clustering works by
putting a cluster's rows next to each other so the reader can skip whole row groups.
The first column in table order gets that order. A second column's clusters are
scattered through it, so its row-group statistics cover most of the file and nothing
gets skipped.

What a later column still gets is the filter. Its predicate cuts the rows that have
to be *scored*, just not the rows that have to be *read*, and reading is about 95% of
the cost. Expect single-digit percent rather than the 54x the first column gets.

`vector_status` reports which is which:

```sql
SELECT table_name, column_name, prunes, probe_fraction FROM cf_vector_status;
```

`prunes` is true for the one column that owns the sort order. For the others,
`probe_fraction` describes the rows scored rather than the rows read.

If a second vector column needs to be fast, the honest answer is a second table
holding that column and a key, ordered by its own clustering. That is what a
secondary index is, and Iceberg gives us no way to have two orders in one file.

## What a clustered table needs from the deployment

The assignment lookup reads the centroid tables through a local connection, so
`coldfront.local_pg_dsn` must be set. The shipped container image sets it. On
bare metal, add it to `postgresql.conf`:

```
coldfront.local_pg_dsn = 'host=/var/run/postgresql dbname=<db> user=<role>'
```

Without it, a cold write to a clustered table fails with `Catalog 'pglocal' does
not exist` rather than writing an unassigned row.

## Compaction

Compaction stays mandatory on these tables, as it is on any ColdFront table:
every small write makes a file and query cost grows with file count. Run the
compactor as you already do.

On a clustered table it does more than consolidate. Each write leaves a file
sorted within itself, and a search has to look in every one of them; compaction
merges them on the sort column, one ordered run per size-bounded merge group, so
the number of places a search looks is set by data volume rather than by write
count. Nothing to configure: the table records its own sort column at creation
and the compactor reads it.

## Limits worth knowing

- A hot pgvector index is optional and capped by pgvector itself: HNSW refuses a
  `vector` column beyond 2,000 dimensions and a `halfvec` beyond 4,000, while
  storage tops out at 16,000 for both. A 3,072-dimension model gets no hot HNSW
  as a plain `vector`, and searches do not assume one exists.
- One vector column per table owns the physical sort order. Every vector column
  gets centroids, assignments and a probe filter, but only the sorted column's
  probes skip row groups; the others cut the rows scored, not the rows read.
- `SELECT *` returns your own columns. The cluster assignment is internal and no
  branch of the view projects it, so no query can reference it.
- A hot row stores its embedding twice, once as `vector` and once in a generated
  `real[]` column that the cold reader can scan. Cold rows, which are the bulk of
  the data, store it once.
