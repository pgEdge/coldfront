-- COPY FROM on a tiered view goes through the hook's INSERT rewrite: the
-- utility hook reads the rows with PostgreSQL's COPY reader and writes each
-- batch of cold_write_batch_size rows as an INSERT into the view, so the
-- routing, the claim, the identity values and the defaults are the INSERT's.
-- White-box: hot rows only, since the regress server has no warehouse; cold
-- rows and batch boundaries are ci/journey.sh's.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared
-- regress db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

CREATE TABLE public._events (
    id     bigint GENERATED ALWAYS AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'new',
    n      int DEFAULT 7
);
CREATE VIEW public.events AS SELECT id, ts, status, n FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- Omitted columns take the hot table's identity and default values.
COPY public.events (ts) FROM stdin;
2026-04-01 00:00:00+00
2026-04-02 00:00:00+00
\.
-- A supplied identity value is kept, as COPY into the table itself keeps it,
-- and the format options are the reader's.
COPY public.events (id, ts, status, n) FROM stdin WITH (FORMAT csv, HEADER);
id,ts,status,n
100,2026-04-03 00:00:00+00,csv,1
\.
SELECT id, ts, status, n FROM public._events ORDER BY id;

-- Options the rewrite cannot honour are refused, not ignored. The refused
-- statements read a file rather than stdin: after a refused COPY FROM stdin,
-- psql 18 consumes the data terminator and psql 17 reports it as a command.
COPY public.events (ts) FROM '/dev/null' WHERE ts > '2026-01-01';
COPY public.events (ts) FROM '/dev/null' WITH (FREEZE);

-- A view without a registry row stays PostgreSQL's business.
CREATE VIEW public.plain_v AS SELECT 1 AS a;
COPY public.plain_v FROM '/dev/null';
-- Reads through COPY are untouched.
COPY (SELECT id, status FROM public.events ORDER BY id) TO stdout;

-- Cleanup.
DROP VIEW public.plain_v;
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
