-- Regression test: a WHERE-clause string literal that contains the substring
-- " RETURNING " must not cause the cold-path rewriter to truncate the query.
--
-- The original strip_returning() used strstr() over the deparsed SQL, which
-- matched inside quoted literals and silently chopped the query there.
-- After the fix, RETURNING is cleared on a cloned Query before deparse, so
-- no substring search happens — and the literal survives intact.

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

-- Cold-path UPDATE whose WHERE clause contains " RETURNING " inside a text
-- literal. The raw_query argument must carry the full literal verbatim.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'normal'
  WHERE ts < '2026-03-01'::timestamptz
    AND status = 'bug RETURNING error';

-- Cleanup
DROP VIEW public.events;
DROP TABLE public._events;
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
