-- The registry is read once per statement and matched in memory. Three
-- behaviours that the snapshot must preserve:
--   (A) a registration made earlier in the same transaction is visible to the
--       next statement, so create_iceberg_table() followed by a write through
--       the view it created still rewrites.
--   (B) the watermark attaches by (schema_name, table_name), never by table
--       name alone.
--   (C) a statement naming several views finds the registered one among them,
--       and leaves the others alone.
-- White-box: the assertions are on the rewritten SQL, not on Iceberg I/O.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;
SET TIME ZONE 'UTC';
-- White-box: checks the generated SQL, not Iceberg I/O.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

-- (A) Register inside a transaction, then use the view in a later statement of
-- the same transaction. The cold UPDATE must still be rewritten through the
-- bakery, which it can only be if the hook sees the registration.
BEGIN;
CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'x' WHERE ts < '2019-01-01'::timestamptz;
COMMIT;

-- The same holds for a watermark moved earlier in the transaction: the second
-- statement classifies against the new cutoff, not the one it started with.
BEGIN;
UPDATE coldfront.archive_watermark SET cutoff_time = '2018-01-01'::timestamptz
 WHERE table_name = 'events';
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'y' WHERE ts < '2019-01-01'::timestamptz;
ROLLBACK;

-- (B) The watermark joins by (schema_name, table_name), the key it is stored
-- under: a same-named table's watermark in another schema must not attach to
-- this view. With public.events's own row gone the view has no cutoff, so the
-- write stays plain hot-tier DML; the decoy row would otherwise classify it
-- cold.
BEGIN;
DELETE FROM coldfront.archive_watermark
 WHERE schema_name = 'public' AND table_name = 'events';
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('other', 'events', '2026-03-01'::timestamptz);
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'z' WHERE ts < '2019-01-01'::timestamptz;
ROLLBACK;

-- (C) Two plain views the registry does not know, named alongside the tiered
-- one. The tiered view is still found, so the builder is rewritten. The JSON
-- rewrite is the one to assert on here: its output is PostgreSQL's own plan,
-- where date_bin's would be a DuckDB plan carrying row estimates.
CREATE VIEW public.plain_a AS SELECT 1 AS k;
CREATE VIEW public.plain_b AS SELECT 1 AS k;
EXPLAIN (COSTS OFF, VERBOSE)
SELECT jsonb_build_object('status', e.status)::text AS details
FROM public.events e, public.plain_a a, public.plain_b b
WHERE a.k = b.k;

-- A statement naming only unregistered views is left alone entirely.
EXPLAIN (COSTS OFF, VERBOSE)
SELECT jsonb_build_object('k', a.k)::text AS details
FROM public.plain_a a, public.plain_b b WHERE a.k = b.k;

-- Cleanup.
DROP VIEW public.plain_a;
DROP VIEW public.plain_b;
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
