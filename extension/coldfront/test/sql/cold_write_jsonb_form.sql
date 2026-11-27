-- A cold write stores a jsonb value as the text PostgreSQL renders it in, which is
-- what a read compares. DuckDB cannot produce that text, so the value a cold
-- UPDATE, INSERT or MERGE assigns to a jsonb column must be that text already:
-- a constant, a parameter, a jsonb column, or a CASE or COALESCE that picks one
-- of those. Any other value is refused, with an error that names the column.
-- White-box: EXPLAIN shows the statement each accepted shape becomes; no Iceberg
-- I/O.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, data jsonb, alt jsonb, note text, j json);
CREATE VIEW public.events AS SELECT * FROM public._events;
CREATE TABLE public._dv (id int, doc jsonb);
CREATE VIEW public.dv AS SELECT * FROM public._dv;
CREATE DOMAIN public.jdoc AS jsonb;
CREATE TABLE public.src (id int, k text, doc jsonb, dd public.jdoc);
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.tiered_views(schema_name, relname, iceberg_table, is_iceberg_only)
VALUES ('public', 'dv', 'ice.default.dv', true);
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- Accepted. A constant reaches DuckDB in jsonb's rendering, whatever its spelling.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = '{"b":1,   "a":2}' WHERE ts < '2019-01-01'::timestamptz;
-- Another jsonb column, and a CASE and a COALESCE that pick one or a constant.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = alt WHERE ts < '2019-01-01'::timestamptz;
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = CASE WHEN id > 5 THEN alt ELSE COALESCE(data, '{}') END
WHERE ts < '2019-01-01'::timestamptz;
-- A jsonb column of a PostgreSQL table, in a MERGE and in a decoupled INSERT, and
-- a column of a domain over jsonb.
EXPLAIN (COSTS OFF, VERBOSE)
MERGE INTO public.dv d USING public.src s ON d.id = s.id
WHEN MATCHED THEN UPDATE SET doc = s.doc
WHEN NOT MATCHED THEN INSERT VALUES (s.id, s.doc);
EXPLAIN (COSTS OFF, VERBOSE)
INSERT INTO public.dv SELECT id, doc FROM public.src;
EXPLAIN (COSTS OFF, VERBOSE)
INSERT INTO public.dv SELECT id, dd FROM public.src;
-- A bound parameter.
PREPARE dv_set(jsonb, int) AS UPDATE public.dv SET doc = $1 WHERE id = $2;
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE dv_set('{"b":1,   "a":2}', 4);
DEALLOCATE dv_set;
-- On the hot tier PostgreSQL computes the value, so any expression is accepted.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET data = data || '{"x": 1}' WHERE ts >= '2026-03-02'::timestamptz;

-- Refused, naming the column: a built object, with or without the row's columns;
-- a sub-select; text cast to jsonb; an operator; a value extracted from the row;
-- a volatile function; a json column; a MERGE and a decoupled INSERT that build a
-- value; and an UPDATE on both tiers.
UPDATE public.events SET data = jsonb_build_object('b', 1, 'a', 2) WHERE ts < '2019-01-01'::timestamptz;
UPDATE public.events SET data = jsonb_build_object('id', id, 'note', note), note = 'x'
WHERE ts < '2019-01-01'::timestamptz;
UPDATE public.events SET data = (SELECT jsonb_agg(k ORDER BY k) FROM public.src)
WHERE ts < '2019-01-01'::timestamptz;
UPDATE public.events SET data = '{"b":1,   "a":2}'::text::jsonb WHERE ts < '2019-01-01'::timestamptz;
UPDATE public.events SET data = data || '{"x": 1}' WHERE ts < '2019-01-01'::timestamptz;
UPDATE public.events e SET data = e.data -> 'k' WHERE e.ts < '2019-01-01'::timestamptz;
UPDATE public.events SET data = jsonb_build_object('r', random()) WHERE ts < '2019-01-01'::timestamptz;
UPDATE public.events SET data = j WHERE ts < '2019-01-01'::timestamptz;
MERGE INTO public.dv d USING public.src s ON d.id = s.id
WHEN NOT MATCHED THEN INSERT VALUES (s.id, jsonb_build_object('new', true));
INSERT INTO public.dv VALUES (1, jsonb_build_object('b', 1, 'a', 2)), (2, '{"z": 1}');
INSERT INTO public.dv SELECT id, k::jsonb FROM public.src;
UPDATE public.events SET data = jsonb_build_object('b', 1, 'a', 2) WHERE id = 7;

-- The refusal holds in a WITH entry and in PL/pgSQL.
WITH w AS (UPDATE public.dv SET doc = jsonb_build_object('a', 1) WHERE id = 1) SELECT 1;
DO $$ BEGIN UPDATE public.dv SET doc = jsonb_build_object('a', 1) WHERE id = 1; END $$;

-- The part of a cold write that DuckDB evaluates, its condition and a decoupled
-- INSERT's source, gets the rewrite a read DuckDB runs gets: a stored document
-- compares with a constant as text, a value DuckDB computes through json(), an
-- operator DuckDB lacks becomes DuckDB's function, and an ordering or an
-- untranslated operator is refused.
EXPLAIN (COSTS OFF, VERBOSE)
DELETE FROM public.events WHERE ts < '2019-01-01'::timestamptz AND data = '{"b":1,   "a":2}';
EXPLAIN (COSTS OFF, VERBOSE)
DELETE FROM public.events WHERE ts < '2019-01-01'::timestamptz AND data -> 'k' = '{"b": 1}';
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET note = 'x' WHERE ts < '2019-01-01'::timestamptz AND data ? 'k';
EXPLAIN (COSTS OFF, VERBOSE)
INSERT INTO public.dv SELECT id, doc FROM public.src WHERE doc = '{"a": 1}';
DELETE FROM public.events WHERE ts < '2019-01-01'::timestamptz AND data > '9';
DELETE FROM public.events WHERE ts < '2019-01-01'::timestamptz AND data || '{}' = '{}';
DELETE FROM public.events WHERE ts < '2019-01-01'::timestamptz AND ARRAY[data] = ARRAY['{}'::jsonb];
-- The DuckDB statement names pg_duckdb's functions as DuckDB knows them,
-- whatever the session's search_path.
SET search_path = pg_catalog;
EXPLAIN (COSTS OFF, VERBOSE)
DELETE FROM public.events WHERE ts < '2019-01-01'::timestamptz AND data -> 'k' = '{"b": 1}';
RESET search_path;
-- The key or path of ?, ?|, ?& and #> in a cold write must be a constant: the
-- rewrite needs its value, and a cold write's parameters are bound as it runs.
PREPARE dk(text) AS DELETE FROM public.events WHERE ts < '2019-01-01'::timestamptz AND data ? $1;
-- On both tiers the hot half keeps PostgreSQL's comparison and the cold half gets
-- the rewrite; a move of the partition column reads its cold rows with the
-- rewritten condition.
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET note = 'x' WHERE id = 7 AND data = '{"a": 1}';
EXPLAIN (COSTS OFF, VERBOSE)
UPDATE public.events SET ts = ts + interval '1 day' WHERE data = '{"a": 1}';

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events, public.dv;
DROP TABLE public._events, public._dv, public.src;
DROP DOMAIN public.jdoc;
