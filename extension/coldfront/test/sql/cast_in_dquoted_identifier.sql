-- Regression: a double-quoted identifier whose content matches a PG cast
-- spelling (e.g., "col::timestamp with time zone") must not be rewritten by
-- normalize_casts_for_duckdb. The original scanner only tracked single-quote
-- state and would destructively shorten the identifier.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (
    "col::timestamp with time zone" text,
    ts timestamptz
);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public.events'::regclass, 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Cold path: SET targets the column whose name contains the cast spelling.
-- The column name must survive verbatim in the raw_query argument; only the
-- real ts cast should be normalised.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET "col::timestamp with time zone" = 'x'
  WHERE ts < '2026-03-01'::timestamptz;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
