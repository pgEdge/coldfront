-- Column-shape DDL on a tiered table is MIRRORED onto the cold Iceberg tier
-- (duckdb-iceberg v1.5 implements Iceberg ALTER): ADD/DROP COLUMN, ALTER COLUMN
-- TYPE and RENAME COLUMN evolve both tiers in one statement, serialized through
-- the bakery, and the view is rebuilt to the new column set. This white-box test
-- checks the hook's SQL/DDL, not Iceberg I/O (real cold I/O is ci/journey.sh;
-- see README.md), along the two axes observable without a live catalog:
--   1. Data-type correspondence is enforced up front: an unsupported column type
--      is rejected by coldfront._iceberg_storage_type BEFORE any Iceberg call,
--      rolling the hot-side ALTER back with it.
--   2. The Spock apply-worker path (session_replication_role = replica) mirrors
--      NOTHING to the shared catalog (the originator already did) but DOES rebuild
--      the per-node view to follow each column change. Running the positive cases
--      under 'replica' is what lets them complete with warehouse='' (no Iceberg).
-- RENAME TABLE / RENAME VIEW are covered by ddl_rename_*.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');

-- The rebuilt view keeps the grants and the owner the view had.
CREATE ROLE ddl_alter_reader;
CREATE ROLE ddl_alter_owner;
GRANT SELECT, INSERT ON public.events TO ddl_alter_reader;
ALTER VIEW public.events OWNER TO ddl_alter_owner;

-- 1. Unsupported column type is rejected up front (originator path), before any
--    Iceberg I/O; the hot ALTER rolls back with it, so _events is unchanged.
ALTER TABLE public._events ADD COLUMN bad inet;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public._events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- 2. Apply-worker path: the mirror is a no-op (the shared catalog was already
--    evolved by the originator), but the per-node view is rebuilt to follow every
--    column change. No live Iceberg needed.
SET session_replication_role = replica;

ALTER TABLE public._events ADD COLUMN cnt integer;        -- INTEGER (mirror skipped here); view gains cnt
ALTER TABLE public._events ALTER COLUMN cnt TYPE bigint;  -- INTEGER -> BIGINT safe promotion
ALTER TABLE public._events RENAME COLUMN cnt TO ctr;      -- column renamed on both tiers
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

ALTER TABLE public._events DROP COLUMN ctr;               -- dropped from both tiers
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

SET session_replication_role = DEFAULT;

SELECT has_table_privilege('ddl_alter_reader', 'public.events', 'SELECT') AS can_select,
       has_table_privilege('ddl_alter_reader', 'public.events', 'INSERT') AS can_insert,
       pg_get_userbyid(relowner) AS owner
  FROM pg_class WHERE oid = 'public.events'::regclass;

-- 3. Whoever PostgreSQL lets alter the hot table makes the change, with no
--    privilege on the view or its schema: the hook rebuilds the view as the
--    extension's owner and gives it back its owner and grants. The Iceberg
--    change runs as the caller, who needs the cold access grant_app_access
--    gives an application role (here USAGE on schema coldfront). A role holding
--    the owner's privileges without the SET ROLE an ownership change needs, a
--    role owning the hot table but not the view, and a role owning neither,
--    refused before anything changes.
CREATE ROLE ddl_alter_member;
CREATE ROLE ddl_alter_hot_owner;
GRANT ddl_alter_owner TO ddl_alter_member WITH INHERIT TRUE, SET FALSE;
GRANT USAGE ON SCHEMA coldfront TO ddl_alter_member, ddl_alter_hot_owner;
ALTER TABLE public._events OWNER TO ddl_alter_owner;
SET session_replication_role = replica;
SET ROLE ddl_alter_member;
ALTER TABLE public._events ADD COLUMN by_member integer;
RESET ROLE;
ALTER TABLE public._events OWNER TO ddl_alter_hot_owner;
SET ROLE ddl_alter_hot_owner;
ALTER TABLE public._events RENAME COLUMN by_member TO by_hot_owner;
RESET ROLE;
SET ROLE ddl_alter_reader;
ALTER TABLE public._events DROP COLUMN by_hot_owner;
RESET ROLE;
SET session_replication_role = DEFAULT;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;
SELECT has_table_privilege('ddl_alter_reader', 'public.events', 'SELECT') AS can_select,
       has_table_privilege('ddl_alter_reader', 'public.events', 'INSERT') AS can_insert,
       pg_get_userbyid(relowner) AS owner
  FROM pg_class WHERE oid = 'public.events'::regclass;

-- 4. The rebuild runs with search_path pinned to pg_catalog, pg_temp, so the
--    caller's temporary types take no part in it, though its functions are
--    compiled in the caller's session. A fresh session compiles them with the
--    caller's domain named text in place; the domain's CHECK reports any role
--    other than the caller it runs as.
\c
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';
SET session_replication_role = replica;
SET ROLE ddl_alter_hot_owner;
CREATE FUNCTION pg_temp.ran_as(pg_catalog.text) RETURNS pg_catalog.bool
LANGUAGE plpgsql AS $$
BEGIN
    IF current_user <> 'ddl_alter_hot_owner' THEN
        RAISE NOTICE 'the domain check ran as %', current_user;
    END IF;
    RETURN true;
END $$;
CREATE DOMAIN pg_temp.text AS pg_catalog.text CHECK (pg_temp.ran_as(VALUE));
ALTER TABLE public._events ADD COLUMN probed integer;
DROP DOMAIN pg_temp.text;
DROP FUNCTION pg_temp.ran_as(pg_catalog.text);
RESET ROLE;
SET session_replication_role = DEFAULT;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- 5. A non-tiered table's columns alter normally (control).
CREATE TABLE public.plain (id int, val text);
ALTER TABLE public.plain ADD COLUMN extra int;
ALTER TABLE public.plain DROP COLUMN val;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.plain'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;
DROP TABLE public.plain;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a registered
-- tiered table/view.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
REVOKE USAGE ON SCHEMA coldfront FROM ddl_alter_member, ddl_alter_hot_owner;
DROP ROLE ddl_alter_member;
DROP ROLE ddl_alter_hot_owner;
DROP ROLE ddl_alter_reader;
DROP ROLE ddl_alter_owner;
