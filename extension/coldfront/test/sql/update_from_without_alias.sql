-- An UPDATE ... FROM, a DELETE ... USING or a correlated sub-select on a tiered
-- view that gives the view no alias. The deparser then qualifies the view's
-- columns by its name, so the retargeted relation takes that name as its
-- alias, on both tiers, and a cold statement reads its PostgreSQL table
-- through pglocal. White-box: EXPLAIN VERBOSE shows the cold SQL, and only hot
-- statements run, since the regress server has no warehouse.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared
-- regress db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);
CREATE TABLE public.src (id int, status text);
INSERT INTO public._events VALUES (1, '2026-05-01 00:00:00+00', 'a'), (2, '2026-05-02 00:00:00+00', 'b'), (3, '2026-05-03 00:00:00+00', 'c');
INSERT INTO public.src VALUES (1, 'from'), (2, 'exists'), (3, 'using');

-- The hot tier: the three shapes run on the hot table under the view's name.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = s.status FROM public.src s
  WHERE events.id = s.id AND events.ts >= '2026-05-01 00:00:00+00';
UPDATE public.events SET status = s.status FROM public.src s
WHERE events.id = s.id AND s.status = 'from' AND events.ts >= '2026-05-01 00:00:00+00';
UPDATE public.events SET status = 'exists' WHERE ts >= '2026-05-01 00:00:00+00'
  AND EXISTS (SELECT 1 FROM public.src s WHERE s.id = events.id AND s.status = 'exists');
DELETE FROM public.events USING public.src s
WHERE events.id = s.id AND s.status = 'using' AND events.ts >= '2026-05-01 00:00:00+00';
SELECT id, status FROM public._events ORDER BY id;

-- The cold tier: the alias again, and the PostgreSQL table through pglocal.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = s.status FROM public.src s
  WHERE events.id = s.id AND events.ts < '2026-01-01 00:00:00+00';
EXPLAIN (COSTS OFF, VERBOSE)
  DELETE FROM public.events USING public.src s
  WHERE events.id = s.id AND events.ts < '2026-01-01 00:00:00+00';

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events, public.src;
