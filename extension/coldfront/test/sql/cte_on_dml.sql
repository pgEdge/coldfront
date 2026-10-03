-- A WITH clause on an UPDATE or DELETE over a tiered view, in both positions
-- PostgreSQL allows. A leading WITH is carried through verbatim with only the
-- relation swapped (hot heap or Iceberg): pg_get_querydef emits it before the
-- verb, so the rewrite finds the result relation past it. An UPDATE or DELETE
-- nested in a WITH entry takes the path of a top-level one, rewritten in
-- place. White-box: EXPLAIN VERBOSE shows the cold SQL, and only hot rows are
-- executed, since the regress server has no warehouse.
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

-- Cold UPDATE (ts < cutoff) with a CTE referenced in SET: the WITH must be
-- carried into the cold DML with the relation swapped to ice.default.events.
EXPLAIN (COSTS OFF, VERBOSE)
  WITH v AS (SELECT 'cold_upd'::text AS s)
  UPDATE public.events SET status = (SELECT s FROM v)
  WHERE ts < '2026-01-01 00:00:00+00';

-- Cold DELETE (ts < cutoff) with a CTE referenced in WHERE: WITH carried through.
EXPLAIN (COSTS OFF, VERBOSE)
  WITH lim AS (SELECT 99 AS n)
  DELETE FROM public.events
  WHERE ts < '2026-01-01 00:00:00+00' AND id < (SELECT n FROM lim);

-- A WITH entry that modifies data cannot reach the cold tier: DuckDB runs the
-- statement there and has no data-modifying WITH, so a cold write is refused,
-- and so is a dual-tier one, whose cold half runs there too.
CREATE TABLE public.staging (id int);
WITH gone AS (DELETE FROM public.staging RETURNING id)
DELETE FROM public.events
WHERE ts < '2026-01-01 00:00:00+00' AND id IN (SELECT id FROM gone);
WITH gone AS (DELETE FROM public.staging RETURNING id)
UPDATE public.events SET status = 'gone' WHERE id IN (SELECT id FROM gone);
DROP TABLE public.staging;
-- The refusal stands in for DuckDB 1.5.4's parser, which takes only a SELECT
-- as a WITH entry's body. DuckDB 2.0 runs a data-modifying entry, so once the
-- pin moves this statement succeeds and the test fails: the cue to remove
-- reject_cold_modifying_cte (coldfront.c).
SELECT duckdb.raw_query('WITH gone AS (DELETE FROM nowhere RETURNING id) SELECT id FROM gone');

-- An UPDATE or DELETE nested in a WITH entry. A hot one is a plain swap that
-- keeps RETURNING and may read an entry before it; a cold one is the anchor
-- UPDATE that runs the DuckDB write; a dual one lifts its cold half into the
-- statement's WITH list, just before the entry.
INSERT INTO public._events VALUES (1, '2026-05-01 00:00:00+00', 'hot'), (2, '2026-05-02 00:00:00+00', 'hot');
WITH u AS (UPDATE public.events SET status = 'nested' WHERE ts >= '2026-05-01 00:00:00+00' AND id = 1 RETURNING id, status)
SELECT id, status FROM u;
WITH ids AS (SELECT 2 AS id),
     d AS (DELETE FROM public.events WHERE ts >= '2026-05-01 00:00:00+00' AND id IN (SELECT id FROM ids) RETURNING id)
SELECT id AS deleted FROM d;
SELECT id, status FROM public._events ORDER BY id;
EXPLAIN (COSTS OFF, VERBOSE)
  WITH d AS (DELETE FROM public.events WHERE ts < '2026-01-01 00:00:00+00')
  SELECT 1;
EXPLAIN (COSTS OFF, VERBOSE)
  WITH u AS (UPDATE public.events SET status = 'dual' WHERE id = 1)
  SELECT 1;
-- What runs in DuckDB cannot read another WITH entry, or return rows.
WITH ids AS (SELECT 1 AS id),
     d AS (DELETE FROM public.events WHERE ts < '2026-01-01 00:00:00+00' AND id IN (SELECT id FROM ids))
SELECT 1;
WITH d AS (DELETE FROM public.events WHERE ts < '2026-01-01 00:00:00+00' RETURNING id)
SELECT id FROM d;
-- A partition-column UPDATE with a watermark is a cross-tier move, which no
-- WITH entry can hold.
WITH u AS (UPDATE public.events SET ts = ts - interval '1 year' WHERE ts >= '2026-05-01 00:00:00+00')
SELECT 1;
-- One write to the view per statement.
WITH d AS (DELETE FROM public.events WHERE ts >= '2026-05-01 00:00:00+00')
INSERT INTO public.events VALUES (3, '2026-05-03 00:00:00+00', 'twice');
DELETE FROM public._events;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
