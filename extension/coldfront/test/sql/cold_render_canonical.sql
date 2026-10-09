-- A value that leaves the caller's session as text reads back as the same
-- value whatever that session's DateStyle, IntervalStyle and extra_float_digits
-- are, and a cold interval is stored as ISO 8601 text. A tiered INSERT carries
-- a timestamp, an interval and a double to the cold tier through the stream
-- (its parameters, then its columns), through the sink, and a cold UPDATE
-- carries them as its parameters. Observed end to end: a DuckDB temporary
-- table stands in for the Iceberg table and is read back with duckdb.query.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SELECT set_config('coldfront.local_pg_dsn',
                  format('host=%s dbname=%s user=%s',
                         trim(split_part(current_setting('unix_socket_directories'), ',', 1)),
                         current_database(), current_user), false) <> '' AS dsn_set;
SELECT duckdb.raw_query('CREATE TEMP TABLE cf_canon (id BIGINT, ts TIMESTAMPTZ, iv VARCHAR, x DOUBLE)') IS NOT NULL AS created;

CREATE TABLE public._cf_canon (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL,
                               iv interval, x double precision);
CREATE VIEW public.cf_canon AS SELECT * FROM public._cf_canon;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'cf_canon', 'public._cf_canon', 'temp.main.cf_canon', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'cf_canon', '2026-03-15'::timestamptz);
CREATE TABLE public.cf_canon_src (tag text, ts timestamptz, iv interval, x double precision);
INSERT INTO public.cf_canon_src VALUES
    ('cold', '2026-03-01 08:00:00+00', '-1 days -02:03:04', 0.1::float8 + 0.2::float8),
    ('hot',  '2026-04-01 08:00:00+00', '1 year 2 mons -3 days 04:05:06.5', 1e-7);
CREATE VIEW public.cf_canon_cold AS
    SELECT r['ts']::timestamptz AS ts, r['iv']::text AS iv, r['x']::float8 AS x
      FROM duckdb.query('SELECT * FROM temp.main.cf_canon') AS t(r);

-- The caller's settings: day-first dates, SQL-standard intervals, and floats
-- printed with fewer digits than they hold.
SET DateStyle = 'SQL, DMY';
SET IntervalStyle = sql_standard;
SET extra_float_digits = -3;

-- (1) The stream's parameters.
PREPARE cf_canon_ins(timestamptz, interval, double precision) AS
    INSERT INTO public.cf_canon (ts, iv, x) VALUES ($1, $2, $3);
EXECUTE cf_canon_ins('2026-03-01 08:00:00+00', '-1 days -02:03:04', 0.1::float8 + 0.2::float8);

-- (2) The stream's columns.
INSERT INTO public.cf_canon (ts, iv, x) SELECT ts, iv, x FROM public.cf_canon_src WHERE tag = 'cold';

-- (3) The sink, for both.
SET coldfront.local_pg_dsn = '';
EXECUTE cf_canon_ins('2026-03-01 08:00:00+00', '-1 days -02:03:04', 0.1::float8 + 0.2::float8);
INSERT INTO public.cf_canon (ts, iv, x) SELECT ts, iv, x FROM public.cf_canon_src;

-- Every cold row holds the values the caller gave, the interval in the
-- canonical shape. The rows are copied to a heap table first, so the checks
-- run in PostgreSQL: pg_duckdb renders a query's interval literal in the
-- session's IntervalStyle, which DuckDB does not read.
CREATE TEMP TABLE cf_canon_got AS SELECT * FROM public.cf_canon_cold;
SELECT ts = '2026-03-01 08:00:00+00'::timestamptz AS ts_kept, iv,
       iv::interval = interval '-1 days -02:03:04' AS iv_kept,
       x = 0.1::float8 + 0.2::float8 AS x_kept
  FROM cf_canon_got ORDER BY 1, 2, 3, 4;
SELECT count(*) AS hot_rows FROM public._cf_canon;

-- (4) A cold UPDATE's parameters: the interval it sets and the timestamp it
--     matches on.
PREPARE cf_canon_upd(interval, timestamptz) AS UPDATE public.cf_canon SET iv = $1 WHERE ts = $2;
EXECUTE cf_canon_upd('1 year 2 mons -3 days 04:05:06.5', '2026-03-01 08:00:00+00');
SELECT iv, count(*) FROM public.cf_canon_cold GROUP BY iv ORDER BY iv;

RESET DateStyle;
RESET IntervalStyle;
RESET extra_float_digits;

-- The interval shape is the one DuckDB 1.5.4 reads. When its INTERVAL cast
-- takes an ISO 8601 duration, this stops failing and the shape can become
-- ISO 8601.
SELECT duckdb.raw_query('SELECT ''PT2H''::INTERVAL');
