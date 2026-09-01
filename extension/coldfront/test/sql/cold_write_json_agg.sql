-- A JSON aggregate on the cold write path. DuckDB has neither jsonb_agg nor
-- json_agg, and its json_group_array is a macro that refuses the ORDER BY an
-- aggregate carries, so the rewrite target is to_json(array_agg(...)): both
-- engines have those, and array_agg keeps the ORDER BY. The substitution adds a
-- closing paren at the aggregate's own, which is what the map's `wrap` flag
-- does. Two halves:
--   (A) white-box: the deparsed cold SQL carries to_json(array_agg(...)) for an
--       UPDATE (with and without ORDER BY) and for an INSERT ... SELECT.
--   (B) parity: DuckDB accepts the target and rejects what it replaces.
-- White-box: we do NOT exercise Iceberg I/O.
-- Suppress NOTICEs: raw_query echoes each DuckDB result as a (version-dependent)
-- NOTICE, and CREATE EXTENSION emits "already exists" depending on suite order.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, data jsonb);
CREATE VIEW public.events AS SELECT * FROM public._events;
CREATE TABLE public.src (k text);
INSERT INTO public.src VALUES ('b'), ('a');
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- (A1) Cold UPDATE, aggregate carrying ORDER BY: the ORDER BY rides along inside
-- array_agg, which is an aggregate in DuckDB (json_group_array is not).
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = (SELECT jsonb_agg(k ORDER BY k) FROM public.src)
WHERE ts < '2019-01-01'::timestamptz;

-- (A2) Cold UPDATE, no ORDER BY.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = (SELECT jsonb_agg(k) FROM public.src)
WHERE ts < '2019-01-01'::timestamptz;

-- (A3) The json_ spelling reaches DuckDB the same way: the catch-all leaves it
-- alone (no jsonb token), so it needs its own entry.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = (SELECT json_agg(k)::jsonb FROM public.src)
WHERE ts < '2019-01-01'::timestamptz;

-- (A4) Cold INSERT ... SELECT: the aggregate sits in the row source that the
-- cold leg streams out of PostgreSQL.
EXPLAIN (COSTS OFF, VERBOSE)
INSERT INTO public.events
SELECT 9, '2019-01-01'::timestamptz, jsonb_agg(k ORDER BY k) FROM public.src;

-- (A5) An aggregate nested inside an object builder: the added paren must land
-- at the aggregate's own close, leaving the builder's intact.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events
SET data = (SELECT jsonb_build_object('all', jsonb_agg(k ORDER BY k)) FROM public.src)
WHERE ts < '2019-01-01'::timestamptz;

-- (A6) A hot-tier UPDATE is plain PostgreSQL DML: jsonb_agg stays, and the
-- column stays jsonb.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = (SELECT jsonb_agg(k) FROM public.src)
WHERE ts >= '2026-06-01'::timestamptz;

-- (A7) The aggregate's name inside a string literal is not a call: left intact.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = to_jsonb('jsonb_agg(x)'::text)
WHERE ts < '2019-01-01'::timestamptz;

-- (A8) The reverse nesting of (A5): a builder inside the aggregate, with an
-- operator applied to the builder's result. The builder's own paren also counts
-- toward the depth, so the added paren still lands at the aggregate's close,
-- keeping the operator and the ORDER BY inside array_agg.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events
SET data = (SELECT jsonb_agg(jsonb_build_object('k', k) ->> 'k' ORDER BY k) FROM public.src)
WHERE ts < '2019-01-01'::timestamptz;

-- (B) Parity against the live DuckDB: the target is accepted (ordered and not),
-- and both spellings it replaces are rejected. A void row = accepted.
SELECT duckdb.raw_query($$ SELECT to_json(array_agg(x ORDER BY x)) FROM (VALUES ('b'),('a')) v(x) $$);
SELECT duckdb.raw_query($$ SELECT to_json(array_agg(x)) FROM (VALUES ('b'),('a')) v(x) $$);
SELECT duckdb.raw_query($$ SELECT to_json(array_agg(json_object('k', x) ->> 'k' ORDER BY x)) FROM (VALUES ('b'),('a')) v(x) $$);
SELECT duckdb.raw_query($$ SELECT json_agg(x) FROM (VALUES ('a')) v(x) $$);
SELECT duckdb.raw_query($$ SELECT jsonb_agg(x) FROM (VALUES ('a')) v(x) $$);
-- json_group_array is why the target is not that: a macro cannot take ORDER BY.
SELECT duckdb.raw_query($$ SELECT json_group_array(x ORDER BY x) FROM (VALUES ('a')) v(x) $$);

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
DROP TABLE public.src;
