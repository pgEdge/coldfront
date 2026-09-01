-- date_bin on a tiered read. A read that spans the cold tier runs entirely in
-- DuckDB, which has no date_bin; its time_bucket takes the same (interval,
-- timestamptz, timestamptz) arguments and pg_duckdb declares it PG-side, so the
-- read is rewritten to time_bucket and reparses in both engines. White-box: DuckDB
-- executes the rewritten read against the heap (duckdb.force_execution), and the
-- reads that must stay untouched are shown through PostgreSQL's plan; no Iceberg I/O.
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

CREATE TABLE public._events (id int, ts timestamptz, val int);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);
INSERT INTO public._events VALUES (1, '2026-01-01 00:05+00', 10),
                                  (2, '2026-01-01 00:50+00', 20),
                                  (3, '2026-01-01 01:07+00', 30);

-- (A) Parity: DuckDB runs the rewritten read (force_execution scans the heap the
-- way a cold read scans Parquet; DuckDB rejecting the spelling would be a planning
-- warning here) and buckets the rows exactly as PostgreSQL's date_bin does on the
-- heap directly. The bucket is in the target list and the GROUP BY.
SET duckdb.force_execution = true;
SELECT date_bin('1 hour'::interval, ts, '2026-01-01'::timestamptz) AS bucket, sum(val)
FROM public.events GROUP BY 1 ORDER BY 1;
RESET duckdb.force_execution;
SELECT date_bin('1 hour'::interval, ts, '2026-01-01'::timestamptz) AS bucket, sum(val)
FROM public._events GROUP BY 1 ORDER BY 1;

-- (B) A read the hot heap can answer keeps date_bin: it never reaches DuckDB.
EXPLAIN (COSTS OFF, VERBOSE)
SELECT date_bin('1 hour'::interval, ts, '2026-01-01'::timestamptz) AS bucket
FROM public.events WHERE ts >= '2026-04-01'::timestamptz;

-- (C) A name that merely ends in date_bin( is a different function; it is left
-- alone. The read is not provably hot, so the rewrite pass does run on it.
CREATE FUNCTION public.undate_bin(interval, timestamptz, timestamptz) RETURNS timestamptz
LANGUAGE plpgsql AS $$ BEGIN RETURN $2; END $$;
EXPLAIN (COSTS OFF, VERBOSE)
SELECT undate_bin('1 hour'::interval, ts, '2026-01-01'::timestamptz) FROM public.events;

-- Cleanup.
DROP FUNCTION public.undate_bin(interval, timestamptz, timestamptz);
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
