-- Parity / drift guard for normalize_casts_for_duckdb. Two halves:
--   (A) white-box: a cold UPDATE whose casts + jsonb functions exercise the
--       normalizer; EXPLAIN VERBOSE shows the rewritten cold SQL carries the DuckDB
--       spellings (::timestamp/::varchar/::double, json_object/json_set, ::json),
--       the timestamptz bound, and the evt_jsonb identifier left intact.
--   (B) parity: DuckDB itself rejects `jsonb` (so ::jsonb→::json is required) but
--       accepts the rewrite targets. If a future DuckDB changes what it accepts,
--       or a new storage type needs a rewrite, this surfaces it.
-- White-box: we do NOT exercise Iceberg I/O.

-- Suppress NOTICEs: raw_query echoes each DuckDB result as a (version-dependent)
-- NOTICE, and CREATE EXTENSION emits "already exists" depending on suite order.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

-- evt_jsonb's name embeds "jsonb": it must survive the jsonb→json rewrite intact.
CREATE TABLE public._events (id int, ts timestamptz, c_tsn timestamp,
                             c_vc varchar, c_dp double precision, evt_jsonb jsonb);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- (A) Cold UPDATE (ts < cutoff): the deparsed cold SQL must carry DuckDB spellings.
-- Casts: timestamp without time zone → timestamp, character varying → varchar,
-- double precision → double; the timestamptz bound stays timestamptz. jsonb → json
-- everywhere: ::jsonb → ::json, jsonb_set → json_set, jsonb_build_object →
-- json_object — but the column name evt_jsonb (jsonb embedded) is left intact.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events
  SET c_tsn     = '2020-06-01 00:00:00'::timestamp without time zone,
      c_vc      = 'x'::character varying,
      c_dp      = 1.5::double precision,
      evt_jsonb = jsonb_set(jsonb_build_object('k', 1), '{x}', '"v"'::jsonb)
  WHERE ts < '2019-01-01'::timestamp with time zone;

-- (B) Parity against the live DuckDB: the rewrite targets are accepted; `jsonb`
-- is rejected (which is why the map rewrites it). A void row = accepted.
SELECT duckdb.raw_query($$ SELECT NULL::json $$);
SELECT duckdb.raw_query($$ SELECT json_object('k', 1) $$);
SELECT duckdb.raw_query($$ SELECT NULL::timestamp $$);
SELECT duckdb.raw_query($$ SELECT NULL::varchar $$);
SELECT duckdb.raw_query($$ SELECT NULL::double $$);
SELECT duckdb.raw_query($$ SELECT NULL::jsonb $$);

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
