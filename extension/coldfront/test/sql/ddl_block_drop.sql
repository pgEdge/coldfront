-- DROP TABLE on a tiered hot table, and DROP VIEW on the transparent view,
-- must both be blocked: dropping either would orphan the Iceberg cold tier.
-- The block is intentional; the error tells the operator to dismantle tiering
-- deliberately (unregister + drop each tier explicitly), not via a one-shot helper.

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

-- DROP of the hot table is blocked.
DROP TABLE public._events;

-- DROP of the transparent view is blocked.
DROP VIEW public.events;

-- A non-tiered table drops normally (control).
CREATE TABLE public.plain (id int);
DROP TABLE public.plain;

-- Cleanup: remove the registry row first so the drops are permitted.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
