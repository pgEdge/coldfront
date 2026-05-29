-- ALTER COLUMN TYPE on a tiered hot table rebuilds the transparent view.
-- The view column set is unchanged (same names) but the view is recreated
-- with the new projected type. Iceberg mirror is skipped (warehouse='').

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

-- Before: id is integer.
SELECT format_type(atttypid, atttypmod) FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attname = 'id';

ALTER TABLE public._events ALTER COLUMN id TYPE bigint;

-- After: id is bigint in the rebuilt view.
SELECT format_type(atttypid, atttypmod) FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attname = 'id';

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
