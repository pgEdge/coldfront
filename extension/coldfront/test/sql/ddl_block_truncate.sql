-- TRUNCATE on a tiered hot table must be blocked: the per-row capture trigger
-- does not fire on TRUNCATE, and cold-tier rows in Iceberg would remain
-- visible through the view. The block is intentional; the operator must
-- truncate each tier explicitly and deliberately.

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

-- TRUNCATE of the hot table is blocked.
TRUNCATE public._events;

-- A non-tiered table truncates normally (control).
CREATE TABLE public.plain (id int);
INSERT INTO public.plain VALUES (1);
TRUNCATE public.plain;
SELECT count(*) FROM public.plain;
DROP TABLE public.plain;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
