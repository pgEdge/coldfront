-- Regression test: a text literal containing "::timestamp with time zone"
-- (or any other PG-specific cast spelling) must not be rewritten by
-- normalize_casts_for_duckdb — only the OUT-OF-QUOTES cast occurrences should
-- be normalised.
--
-- The original implementation did a blind substring replace, so a row value
-- like 'cast::timestamp with time zone' became 'cast::timestamptz' in the
-- cold-path raw_query argument.  The quote-aware scanner skips anything
-- inside single-quoted literals.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public.events'::regclass, 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Cold path. SET value contains an embedded "::timestamp with time zone" inside
-- a text literal; that must stay intact in the raw_query argument. The real
-- timestamptz cast in the WHERE clause must still be normalised to ::timestamptz.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'cast::timestamp with time zone'
  WHERE ts < '2026-03-01'::timestamptz;

-- Also exercise embedded single-quote escapes inside a cast-looking literal.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'it''s a ::character varying value'
  WHERE ts < '2026-03-01'::timestamptz;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
