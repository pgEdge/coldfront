-- Every cold-tier write must route through coldfront._exec_iceberg_with_claim
-- (the serialization chokepoint) — never a bare duckdb.raw_query — so concurrent
-- committers can't hit a Lakekeeper 409. This holds in TIERED mode too, not just
-- iceberg-only. We assert the rewrite via EXPLAIN VERBOSE (no execution; the
-- bakery self-selects R-A vs local advisory lock at runtime).

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
-- White-box: checks the hooks' SQL/DDL, not Iceberg I/O. Real cold I/O is ci/journey.sh; see README.md.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- (1) Tiered cold UPDATE (ts < cutoff): plan must call
-- coldfront._exec_iceberg_with_claim, NOT bare duckdb.raw_query.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'x' WHERE ts = '2026-01-15 01:00:00+00';

-- (2) Tiered cold DELETE: same.
EXPLAIN (COSTS OFF, VERBOSE)
  DELETE FROM public.events WHERE ts = '2026-01-15 01:00:00+00';

-- (3) Ambiguous predicate → dual-tier CTE: the cold branch must be wrapped in
-- coldfront._exec_iceberg_with_claim (permissive mode, default).
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'x' WHERE id = 1;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
