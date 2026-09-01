-- jsonb_build_object / jsonb_agg (and their json_ twins) on a tiered read. The
-- read runs entirely in DuckDB, which has neither; a name swap cannot reach a
-- DuckDB counterpart (json_object is grammar-reserved in PostgreSQL, and DuckDB's
-- json_group_array is a macro that refuses ORDER BY), so the builders are rewritten
-- into the concat / to_json / array_agg form both engines evaluate identically.
-- White-box: the assertions are on the rewritten SQL, on PostgreSQL producing the
-- same JSON as jsonb's own rendering, and on DuckDB accepting the rewritten read
-- against the heap (duckdb.force_execution); no Iceberg I/O.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;
SET TIME ZONE 'UTC';
-- White-box: checks the generated SQL, not Iceberg I/O.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, name text, setting text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);
-- A NULL value and a value with a quote: both must survive as JSON.
INSERT INTO public._events VALUES (1, '2026-01-01 00:05+00', 'work_mem', '4MB'),
                                  (2, '2026-01-01 01:07+00', 'max_conn', NULL),
                                  (3, '2026-01-01 02:09+00', 'app_name', 'o''neil');

-- (A) The rewritten shapes: an object, an ordered aggregate of objects nested in
-- an object, a FILTERed aggregate, and a json_ (not jsonb_) aggregate of scalars.
EXPLAIN (COSTS OFF, VERBOSE)
SELECT jsonb_build_object('name', name, 'value', setting)::text AS details FROM public.events;
EXPLAIN (COSTS OFF, VERBOSE)
SELECT jsonb_build_object('count', count(*),
                          'changes', jsonb_agg(jsonb_build_object('name', name, 'value', setting) ORDER BY name))::text
FROM public.events;
EXPLAIN (COSTS OFF, VERBOSE)
SELECT jsonb_agg(name) FILTER (WHERE setting IS NOT NULL) FROM public.events;
EXPLAIN (COSTS OFF, VERBOSE)
SELECT json_agg(name ORDER BY name) FROM public.events;

-- (B) JSON parity with jsonb's own rendering. The rewritten read, run by
-- PostgreSQL here, is captured and compared as jsonb against the builders on the
-- heap (no tiered view in that statement, so it is left untouched).
SELECT jsonb_build_object('count', count(*),
                          'changes', jsonb_agg(jsonb_build_object('name', name, 'value', setting) ORDER BY name))::text AS details
FROM public.events \gset
SELECT :'details' AS rewritten_read;
SELECT :'details'::jsonb = jsonb_build_object('count', count(*),
                          'changes', jsonb_agg(jsonb_build_object('name', name, 'value', setting) ORDER BY name)) AS same_json
FROM public._events;
SELECT jsonb_agg(name) FILTER (WHERE setting IS NOT NULL) AS filtered FROM public.events \gset
SELECT :'filtered'::jsonb = (SELECT jsonb_agg(name) FILTER (WHERE setting IS NOT NULL) FROM public._events) AS same_json;
SELECT json_agg(name ORDER BY name) AS scalars FROM public.events \gset
SELECT :'scalars'::jsonb = (SELECT json_agg(name ORDER BY name)::jsonb FROM public._events) AS same_json;

-- The result is still JSON to the rest of the query: ->> works on it.
SELECT jsonb_build_object('name', name, 'value', setting) ->> 'value' AS value FROM public.events ORDER BY id;

-- A view reference below the top level is rewritten too: the whole statement runs
-- in DuckDB, whichever branch names the view.
WITH changes AS (SELECT name, setting FROM public.events)
SELECT jsonb_build_object('name', name)::text FROM changes ORDER BY 1;

-- (C) Parity against the live DuckDB: it executes the rewritten read (force_execution
-- scans the heap the way a cold read scans Parquet) and returns the same JSON.
SET duckdb.force_execution = true;
SELECT jsonb_build_object('count', count(*),
                          'changes', jsonb_agg(jsonb_build_object('name', name, 'value', setting) ORDER BY name))::text AS details
FROM public.events;
SELECT json_agg(name ORDER BY name)::text AS scalars FROM public.events;
RESET duckdb.force_execution;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
