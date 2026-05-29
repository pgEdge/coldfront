-- RENAME of the hot table updates coldfront.tiered_views.hot_table and rebuilds
-- the view so its hot branch references the new name. The view_oid is stable
-- across a rename, so the registry key does not change.

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

-- Rename the hot table. Registry hot_table must follow.
ALTER TABLE public._events RENAME TO _events_v2;
SELECT hot_table FROM coldfront.tiered_views
 WHERE view_oid = 'public.events'::regclass;

-- The view still resolves and projects the same columns from the renamed hot
-- table.
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events_v2;
