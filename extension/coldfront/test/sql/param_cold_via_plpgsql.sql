-- Cause 1 (params -> DuckDB): a cold-tier write carrying bound parameters ($N)
-- — from PREPARE/EXECUTE, the extended protocol, or a plpgsql variable — must
-- keep those params LIVE. Before the fix the deparsed cold SQL baked "$N" into a
-- string literal DuckDB could not bind ("Expected N parameters, but none were
-- supplied"). The fix emits the cold SQL as a runtime format(<template>, $1, …)
-- call, so PG binds the values at execution and DuckDB only ever sees finished
-- literals.
--
-- White-box: asserts the TOP-LEVEL rewrite via EXPLAIN VERBOSE (no Iceberg I/O —
-- warehouse/endpoint left ''). A PREPARE with declared types produces the same
-- PARAM_EXTERN node shape a driver's bind params or a plpgsql variable would;
-- force_generic_plan keeps $N from folding to Consts so the format() call stays
-- visible. The in-plpgsql DML statement shape (Cause 2, the dummy-DML carrier)
-- only triggers when actually executing inside plpgsql, so it is covered by the
-- live journey (ci/journey.sh story 6c/6b'), not here.

-- Suppress the run-order-dependent "already exists" NOTICE: in the shared
-- regress db an earlier test may have created the extensions, standalone not —
-- either way the captured output must be the same.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET plan_cache_mode = force_generic_plan;   -- keep $N live (no const-folding)

CREATE TABLE public._events (id int, ts timestamptz, status text, data bytea);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- (1) pure-cold UPDATE (literal cold predicate), param in SET: the cold call's
-- SQL arg must be a format(...) call with a %N$L spec + a LIVE $1 arg, NOT a
-- literal with a baked $1.
PREPARE cold_upd(text) AS
  UPDATE public.events SET status = $1 WHERE ts < '2026-03-01';
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE cold_upd('x');

-- (2) pure-cold DELETE, param in WHERE alongside the literal cold predicate.
PREPARE cold_del(text) AS
  DELETE FROM public.events WHERE ts < '2026-03-01' AND status = $1;
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE cold_del('x');

-- (3) reordered params: $2 appears first (SET), $1 second (WHERE) -> positional
-- %N$L; the format arg list is the distinct params in first-seen order ($2,$1).
PREPARE cold_rep(text, text) AS
  UPDATE public.events SET status = $2 WHERE ts < '2026-03-01' AND status = $1;
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE cold_rep('a', 'b');

-- (4) bytea param -> from_hex(%N$L) placeholder with an encode($K,'hex') arg.
PREPARE cold_bytea(bytea) AS
  UPDATE public.events SET data = $1 WHERE ts < '2026-03-01';
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE cold_bytea('\xcafe'::bytea);

-- (5) a literal % in the SQL must be doubled to %% so format() passes it through.
PREPARE cold_like(text) AS
  UPDATE public.events SET status = 'pct%done' WHERE ts < '2026-03-01' AND status = $1;
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE cold_like('x');

-- (6) dual-tier (ambiguous predicate on a non-partition column) with a param:
-- the cold CTE leg uses format(...); the hot CTE leg keeps native $1.
PREPARE dual_upd(text) AS
  UPDATE public.events SET status = $1 WHERE id = 1;
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE dual_upd('x');

-- (7) no-param regression guard: a literal cold UPDATE must STILL bake a plain
-- literal (no format()) in the plain SELECT shape — byte-identical to the
-- bakery_wraps_cold_writes baseline.
EXPLAIN (COSTS OFF, VERBOSE)
  UPDATE public.events SET status = 'x' WHERE ts < '2026-03-01';

-- (8) slow tiered-INSERT: hot table has an IDENTITY column the INSERT omits, so
-- the cold half runs through coldfront._tiered_insert_cold, whose source SQL is
-- executed by a PostgreSQL cursor (NOT DuckDB). A bytea param there must render
-- GUC-independently as decode(%N$L,'hex') / encode($N,'hex') — not a plain %L,
-- which would be quoted under the session's bytea_output and corrupt under
-- bytea_output='escape'.
CREATE TABLE public._eid (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz, data bytea);
CREATE VIEW public.eid AS SELECT * FROM public._eid;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'eid', 'public._eid', 'ice.default.eid', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'eid', '2026-03-01'::timestamptz);
PREPARE eid_ins(timestamptz, bytea) AS INSERT INTO public.eid (ts, data) VALUES ($1, $2);
EXPLAIN (COSTS OFF, VERBOSE) EXECUTE eid_ins('2026-01-10 00:00+00', '\xcafe'::bytea);

DEALLOCATE cold_upd;
DEALLOCATE cold_del;
DEALLOCATE cold_rep;
DEALLOCATE cold_bytea;
DEALLOCATE cold_like;
DEALLOCATE dual_upd;
DEALLOCATE eid_ins;
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
DROP VIEW public.eid;
DROP TABLE public._eid;
