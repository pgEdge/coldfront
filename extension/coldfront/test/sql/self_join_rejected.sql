-- The dual-tier rewrite substitutes only the LEADING result-relation reference
-- to a tiered view. A second reference to the same view — a self-join
-- (UPDATE … FROM v), DELETE … USING v, or a sub-select (… WHERE id IN
-- (SELECT … FROM v)) — would be copied through verbatim and then fail
-- confusingly (PG cannot scan the iceberg_scan view; DuckDB does not know it).
-- The hook must reject these cleanly at parse-analyze, before planning. A
-- structural multi-reference rewrite is out of scope. White-box: no Iceberg
-- attached; single-reference DML is unaffected (see update_{hot,cold}_via_view).

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Self-join via FROM — rejected.
UPDATE public.events SET status = 'x' FROM public.events e2 WHERE public.events.id = e2.id;

-- DELETE … USING the same view — rejected.
DELETE FROM public.events USING public.events e2 WHERE public.events.id = e2.id;

-- Sub-select over the same view (the common, dangerous idiom) — rejected.
UPDATE public.events SET status = 'x' WHERE id IN (SELECT id FROM public.events WHERE status = 'y');

-- A single reference is still fine: the hot-tier rewrite happens as usual.
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x' WHERE ts = '2026-04-01 00:00:00+00';

DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
