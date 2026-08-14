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

Choosing `nlist` is a floor rather than a formula: aim for at least one row
group's worth of rows per cluster, roughly 2048. Below that, extra clusters stop
reducing the data read. Above it there is a wide plateau.

### What a clustered search does

Once a column has a trained generation, a search that ends in `ORDER BY <column>
<=> <vector> LIMIT n` reads only the `nprobe` clusters nearest your query vector.
The query you write does not change. The result becomes approximate, in the same
way it does with any vector index: raise `nprobe` for recall, lower it for speed.

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
merges those into one ordered run, which is what keeps the number of places a
search looks from growing with the table. Nothing to configure: the table records
its own sort column at creation and the compactor reads it.

## Limits worth knowing

- A hot pgvector index is optional and capped by pgvector itself: HNSW refuses a
  `vector` column beyond 2,000 dimensions and a `halfvec` beyond 4,000, while
  storage tops out at 16,000 for both. A 3,072-dimension model gets no hot HNSW
  as a plain `vector`, and searches do not assume one exists.
- A table has one clustered vector column. A second vector column is stored and
  searched exactly, without clustering.
- `SELECT *` returns your own columns. The cluster assignment is internal and no
  branch of the view projects it, so no query can reference it.
- A hot row stores its embedding twice, once as `vector` and once in a generated
  `real[]` column that the cold reader can scan. Cold rows, which are the bulk of
  the data, store it once.
