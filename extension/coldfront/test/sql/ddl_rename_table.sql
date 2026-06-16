-- RENAME of the hot table updates coldfront.tiered_views.hot_table and rebuilds
-- the view so its hot branch references the new name. The view name is stable
-- across the rename, so the registry key (schema, relname) does not change.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
-- White-box: checks the hooks' SQL/DDL, not Iceberg I/O. Real cold I/O is ci/journey.sh; see README.md.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.dblink_self = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');

-- Rename the hot table. Registry hot_table must follow.
ALTER TABLE public._events RENAME TO _events_v2;
SELECT hot_table FROM coldfront.tiered_views
 WHERE schema_name = 'public' AND relname = 'events';

-- The view still resolves and projects the same columns from the renamed hot
-- table.
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events_v2;
