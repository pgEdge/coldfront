-- A WITH clause on an INSERT into a tiered view, in both positions PostgreSQL
-- allows. A leading WITH's entries open the rewritten statement, ahead of the
-- rewrite's own, so an entry that modifies data stays at the top level where
-- PostgreSQL requires it. An INSERT nested in a WITH entry is rewritten in
-- place, with the rewrite's source and cold sink lifted into the outer WITH
-- list just before it. White-box: hot rows only, since the regress server has
-- no warehouse; cold rows are ci/journey.sh's.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared
-- regress db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.local_pg_dsn = '';
SET coldfront.dblink_self = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);
CREATE TABLE public.staging (id int, ts timestamptz, status text);

-- A leading WITH: the plan shows its entry at the top level beside the
-- rewrite's, and the source reads it there.
EXPLAIN (COSTS OFF, VERBOSE)
  WITH s AS (SELECT 7 AS id, '2026-05-01 00:00:00+00'::timestamptz AS ts, 'new' AS status)
  INSERT INTO public.events SELECT id, ts, status FROM s;
-- An entry may take a name the rewrite's own entries once had.
WITH src AS (SELECT 1 AS id, '2026-05-01 00:00:00+00'::timestamptz AS ts, 'src' AS status)
INSERT INTO public.events SELECT id, ts, status FROM src;
-- A recursive WITH.
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3)
INSERT INTO public.events (id, ts, status) SELECT 10 + i, '2026-05-01 00:00:00+00', 'recursive' FROM n;
-- An entry that modifies data: the rows a DELETE returns move into the view.
INSERT INTO public.staging VALUES (20, '2026-05-01 00:00:00+00', 'moved');
WITH moved AS (DELETE FROM public.staging RETURNING id, ts, status)
INSERT INTO public.events SELECT id, ts, status FROM moved;
SELECT count(*) AS staging_left FROM public.staging;

-- An INSERT nested in WITH: on its own, reading an entry before it, under a
-- top-level INSERT into another table, with a bound parameter, and in plpgsql.
WITH i AS (INSERT INTO public.events (id, ts, status) VALUES (30, '2026-05-01 00:00:00+00', 'nested'))
SELECT 1 AS outer_ran;
WITH a AS (SELECT 31 AS id, '2026-05-01 00:00:00+00'::timestamptz AS ts, 'nested_cte' AS status),
     i AS (INSERT INTO public.events SELECT id, ts, status FROM a)
SELECT count(*) AS outer_read FROM a;
WITH i AS (INSERT INTO public.events (id, ts, status) VALUES (32, '2026-05-01 00:00:00+00', 'nested_under_insert'))
INSERT INTO public.staging VALUES (32, '2026-05-01 00:00:00+00', 'outer');
PREPARE nested(text) AS
  WITH i AS (INSERT INTO public.events (id, ts, status) VALUES (33, '2026-05-01 00:00:00+00', $1))
  SELECT 1;
EXECUTE nested('nested_param');
DO $$ DECLARE x int; BEGIN
  WITH i AS (INSERT INTO public.events (id, ts, status) VALUES (34, '2026-05-01 00:00:00+00', 'nested_plpgsql'))
  SELECT 1 INTO x;
END $$;
SELECT id, ts, status FROM public._events ORDER BY id;
SELECT id, status FROM public.staging ORDER BY id;

-- With a watermark a row may go cold, so RETURNING is refused as at the top
-- level.
WITH i AS (INSERT INTO public.events (id, ts, status) VALUES (40, '2026-05-01 00:00:00+00', 'returning') RETURNING id)
SELECT id FROM i;
-- The rewrite stands in for one write to the view: a second one in the same
-- statement is refused.
WITH i AS (INSERT INTO public.events (id, ts, status) VALUES (41, '2026-05-01 00:00:00+00', 'twice'))
INSERT INTO public.events (id, ts, status) VALUES (42, '2026-05-01 00:00:00+00', 'twice');
WITH i AS (INSERT INTO public.events (id, ts, status) VALUES (43, '2026-05-01 00:00:00+00', 'twice')),
     j AS (INSERT INTO public.events (id, ts, status) VALUES (44, '2026-05-01 00:00:00+00', 'twice'))
SELECT 1;
SELECT count(*) AS rows_after FROM public._events;

-- Without a watermark every row is hot, and a nested INSERT keeps RETURNING.
CREATE TABLE public._plain (id int, ts timestamptz, status text);
CREATE VIEW public.plain AS SELECT * FROM public._plain;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'plain', 'public._plain', 'ice.default.plain', 'ts');
WITH i AS (INSERT INTO public.plain (id, ts, status) VALUES (1, '2026-01-01 00:00:00+00', 'hot') RETURNING id, status)
SELECT id, status FROM i;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events, public.plain;
DROP TABLE public._events, public._plain, public.staging;

-- A decoupled view's INSERT runs its source in DuckDB, which does not see the
-- statement's WITH entries. A nested INSERT is rewritten in place (EXPLAIN
-- only: no warehouse) as long as it reads none of them, and a leading WITH that
-- modifies data is refused, because DuckDB cannot run the write it holds.
CREATE TABLE public._ice_base (id int, ts timestamptz, status text);
CREATE VIEW public.iceplain AS SELECT * FROM public._ice_base;
INSERT INTO coldfront.tiered_views(schema_name, relname, iceberg_table, is_iceberg_only)
VALUES ('public', 'iceplain', 'ice.default.iceplain', true);
EXPLAIN (COSTS OFF, VERBOSE)
  WITH i AS (INSERT INTO public.iceplain (id, ts, status) VALUES (1, '2026-05-01 00:00:00+00', 'nested'))
  SELECT 1;
WITH a AS (SELECT 2 AS id, '2026-05-01 00:00:00+00'::timestamptz AS ts, 'from_cte' AS status),
     i AS (INSERT INTO public.iceplain SELECT id, ts, status FROM a)
SELECT 1;
CREATE TABLE public.staging (id int, ts timestamptz, status text);
WITH moved AS (DELETE FROM public.staging RETURNING id, ts, status)
INSERT INTO public.iceplain SELECT id, ts, status FROM moved;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.iceplain;
DROP TABLE public._ice_base, public.staging;

-- The clustered iceberg-only INSERT is re-emitted so the cluster is derived in
-- the same statement, and the CTE must survive that re-emission too: the WITH
-- folds into the derived table the assignment reads from, the only scope its
-- CTEs are visible from.
CREATE TABLE public._vec_base (id int, ts timestamptz, embedding real[]);
CREATE VIEW public.icevec AS SELECT * FROM public._vec_base;
INSERT INTO coldfront.tiered_views(schema_name, relname, iceberg_table, is_iceberg_only, vec_columns)
VALUES ('public', 'icevec', 'ice.default.icevec', true, ARRAY['embedding']);

EXPLAIN (COSTS OFF, VERBOSE)
  WITH s AS (SELECT 7 AS id, '2026-05-01 00:00:00+00'::timestamptz AS ts, ARRAY[1,0,0]::real[] AS embedding)
  INSERT INTO public.icevec SELECT id, ts, embedding FROM s;

-- Cleanup.
DELETE FROM coldfront.tiered_views WHERE relname = 'icevec';
DROP VIEW public.icevec;
DROP TABLE public._vec_base;
