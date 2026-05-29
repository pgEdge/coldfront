-- RENAME COLUMN on a tiered hot table rebuilds the transparent view with the
-- new column name. When the renamed column is the partition column, the
-- registry's partition_col is updated too.

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

-- Rename a non-partition column.
ALTER TABLE public._events RENAME COLUMN status TO state;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- Rename the partition column: registry partition_col must follow.
ALTER TABLE public._events RENAME COLUMN ts TO event_time;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;
SELECT partition_col FROM coldfront.tiered_views
 WHERE view_oid = 'public.events'::regclass;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
