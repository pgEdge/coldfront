-- Regression guard: a leading WITH (CTE) clause on UPDATE/DELETE over a tiered
-- view. pg_get_querydef emits the WITH clause before the verb, so the rewrite
-- must find the result relation past the WITH preamble and carry the WITH through
-- verbatim with only the relation swapped (hot heap / Iceberg). White-box:
-- EXPLAIN VERBOSE shows the rewritten cold SQL; we do NOT execute.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- Cold UPDATE (ts < cutoff) with a CTE referenced in SET: the WITH must be
-- carried into the cold DML with the relation swapped to ice.default.events.
EXPLAIN (COSTS OFF, VERBOSE)
  WITH v AS (SELECT 'cold_upd'::text AS s)
  UPDATE public.events SET status = (SELECT s FROM v)
  WHERE ts < '2026-01-01 00:00:00+00';

-- Cold DELETE (ts < cutoff) with a CTE referenced in WHERE: WITH carried through.
EXPLAIN (COSTS OFF, VERBOSE)
  WITH lim AS (SELECT 99 AS n)
  DELETE FROM public.events
  WHERE ts < '2026-01-01 00:00:00+00' AND id < (SELECT n FROM lim);

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
