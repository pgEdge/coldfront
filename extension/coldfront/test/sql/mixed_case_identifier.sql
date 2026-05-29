-- Regression: tiered views on tables with mixed-case (or otherwise quoted)
-- identifiers must rewrite cleanly. The previous implementation built the
-- prefix-search string from the raw catalog name (unquoted), but
-- pg_get_querydef quotes mixed-case names — so strncmp always missed and
-- the hook errored out with "cannot locate result relation".
-- The fix wraps the names with quote_identifier() before forming the search
-- string, matching what the deparser emits.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public."_MixedEvents" (id int, ts timestamptz, status text);
CREATE VIEW public."MixedEvents" AS SELECT * FROM public."_MixedEvents";

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public."MixedEvents"'::regclass,
        'public."_MixedEvents"',
        'ice.default."MixedEvents"',
        'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('MixedEvents', '2026-03-01'::timestamptz);

-- Cold UPDATE through the mixed-case view: must rewrite, not error.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public."MixedEvents" SET status = 'cold_upd'
  WHERE ts = '2026-01-15 01:00:00+00';

-- Cold DELETE through the mixed-case view: must rewrite, not error.
EXPLAIN (COSTS OFF, VERBOSE)
  DELETE FROM public."MixedEvents"
  WHERE ts = '2026-01-15 01:00:00+00';

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public."MixedEvents";
DROP TABLE public."_MixedEvents";
