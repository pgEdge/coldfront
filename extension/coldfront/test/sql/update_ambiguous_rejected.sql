-- When the WHERE clause has no partition-column predicate (or one the walker
-- cannot prove stays in a single tier), the hook must ereport(ERROR) with
-- SQLSTATE 0A000 (ERRCODE_FEATURE_NOT_SUPPORTED) and a hint pointing at the
-- partition column.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
-- Strict mode: ambiguous predicates must error rather than fall through
-- to the permissive dual-tier rewrite.
SET coldfront.allow_mixed_writes = off;

CREATE TABLE public._events (id int, ts timestamptz, status text);
INSERT INTO public._events VALUES (1, '2026-04-01 12:00:00+00', 'hot_orig');
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public.events'::regclass, 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- WHERE predicate does not reference ts → TIER_AMBIGUOUS → ERROR
UPDATE public.events SET status = 'x' WHERE id = 1;

-- Even an OR across tiers is ambiguous
UPDATE public.events SET status = 'x'
  WHERE ts = '2026-01-15 01:00:00+00' OR ts = '2026-04-01 12:00:00+00';

-- _events must be untouched by the rejected statements
SELECT id, status FROM public._events ORDER BY id;

-- Cleanup
DROP VIEW public.events;
DROP TABLE public._events;
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
