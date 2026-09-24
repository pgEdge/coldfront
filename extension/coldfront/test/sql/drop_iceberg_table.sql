-- coldfront.drop_iceberg_table drops the Iceberg table backing a registered
-- relation, in either mode. Decoupled: the relation is the Iceberg table, so
-- nothing is left. Tiered: the Iceberg table is the cold tier, so the cold tier
-- goes and the hot table returns under its original name. Whether the Parquet
-- and metadata objects are also deleted is the caller's explicit decision
-- (p_purge), never a default.
--
-- White-box: checks the emitted DDL and the PG-side teardown, not Iceberg I/O.
-- Real cold I/O (that purge deletes objects and keep-files does not) is
-- ci/journey.sh; see README.md.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = 'wh';
SET coldfront.lakekeeper_endpoint = 'http://lk:8181/catalog';
SET coldfront.dblink_self = '';

-- The emitted DDL is built from the stored iceberg_table ref, which is the only
-- thing that names the right catalog table: an adopted relation's namespace is
-- whatever the caller adopted from, not its PG schema.
-- purge=true arms PURGE_REQUESTED on a scoped attachment: Lakekeeper deletes the
-- data and metadata objects.
SELECT coldfront._iceberg_drop_sql('ice.public.iceonly', true);

-- purge=false needs no attachment of its own: the everyday 'ice' attachment is
-- never purge-armed, so the drop goes straight through it and the objects stay
-- in the bucket, so the ref goes through as it is stored.
SELECT coldfront._iceberg_drop_sql('ice.public.iceonly', false);

-- The archiver quotes every part of the ref it stores and this SQL path quotes
-- only what needs it; both parse to the same three identifiers.
SELECT coldfront._iceberg_drop_sql('"ice"."public"."iceonly"', true);

-- Identifiers are re-quoted on the way out, so mixed case and embedded quotes
-- cannot break out.
SELECT coldfront._iceberg_drop_sql(format('ice.%I.%I', 'My Schema', 'Odd"Name'), true);

-- An unregistered table is refused (nothing to unregister; no blind catalog drop).
SELECT coldfront.drop_iceberg_table('public', 'nosuch', true);

-- The purge decision is mandatory: NULL is not a silent "false".
CREATE VIEW public.iceonly AS SELECT 1 AS id;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col, is_iceberg_only)
VALUES ('public', 'iceonly', NULL, 'ice.public.iceonly', NULL, true);

SELECT coldfront.drop_iceberg_table('public', 'iceonly', NULL);

-- Read access carries no authority to destroy: a relation adopted read-only is
-- refused before anything is unregistered.
UPDATE coldfront.tiered_views SET is_writable = false
 WHERE schema_name = 'public' AND relname = 'iceonly';
SELECT coldfront.drop_iceberg_table('public', 'iceonly', false);
UPDATE coldfront.tiered_views SET is_writable = true
 WHERE schema_name = 'public' AND relname = 'iceonly';

-- One relation per Iceberg ref. _vec_list_cols_for_ref and _vec_list_prefix_for_ref
-- look the registry up by ref, so a second row on the same ref would make the
-- first concatenate two tables' cluster columns and the second fail outright.
CREATE VIEW public.iceonly_again AS SELECT 1 AS id;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col, is_iceberg_only)
VALUES ('public', 'iceonly_again', NULL, 'ice.public.iceonly', NULL, true);
DROP VIEW public.iceonly_again;

-- Decoupled teardown: the registry row and the wrapper view both go.
SELECT coldfront._unregister_iceberg('public', 'iceonly');
SELECT count(*) AS registry_rows FROM coldfront.tiered_views WHERE relname = 'iceonly';
SELECT count(*) AS view_left FROM pg_class WHERE relname = 'iceonly';

-- Tiered teardown: the archiver's first run renamed events to _events and put a
-- view in its place, so un-tiering reverses that. Every registration row goes
-- (partition_config too, or the next archiver run re-tiers into a dropped
-- catalog entry), and the hot table returns under its original name.
CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.partition_config(schema_name, table_name, partition_period, hot_period)
VALUES ('public', 'events', 'monthly', '30 days');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-01-01 00:00:00+00');

SELECT coldfront._unregister_iceberg('public', 'events');

SELECT count(*) AS tiered_views_rows    FROM coldfront.tiered_views    WHERE relname    = 'events';
SELECT count(*) AS partition_config_rows FROM coldfront.partition_config WHERE table_name = 'events';
SELECT count(*) AS watermark_rows        FROM coldfront.archive_watermark WHERE table_name = 'events';
-- events is a plain table again (relkind r, not v), and _events is gone.
SELECT relname, relkind FROM pg_class
 WHERE relname IN ('events', '_events') AND relnamespace = 'public'::regnamespace
 ORDER BY relname;

-- Unregistering something that was never registered is refused.
SELECT coldfront._unregister_iceberg('public', 'nosuch');

-- Cleanup.
DROP TABLE public.events;
