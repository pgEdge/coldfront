-- A bound parameter carrying an embedding into a cold write. The view exposes the
-- column as real[], so that is the parameter's type by the time the rewrite sees
-- it, and %L would spell it PG's way ({1,2,3}) which DuckDB's list cast rejects.
--
-- White-box, like param_cold_via_plpgsql: EXPLAIN VERBOSE shows the rewritten cold
-- SQL and nothing touches Iceberg (warehouse/endpoint left ''). force_generic_plan
-- keeps $N from folding to a Const so the format() call stays visible.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;
RESET client_min_messages;

SET TIME ZONE 'UTC';
-- The cold SQL embeds the cutoff as a literal, so its spelling follows DateStyle.
-- Pin it for the same reason the timezone is pinned: the assertion is the rewrite,
-- not the session's formatting.
SET DateStyle = 'ISO, MDY';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET plan_cache_mode = force_generic_plan;

CREATE TABLE public._chunks (id int, ts timestamptz, embedding vector(3));
CREATE VIEW public.chunks AS SELECT id, ts, embedding::real[] AS embedding FROM public._chunks;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'chunks', 'public._chunks', 'ice.default.chunks', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'chunks', '2026-03-01'::timestamptz);

-- The parameter must reach DuckDB as CAST(%1$L AS FLOAT[]) with a
-- translate($1::text,'{}','[]') argument.
PREPARE cold_vec(real[]) AS
  UPDATE public.chunks SET embedding = $1 WHERE ts < '2026-03-01';
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE cold_vec('{1,2,3}'::real[]);

-- Cleanup: this suite shares one database. Unregister first, since DROP on a
-- table that still has a registered cold tier is blocked by design.
DEALLOCATE cold_vec;
DELETE FROM coldfront.tiered_views WHERE relname = 'chunks';
DELETE FROM coldfront.archive_watermark WHERE table_name = 'chunks';
DROP VIEW public.chunks;
DROP TABLE public._chunks;
