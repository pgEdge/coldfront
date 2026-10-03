-- The negative-inner-product operator on a read DuckDB runs. pg_duckdb hands an
-- operator to DuckDB by its symbol; DuckDB has <=> and <-> as aliases of its own
-- list_cosine_distance and list_distance and has no <#>, so the read rewrite
-- turns <#> into a call of the function behind it, which DuckDB has under the
-- same name. White-box: DuckDB executes the rewritten read against the heap
-- (duckdb.force_execution); no Iceberg I/O.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;
RESET client_min_messages;
SET TIME ZONE 'UTC';
-- White-box: checks the generated SQL, not Iceberg I/O.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SELECT coldfront.install_vector_ops();

CREATE TABLE public._items (id int, ts timestamptz, embedding real[]);
CREATE VIEW public.items AS SELECT * FROM public._items;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'items', 'public._items', 'ice.default.items', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'items', '2026-03-01'::timestamptz);
INSERT INTO public._items VALUES (1, '2026-01-01', ARRAY[1,2,3]),
                                 (2, '2026-01-02', ARRAY[-1,0,1]),
                                 (3, '2026-01-03', ARRAY[2,2,2]);

-- (A) Parity: DuckDB runs the read and ranks the rows by the negative inner
-- product exactly as pgvector does on the heap directly.
SET duckdb.force_execution = true;
SELECT id, round((embedding <#> ARRAY[1,2,3]::real[])::numeric, 2) AS neg_ip
  FROM public.items ORDER BY embedding <#> ARRAY[1,2,3]::real[], id;
RESET duckdb.force_execution;
SELECT id, round((embedding <#> ARRAY[1,2,3]::real[])::numeric, 2) AS neg_ip
  FROM public._items ORDER BY embedding <#> ARRAY[1,2,3]::real[], id;

-- (B) The two operators DuckDB has are left as operators and still run there.
SET duckdb.force_execution = true;
SELECT id, round((embedding <=> ARRAY[1,2,3]::real[])::numeric, 2) AS cosine,
       round((embedding <-> ARRAY[1,2,3]::real[])::numeric, 2) AS l2
  FROM public.items ORDER BY id;
RESET duckdb.force_execution;

-- (C) A read the hot heap can answer keeps the operator: it never reaches DuckDB.
EXPLAIN (COSTS OFF, VERBOSE)
SELECT embedding <#> ARRAY[1,2,3]::real[] FROM public.items WHERE ts >= '2026-04-01'::timestamptz;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.items;
DROP TABLE public._items;
