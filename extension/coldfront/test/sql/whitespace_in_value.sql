-- A tab or a newline inside a string literal survives every DML rewrite. The
-- deparsed statement is put on one line for the result-relation search, and
-- only the newlines outside quotes become spaces: a literal keeps its own.
-- White-box: the hot paths execute, and the rewritten SQL of the others is read
-- from EXPLAIN VERBOSE with the two characters shown as <tab> and <nl>, so the
-- expectation reads as text and holds on every PostgreSQL major.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
INSERT INTO public._events VALUES (1, '2026-04-01 12:00:00+00', 'hot');
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- The literal, once per place the plan carries it. EXPLAIN splits its text at
-- every newline, a literal's included, so the rows are joined back first.
CREATE FUNCTION pg_temp.literal_in_plan(stmt text) RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE plan text := '';
        line text;
BEGIN
  FOR line IN EXECUTE 'EXPLAIN (COSTS OFF, VERBOSE) ' || stmt LOOP
    plan := plan || line || E'\n';
  END LOOP;
  RETURN QUERY SELECT m[1]
    FROM regexp_matches(replace(replace(plan, E'\t', '<tab>'), E'\n', '<nl>'),
                        '(tab.*?here nl.*?here)', 'g') AS m;
END $$;

-- Hot-only UPDATE: executed, the hot table holds the literal.
UPDATE public.events SET status = E'tab\there nl\nhere' WHERE ts >= '2026-04-01';
SELECT id, replace(replace(status, E'\t', '<tab>'), E'\n', '<nl>') AS status
  FROM public._events;

-- Cold UPDATE: the DuckDB statement keeps it.
SELECT * FROM pg_temp.literal_in_plan($$
  UPDATE public.events SET status = E'tab\there nl\nhere' WHERE ts < '2026-01-01' $$);

-- Dual-tier UPDATE: the cold half and the hot half keep it.
SELECT * FROM pg_temp.literal_in_plan($$
  UPDATE public.events SET status = E'tab\there nl\nhere' WHERE id = 1 $$);

-- Tiered INSERT: the streamed source and the hot INSERT keep it.
SELECT * FROM pg_temp.literal_in_plan($$
  INSERT INTO public.events (ts, status) VALUES ('2026-01-01', E'tab\there nl\nhere') $$);

-- A write nested in a WITH entry: the hot one executes, the cold one is read
-- from its plan.
WITH u AS (UPDATE public.events SET status = E'tab\there nl\nhere'
           WHERE ts >= '2026-04-01' RETURNING status)
SELECT replace(replace(status, E'\t', '<tab>'), E'\n', '<nl>') AS status FROM u;
SELECT * FROM pg_temp.literal_in_plan($$
  WITH d AS (DELETE FROM public.events
             WHERE ts < '2026-01-01' AND status = E'tab\there nl\nhere')
  SELECT 1 $$);

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
