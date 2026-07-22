-- RETURNING cannot be honored for any write that touches the cold tier:
-- duckdb-iceberg rejects RETURNING on Iceberg writes ("not yet supported for
-- updates of a Iceberg table"), and pg_duckdb's row-returning entry point
-- (duckdb.query) is SELECT-only. So cold/dual/tiered-INSERT writes must reject
-- RETURNING with a clear error rather than silently return a partial (hot-only),
-- void, or empty result set. Hot-only DML keeps RETURNING (plain PG DML).
-- White-box: no Iceberg attached; the error fires at parse-analyze.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text, data jsonb);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- Cold UPDATE … RETURNING (ts < cutoff) — rejected.
UPDATE public.events SET status = 'x' WHERE ts = '2026-01-15 01:00:00+00' RETURNING id;

-- Cold DELETE … RETURNING — rejected.
DELETE FROM public.events WHERE ts = '2026-01-15 01:00:00+00' RETURNING id;

-- Dual-tier (ambiguous predicate, allow_mixed_writes on by default) … RETURNING — rejected.
UPDATE public.events SET status = 'x' WHERE data->>'m' = 'y' RETURNING id;

-- Tiered INSERT … RETURNING (watermark present ⇒ split path) — rejected.
INSERT INTO public.events (id, ts, status) VALUES (1, '2026-01-15 01:00:00+00', 'x') RETURNING id;

-- Hot UPDATE … RETURNING (ts >= cutoff) is plain PG DML and KEEPS RETURNING —
-- rewritten to _events, no error.
EXPLAIN (COSTS OFF)
  UPDATE public.events SET status = 'x' WHERE ts = '2026-04-01 00:00:00+00' RETURNING id;

DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
