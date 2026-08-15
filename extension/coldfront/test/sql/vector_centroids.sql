-- The routing state Phase 2 assigns and probes against: one centroid set per
-- vector column, plus the per-table settings that describe it.
--
-- It lives in PostgreSQL because three consumers need it there: the read-path
-- rewrite scores a query against it in the same backend, the write paths resolve
-- an assignment inside the statement doing the write, and an adaptive addition is
-- inserted in the same transaction as the row that triggered it.
--
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
-- Deliberately no pgvector here: these tables ship with the extension, so they
-- must exist on a database that has no vectors and may never have any.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

-- Name-keyed, like partition_config: a mesh replicates it by value, so every node
-- assigns identical cluster ids without sharing OIDs.
SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull
  FROM pg_attribute a
 WHERE a.attrelid = 'coldfront.vector_centroids'::regclass
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY a.attnum;

-- PG18 catalogues a table's NOT NULL constraints in pg_constraint; PG16 and PG17
-- keep them only in pg_attribute.attnotnull, which the query above asserts.
SELECT conname, pg_get_constraintdef(oid) AS def
  FROM pg_constraint
 WHERE conrelid = 'coldfront.vector_centroids'::regclass
   AND contype <> 'n'
 ORDER BY conname;

SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type
  FROM pg_attribute a
 WHERE a.attrelid = 'coldfront.vector_config'::regclass
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY a.attnum;

-- A restored node must re-attach to the same cold tier without retraining, and a
-- generation is meaningless without the centroids that defined it.
SELECT c.relname
  FROM pg_class c
 WHERE c.oid = ANY (SELECT unnest(extconfig) FROM pg_extension WHERE extname = 'coldfront')
   AND c.relname IN ('vector_centroids', 'vector_config')
 ORDER BY c.relname;

-- A generation is immutable: rows are inserted, never updated in place, so a
-- query that resolved a generation keeps meaning the same thing.
INSERT INTO coldfront.vector_config (schema_name, table_name, column_name, nlist, nprobe)
VALUES ('public', 'chunks', 'embedding', 500, 20);
INSERT INTO coldfront.vector_centroids (schema_name, table_name, column_name, generation, centroid_id, centroid)
VALUES ('public', 'chunks', 'embedding', 1, 0, ARRAY[1,0,0]::real[]),
       ('public', 'chunks', 'embedding', 1, 1, ARRAY[0,1,0]::real[]);
SELECT count(*) AS centroids FROM coldfront.vector_centroids WHERE table_name = 'chunks';

-- The same centroid id twice in one generation would make an assignment ambiguous.
INSERT INTO coldfront.vector_centroids (schema_name, table_name, column_name, generation, centroid_id, centroid)
VALUES ('public', 'chunks', 'embedding', 1, 0, ARRAY[9,9,9]::real[]);

-- Cleanup.
DELETE FROM coldfront.vector_centroids WHERE table_name = 'chunks';
DELETE FROM coldfront.vector_config WHERE table_name = 'chunks';
