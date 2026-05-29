-- Tier-deterministic UPDATE whose predicate proves the hot tier (ts >= cutoff)
-- must be rewritten to plain PG DML on _events. EXPLAIN verifies the plan
-- shape; the execution then verifies the actual mutation.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
-- ensure_attached() is a no-op when these GUCs are empty, so the cold path
-- doesn't try to reach a live Lakekeeper during tests.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
INSERT INTO public._events VALUES
  (1, '2026-04-01 12:00:00+00', 'hot_orig'),
  (2, '2026-04-15 12:00:00+00', 'hot_orig');
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public.events'::regclass, 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Hot-only (ts >= cutoff): plan must target _events, not duckdb.raw_query
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'hot_upd' WHERE ts = '2026-04-01 12:00:00+00';

UPDATE public.events SET status = 'hot_upd' WHERE ts = '2026-04-01 12:00:00+00';
SELECT id, status FROM public._events ORDER BY id;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
