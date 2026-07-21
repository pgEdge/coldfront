-- Regression guard: a leading WITH (CTE) clause on INSERT into a tiered view.
-- emit_tiered_insert splits the row source across the PG hot half and the DuckDB
-- cold half; the CTE must reach both. The rewrite folds the WITH into the source
-- subquery so its CTEs scope to the derived table on each engine. White-box:
-- EXPLAIN VERBOSE shows the rewritten split; we do NOT execute.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.local_pg_dsn = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- INSERT ... SELECT FROM a CTE into the tiered view: the WITH must reach both the
-- hot (PG) and cold (DuckDB) halves, folded into the source derived table.
EXPLAIN (COSTS OFF, VERBOSE)
  WITH s AS (SELECT 7 AS id, '2026-05-01 00:00:00+00'::timestamptz AS ts, 'new' AS status)
  INSERT INTO public.events SELECT id, ts, status FROM s;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
