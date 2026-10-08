-- A tiered INSERT whose source the hook can read a second time from another
-- session streams its cold rows: the hot half is a set-based INSERT and the
-- cold half is one DuckDB INSERT ... SELECT FROM postgres_query('pgstream', ...)
-- through coldfront._exec_iceberg_with_claim, with the identity values and the
-- defaults drawn in that session. Observed end to end: a DuckDB temporary table
-- stands in for the Iceberg table and is read back with duckdb.query. A source
-- the hook cannot read twice (a volatile or stable function, a temporary table,
-- a WITH entry, a view over one, a table this transaction wrote, a transaction
-- that is not READ COMMITTED, no local_pg_dsn) goes through the cold sink in one
-- pass, and a cached plan that meets such a transaction falls back inside the
-- stream.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
-- The regress database is not the one the image's local_pg_dsn names.
SELECT set_config('coldfront.local_pg_dsn',
                  format('host=%s dbname=%s user=%s',
                         trim(split_part(current_setting('unix_socket_directories'), ',', 1)),
                         current_database(), current_user), false) <> '' AS dsn_set;
SELECT duckdb.raw_query('CREATE TEMP TABLE cf_stream (id BIGINT, ts TIMESTAMPTZ, status VARCHAR, n INTEGER, data VARCHAR, b BLOB, tags INTEGER[])') IS NOT NULL AS created;

CREATE TABLE public._cf_stream (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL,
                                status text NOT NULL DEFAULT 'new', n int DEFAULT 7,
                                data jsonb, b bytea, tags int[]);
CREATE VIEW public.cf_stream AS SELECT * FROM public._cf_stream;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'cf_stream', 'public._cf_stream', 'temp.main.cf_stream', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'cf_stream', '2026-03-01'::timestamptz);
CREATE TABLE public.cf_staging (ts timestamptz, status text, data jsonb, b bytea, tags int[]);
INSERT INTO public.cf_staging VALUES
    ('2026-01-01', 'cold1', '{"a": 1}', '\xcafe', '{1,2}'),
    ('2026-02-01', 'cold2', NULL, NULL, NULL),
    ('2026-05-01', 'hot1', '{}', '\xbeef', '{3}');

-- The rows of each tier, without the ids, which the two halves draw from one
-- sequence in no fixed order. The cold read runs in DuckDB, so the two reads
-- are separate views.
CREATE VIEW public.cf_stream_hot AS
    SELECT ts, status, n, data::text AS data, b, tags FROM public._cf_stream;
CREATE VIEW public.cf_stream_cold AS
    SELECT r['ts']::timestamptz AS ts, r['status']::text AS status, r['n']::int AS n,
           r['data']::text AS data, r['b']::bytea AS b, r['tags']::int[] AS tags
      FROM duckdb.query('SELECT * FROM temp.main.cf_stream') AS t(r);
CREATE VIEW public.cf_stream_ids AS
    SELECT count(*) AS rows, count(DISTINCT id) AS ids, min(id) AS min_id, max(id) AS max_id
      FROM (SELECT id FROM public._cf_stream
            UNION ALL
            SELECT r['id']::bigint FROM duckdb.query('SELECT id FROM temp.main.cf_stream') AS t(r)) AS u;

-- (1) A SELECT source over a table: the hot row goes to the heap, the two cold
--     rows stream, every column type lands as the sink would store it, and
--     the omitted identity and default columns are filled on both tiers.
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status, data, b, tags)
  SELECT ts, status, data, b, tags FROM public.cf_staging;
INSERT INTO public.cf_stream (ts, status, data, b, tags)
SELECT ts, status, data, b, tags FROM public.cf_staging;
SELECT * FROM public.cf_stream_hot ORDER BY ts;
SELECT * FROM public.cf_stream_cold ORDER BY ts;
SELECT * FROM public.cf_stream_ids;

-- (2) A VALUES source: the cold test is the hot count against the row count.
--     With a cold row DuckDB writes (and reports it); with none it is never
--     called, so an all-hot INSERT stages nothing.
SET client_min_messages = notice;
INSERT INTO public.cf_stream (ts, status) VALUES ('2026-01-10', 'cold3'), ('2026-06-10', 'hot2');
INSERT INTO public.cf_stream (ts, status) VALUES ('2026-06-11', 'hot3'), ('2026-06-12', 'hot4');
SET client_min_messages = warning;
SELECT status FROM public.cf_stream_hot WHERE status IN ('hot2', 'hot3', 'hot4') ORDER BY status;
SELECT status FROM public.cf_stream_cold WHERE status = 'cold3';

