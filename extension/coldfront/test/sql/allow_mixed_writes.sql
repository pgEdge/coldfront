-- Permissive mode (coldfront.allow_mixed_writes = on, default): an ambiguous
-- predicate triggers a dual-tier CTE that writes to both tiers in the same
-- statement. Strict mode (off) still rejects such predicates with ERROR.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public.events'::regclass, 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Default GUC value is permissive (on)
SHOW coldfront.allow_mixed_writes;

-- Permissive: ambiguous predicate (no ts constraint) → dual-tier CTE.
-- The plan should contain both a hot UPDATE on _events and a cold
-- duckdb.raw_query call.
SET coldfront.allow_mixed_writes = on;
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'x' WHERE id = 1;

-- Strict: same statement → ERROR
SET coldfront.allow_mixed_writes = off;
UPDATE public.events SET status = 'x' WHERE id = 1;

-- Hot-only and cold-only are unaffected by the GUC (same output either way).
SET coldfront.allow_mixed_writes = off;
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'hot' WHERE ts = '2026-04-01 12:00:00+00';
SET coldfront.allow_mixed_writes = on;
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'hot' WHERE ts = '2026-04-01 12:00:00+00';

-- Reset
RESET coldfront.allow_mixed_writes;

-- Cleanup
DROP VIEW public.events;
DROP TABLE public._events;
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
