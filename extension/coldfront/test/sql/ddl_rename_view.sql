-- RENAME of the transparent VIEW must migrate every name-keyed reference:
--   * coldfront.archive_watermark.table_name (keyed on the bare view name)
--   * the regenerated INSERT trigger function/trigger names
-- Without the watermark migration the rebuilt view would silently lose its
-- cold (Iceberg) UNION branch — the watermark lookup would miss, v_has_cutoff
-- would be false, and only the hot branch would remain.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.dblink_self = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public.events'::regclass, 'public._events', 'ice.default.events', 'ts');
-- A watermark exists, so the rebuilt view must keep its cold UNION branch.
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Before: view definition has the cold iceberg_scan branch.
SELECT pg_get_viewdef('public.events'::regclass) LIKE '%iceberg_scan%' AS has_cold_branch;

-- Rename the view.
ALTER VIEW public.events RENAME TO events_v2;

-- The watermark row followed the rename (keyed on the new bare view name).
SELECT table_name FROM coldfront.archive_watermark ORDER BY table_name;

-- The rebuilt view under the new name STILL has the cold UNION branch
-- (watermark lookup matched the new name).
SELECT pg_get_viewdef('public.events_v2'::regclass) LIKE '%iceberg_scan%' AS has_cold_branch;

-- The registry re-pointed to the new view's OID and the new name resolves.
SELECT (view_oid = 'public.events_v2'::regclass) AS registry_points_at_new_view,
       hot_table, partition_col
  FROM coldfront.tiered_views;

-- The INSERT trigger was regenerated under the new view name.
SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'public.events_v2'::regclass AND NOT tgisinternal
 ORDER BY tgname;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events_v2;
DROP TABLE public._events;
