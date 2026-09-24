-- coldfront.tiered_views.is_writable arms the DML rewrite. A table adopted from
-- an existing Iceberg catalog is registered read-only unless the caller asked
-- for writes, so reading someone else's lake table cannot turn into writing it
-- by accident. The check lives in the parse-analyze hook, one refusal covering
-- INSERT, UPDATE and DELETE alike.
--
-- Every other registration keeps the column's default of true: the archiver's
-- upsert and create_iceberg_table both own their Iceberg table outright.
--
-- White-box: registry rows are inserted by hand, and no Iceberg I/O happens.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.local_pg_dsn = '';

-- A row written without naming the column is writable, so no existing registry
-- row changes meaning.
CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
SELECT is_writable AS tiered_default FROM coldfront.tiered_views WHERE relname = 'events';

-- The adopted read-only shape: a decoupled registration the caller did not arm.
CREATE TABLE public._orders_src (order_id bigint, customer text, amount numeric(12,2));
CREATE VIEW public.orders AS SELECT * FROM public._orders_src;
INSERT INTO coldfront.tiered_views(schema_name, relname, iceberg_table, is_iceberg_only, is_writable)
VALUES ('public', 'orders', 'ice.lake.orders', true, false);

-- Reads are the whole point of adopting, so they are untouched.
SELECT count(*) AS read_ok FROM public.orders;

-- All three verbs are refused, with the same message and the same hint.
INSERT INTO public.orders VALUES (1, 'acme', 19.99);
UPDATE public.orders SET amount = 0 WHERE order_id = 1;
DELETE FROM public.orders WHERE order_id = 1;

-- Arming the row lifts the refusal: the DML reaches the cold rewrite instead.
UPDATE coldfront.tiered_views SET is_writable = true
 WHERE schema_name = 'public' AND relname = 'orders';
EXPLAIN (COSTS OFF, VERBOSE) DELETE FROM public.orders WHERE order_id = 1;

-- An unregistered view is not the hook's business, armed or not.
CREATE VIEW public.plain AS SELECT * FROM public._orders_src;
UPDATE public.plain SET amount = 0 WHERE order_id = 1;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.plain;
DROP VIEW public.orders;
DROP TABLE public._orders_src;
DROP VIEW public.events;
DROP TABLE public._events;