-- (3) OVERRIDING SYSTEM VALUE supplies the identity on both tiers.
INSERT INTO public.cf_stream (id, ts, status) OVERRIDING SYSTEM VALUE
VALUES (901, '2026-01-11', 'ovr_cold'), (902, '2026-06-13', 'ovr_hot');
SELECT * FROM public.cf_stream_ids;

-- (4) A prepared statement with a bound parameter streams from its cached plan
--     and keeps the parameter live. Run again in a transaction that wrote the
--     source table, the stream's check falls back to reading in this session,
--     so the row written in the transaction is tiered too.
PREPARE cf_prep(text) AS
  INSERT INTO public.cf_stream (ts, status) SELECT ts, $1 FROM public.cf_staging WHERE ts < '2026-03-01';
EXECUTE cf_prep('prep1');
BEGIN;
INSERT INTO public.cf_staging VALUES ('2026-01-20', 'cold4', NULL, NULL, NULL);
EXECUTE cf_prep('prep2');
COMMIT;
BEGIN ISOLATION LEVEL REPEATABLE READ;
EXECUTE cf_prep('prep3');
COMMIT;
SELECT status, count(*) FROM public.cf_stream_cold WHERE status LIKE 'prep%' GROUP BY status ORDER BY status;

-- (5) COPY into the view goes through the same rewrite, batch by batch.
SET coldfront.cold_write_batch_size = 2;
COPY public.cf_stream (ts, status) FROM stdin WITH (FORMAT csv);
2026-01-21 00:00:00+00,copy_cold
2026-01-22 00:00:00+00,copy_cold
2026-01-23 00:00:00+00,copy_cold
2026-06-21 00:00:00+00,copy_hot
\.
RESET coldfront.cold_write_batch_size;
SELECT status, count(*) FROM public.cf_stream_hot WHERE status LIKE 'copy%' GROUP BY status;
SELECT status, count(*) FROM public.cf_stream_cold WHERE status LIKE 'copy%' GROUP BY status;

-- (6) Sources the hook sends to the sink in one pass: a volatile function, a
--     stable one, a temporary table, a WITH entry, a view that calls a stable
--     function, a table this transaction wrote, a transaction that is not READ
--     COMMITTED, and a session without local_pg_dsn.
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status) SELECT ts, random()::text FROM public.cf_staging;
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status) VALUES (now() - interval '1 year', 'stable');
CREATE TEMP TABLE cf_tmp (ts timestamptz, status text);
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status) SELECT ts, status FROM cf_tmp;
EXPLAIN (COSTS OFF, VERBOSE)
  WITH s AS (SELECT ts, status FROM public.cf_staging)
  INSERT INTO public.cf_stream (ts, status) SELECT ts, status FROM s;
CREATE VIEW public.cf_now_view AS SELECT now() AS ts, status FROM public.cf_staging;
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status) SELECT ts, status FROM public.cf_now_view;
BEGIN;
INSERT INTO public.cf_staging VALUES ('2026-01-30', 'cold5', NULL, NULL, NULL);
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status) SELECT ts, status FROM public.cf_staging;
INSERT INTO public.cf_stream (ts, status) SELECT ts, 'txn' FROM public.cf_staging WHERE status = 'cold5';
COMMIT;
BEGIN ISOLATION LEVEL REPEATABLE READ;
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status) SELECT ts, status FROM public.cf_staging;
COMMIT;
SET coldfront.local_pg_dsn = '';
EXPLAIN (COSTS OFF, VERBOSE)
  INSERT INTO public.cf_stream (ts, status) SELECT ts, status FROM public.cf_staging;
SELECT status FROM public.cf_stream_cold WHERE status = 'txn';
SELECT * FROM public.cf_stream_ids;

-- Cleanup.
DEALLOCATE cf_prep;
DROP VIEW public.cf_now_view, public.cf_stream_hot, public.cf_stream_cold, public.cf_stream_ids;
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.cf_stream;
DROP TABLE public._cf_stream, public.cf_staging, cf_tmp;
RESET coldfront.local_pg_dsn;
