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

-- One column behaves as it did before there were two.
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

-- Cleanup.
DELETE FROM coldfront.vector_centroids WHERE table_name = 'docs';
DELETE FROM coldfront.vector_config    WHERE table_name = 'docs';
