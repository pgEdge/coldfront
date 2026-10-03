-- A table may carry more than one vector column. Every one of them gets a cluster
-- column and an assignment on every write path; only the FIRST gets the file sort
-- order, because a Parquet file has one physical row order. So the first column's
-- probe prunes row groups and the others only cut the rows scored.
--
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;
RESET client_min_messages;
-- The probe scores against the centroids through the distance shim, so it has to be
-- installed before _vec_probe_ids can resolve anything.
SELECT coldfront.install_vector_ops();

-- One cluster column per vector column, named after it. The name is what the
-- read-path rewrite derives from the column a query orders by, so it is the contract
-- between the writer and the reader.
SELECT coldfront._vec_list_col('embedding') AS embedding_cluster,
       coldfront._vec_list_col('summary')   AS summary_cluster;

-- The sort key names one cluster column and the primary key. Passing a second vector
-- column would not help: within one value of the first, the second's values are
-- scattered, so its statistics stop bounding anything.
SELECT coldfront._vec_sort_key('embedding', ARRAY['id','ts']) AS sort_key;

-- The positional prefix carries every vector column, in the order the Iceberg schema
-- declares them, because a cold INSERT supplies values by position.
SELECT coldfront._vec_list_prefix('public', 'docs',
                                  ARRAY['embedding','summary'],
                                  ARRAY['s.embedding','s.summary']) AS prefix;

-- A single vector column yields a prefix of one expression.
SELECT coldfront._vec_list_prefix('public', 'docs',
                                  ARRAY['embedding'], ARRAY['s.embedding']) AS one_column;

-- No vector column, no prefix: a table without vectors pays nothing.
SELECT coldfront._vec_list_prefix('public', 'docs', ARRAY[]::text[], ARRAY[]::text[]) = ''
    AS no_vectors;

-- Mismatched arrays are a caller bug, and a silently short prefix would write a
-- positional INSERT that lands values in the wrong columns.
SELECT coldfront._vec_list_prefix('public', 'docs', ARRAY['a','b'], ARRAY['s.a']);

-- The probe predicate names the column being searched, so two searches on one table
-- filter on different cluster columns.
SELECT coldfront._vec_probe_qual('embedding', ARRAY[1,2]) AS embedding_qual,
       coldfront._vec_probe_qual('summary',   ARRAY[7])   AS summary_qual;

-- Each column carries its own configuration and its own generation.
INSERT INTO coldfront.vector_config (schema_name, table_name, column_name, nlist, nprobe, generation)
VALUES ('public', 'docs', 'embedding', 4, 2, 1),
       ('public', 'docs', 'summary',   2, 1, 1);
INSERT INTO coldfront.vector_centroids (schema_name, table_name, column_name, generation, centroid_id, centroid)
VALUES ('public','docs','embedding',1,0,ARRAY[1,0,0]::real[]),
       ('public','docs','embedding',1,1,ARRAY[0,1,0]::real[]),
       ('public','docs','summary',  1,0,ARRAY[1,1]::real[]),
       ('public','docs','summary',  1,1,ARRAY[-1,1]::real[]);
SELECT coldfront._vec_probe_ids('public','docs','embedding', ARRAY[0.9,0.1,0]::real[]) AS embedding_probe,
       coldfront._vec_probe_ids('public','docs','summary',   ARRAY[-1,1]::real[])      AS summary_probe;

-- A registered two-vector hot table: the lookups by ref below read its registry
-- row, and the per-row renderer at the end renders one of its rows.
CREATE TABLE public._docs (
    id        bigint GENERATED ALWAYS AS IDENTITY,
    ts        timestamptz,
    body      text,
    body_len  int GENERATED ALWAYS AS (length(body)) STORED,
    embedding vector(3),
    summary   vector(2)
);
ALTER TABLE public._docs
    ADD COLUMN "_cf_vec_embedding" real[] GENERATED ALWAYS AS ("embedding"::real[]) STORED,
    ADD COLUMN "_cf_vec_summary"   real[] GENERATED ALWAYS AS ("summary"::real[]) STORED;
CREATE VIEW public.docs AS SELECT id, ts, body, body_len,
       "_cf_vec_embedding"::real[] AS embedding, "_cf_vec_summary"::real[] AS summary
  FROM public._docs;
INSERT INTO coldfront.tiered_views (schema_name, relname, hot_table, iceberg_table, partition_col, vec_columns)
VALUES ('public', 'docs', 'public._docs', 'ice.default.docs', 'ts', ARRAY['embedding','summary']);

-- The C rewrite asks these two for a targeted decoupled INSERT; the same registry
-- row answers both, in schema order.
SELECT coldfront._vec_list_cols_for_ref('ice.default.docs') AS cluster_cols;
SELECT coldfront._vec_list_prefix_for_ref('ice.default.docs', 's.') IS NOT NULL AS prefix_resolves;

-- The UPDATE re-stamp offers every SET column; only a clustered vector column
-- answers with an item, which is what keeps the column list out of C entirely.
SELECT coldfront._vec_list_set_item('ice.default.docs', 'embedding', 'NEW_EXPR') IS NOT NULL AS vector_answers,
       coldfront._vec_list_set_item('ice.default.docs', 'body', 'NEW_EXPR') IS NULL      AS non_vector_declines;

-- One formula for the nearest centroid whatever set it is scored against: the live
-- generation over pglocal for a cold write, the session's freshly trained set for
-- the assignment at the end of training.
SELECT coldfront._vec_nearest_expr('temp.main.cf_gen c', 'embedding');

-- The one per-row renderer, shared by the cold sink and the cross-tier move, on
-- a row of this table. Both cluster expressions lead, each derived from its own
-- column's value, in column order; a column absent from the payload (the
-- identity column here) keeps its positional slot as NULL.
SELECT coldfront._cold_row_literal(
    '{"ts": "2026-06-01 00:00:00+00", "body": "b", "body_len": 1, "embedding": "[0.9,0.1,0]", "summary": "[-1,1]"}'::jsonb,
    ARRAY['id', 'ts', 'body', 'body_len', 'embedding', 'summary'],
    ARRAY['bigint', 'timestamp with time zone', 'text', 'integer', 'vector(3)', 'vector(2)'],
    'public', 'docs') AS two_vector_row;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a registered
-- tiered table/view.
DELETE FROM coldfront.tiered_views WHERE relname = 'docs';
DELETE FROM coldfront.vector_centroids WHERE table_name = 'docs';
DELETE FROM coldfront.vector_config    WHERE table_name = 'docs';
DROP VIEW public.docs;
DROP TABLE public._docs;
