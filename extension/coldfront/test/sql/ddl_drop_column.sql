-- DROP COLUMN on a tiered hot table rebuilds the transparent view without the
-- dropped column. CREATE OR REPLACE VIEW cannot drop a column, so the rebuild
-- must DROP + CREATE the view (and recreate its INSERT trigger).

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

-- Before: id, ts, status.
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

ALTER TABLE public._events DROP COLUMN status;

-- After: status is gone from the view.
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- The INSERT trigger was recreated on the rebuilt view.
SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'public.events'::regclass AND NOT tgisinternal
 ORDER BY tgname;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
