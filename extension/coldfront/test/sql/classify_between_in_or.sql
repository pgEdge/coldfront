-- classify_qual must accept tier-deterministic predicates beyond plain
-- Var <op> Const. In particular:
--   * BETWEEN a AND b  — the analyser already desugars to two OpExprs
--                         joined by AND, which the existing walker handles.
--   * ts IN (...)     — ScalarArrayOpExpr; tier-deterministic iff every
--                         array element proves the same tier.
--   * ts = a OR ts = b — tier-deterministic iff every disjunct proves the
--                         same tier.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
-- White-box: checks the hooks' SQL/DDL, not Iceberg I/O. Real cold I/O is ci/journey.sh; see README.md.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
-- Strict mode so the "straddle the cutoff" cases error cleanly rather
-- than succeeding via the permissive dual-tier rewrite.
SET coldfront.allow_mixed_writes = off;

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- BETWEEN entirely below the cutoff → cold
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x'
  WHERE ts BETWEEN '2026-01-01'::timestamptz AND '2026-02-01'::timestamptz;

-- BETWEEN entirely at/above the cutoff → hot
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x'
  WHERE ts BETWEEN '2026-04-01'::timestamptz AND '2026-05-01'::timestamptz;

-- BETWEEN that straddles the cutoff → ambiguous
UPDATE public.events SET status = 'x'
  WHERE ts BETWEEN '2026-01-01'::timestamptz AND '2026-04-01'::timestamptz;

-- IN of all-cold values → cold
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x'
  WHERE ts IN ('2026-01-15 01:00:00+00'::timestamptz,
               '2026-02-15 01:00:00+00'::timestamptz);

-- IN of all-hot values → hot
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x'
  WHERE ts IN ('2026-04-15 01:00:00+00'::timestamptz,
               '2026-05-15 01:00:00+00'::timestamptz);

-- IN that mixes tiers → ambiguous
UPDATE public.events SET status = 'x'
  WHERE ts IN ('2026-01-15 01:00:00+00'::timestamptz,
               '2026-04-15 01:00:00+00'::timestamptz);

-- OR of all-cold disjuncts → cold
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x'
  WHERE ts = '2026-01-15 01:00:00+00'::timestamptz
     OR ts = '2026-02-15 01:00:00+00'::timestamptz;

-- OR of all-hot disjuncts → hot
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x'
  WHERE ts = '2026-04-15 01:00:00+00'::timestamptz
     OR ts = '2026-05-15 01:00:00+00'::timestamptz;

-- OR mixing tiers → ambiguous
UPDATE public.events SET status = 'x'
  WHERE ts = '2026-01-15 01:00:00+00'::timestamptz
     OR ts = '2026-04-15 01:00:00+00'::timestamptz;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
