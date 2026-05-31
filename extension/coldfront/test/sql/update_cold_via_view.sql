-- Tier-deterministic UPDATE whose predicate proves the cold tier (ts < cutoff)
-- must be rewritten to SELECT duckdb.raw_query($MTQ$ UPDATE ice.default.events
-- ... $MTQ$). EXPLAIN verifies the rewrite targets raw_query; we do NOT execute
-- (that's the E2E harness's job — pg_regress doesn't have Iceberg attached).

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
-- White-box: checks the hooks' SQL/DDL, not Iceberg I/O. Real cold I/O is ci/journey.sh; see README.md.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
INSERT INTO public._events VALUES (1, '2026-04-01 12:00:00+00', 'hot_orig');
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Cold-only (ts < cutoff): plan must call duckdb.raw_query with the cold DML.
-- VERBOSE exposes the function argument so we can assert the generated SQL.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'cold_upd' WHERE ts = '2026-01-15 01:00:00+00';

-- Hot side must be untouched after this plan runs — we don't execute here,
-- but verify _events pre-state for completeness.
SELECT id, status FROM public._events ORDER BY id;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
