-- PERMISSIVE mode (coldfront.allow_mixed_writes = on, the default): an UPDATE that
-- assigns the partition column of a tiered view is rewritten into a single
-- coldfront._cross_tier_move(...) call that relocates the matched rows across the
-- hot/cold cutoff. White-box: we assert the rewrite shape via
-- EXPLAIN VERBOSE — the rewritten statement is just the function call (no
-- iceberg_scan in it, so the planner needs no Iceberg catalog). The live tier
-- relocation is exercised in ci/journey.sh. v1 rejects, at parse-analyze, the move
-- shapes the function does not support.

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

SET coldfront.allow_mixed_writes = on;

-- (1) Constant new ts, WHERE on a non-partition column: the rewrite is one
-- _cross_tier_move call carrying the deparsed WHERE and new-ts expression.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET ts = '2026-06-18 10:00:00+00' WHERE status = 'x';

-- (2) Row-dependent new ts (ts + interval), tier-deterministic WHERE: same shape;
-- the new-ts expression is the interval arithmetic over the partition column.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET ts = ts + interval '6 months' WHERE ts < '2026-02-01+00';

-- (3) Rejections at parse-analyze (no tier write):
-- a VOLATILE new value (re-evaluates per row → could split a row across tiers).
UPDATE public.events SET ts = clock_timestamp() WHERE status = 'x';
-- new value references a column other than the partition column.
UPDATE public.events SET ts = make_timestamptz(2026, 6, 1, 0, 0, 0) + (id || ' days')::interval WHERE status = 'x';
-- a multi-column SET that also moves the partition column.
UPDATE public.events SET ts = '2026-06-18 10:00:00+00', status = 'y' WHERE status = 'x';
-- RETURNING from a move (the cold tier cannot return rows).
UPDATE public.events SET ts = '2026-06-18 10:00:00+00' WHERE status = 'x' RETURNING id;
-- a WHERE that pulls in other tables / sub-queries: the cold tier is read in
-- DuckDB, which can't correlate with Postgres tables, so it is rejected up front.
UPDATE public.events SET ts = '2026-06-18 10:00:00+00' WHERE id IN (SELECT 1);

-- Without a cutoff (nothing archived) a partition-column UPDATE is a plain hot
-- UPDATE — no move, no rejection.
DELETE FROM coldfront.archive_watermark WHERE table_name = 'events';
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET ts = '2026-06-18 10:00:00+00' WHERE status = 'x';

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
