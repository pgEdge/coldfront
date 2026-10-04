-- RENAME of the transparent VIEW must migrate its name-keyed reference,
-- coldfront.archive_watermark.table_name (the bare view name in its (schema, table) key).
-- Without the watermark migration the rebuilt view would silently lose its
-- cold (Iceberg) UNION branch — the watermark lookup would miss, v_has_cutoff
-- would be false, and only the hot branch would remain.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
-- White-box: checks the hooks' SQL/DDL, not Iceberg I/O. Real cold I/O is ci/journey.sh; see README.md.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
-- A watermark exists, so the rebuilt view must keep its cold UNION branch.
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'events', '2026-03-01'::timestamptz);

-- Before: the view definition has the cold branch, a catalog read.
SELECT pg_get_viewdef('public.events'::regclass) LIKE '%duckdb.query(%' AS has_cold_branch;

-- Rename the view.
ALTER VIEW public.events RENAME TO events_v2;

-- The watermark row followed the rename (its table_name is the new bare view name).
SELECT table_name FROM coldfront.archive_watermark ORDER BY table_name;

-- The rebuilt view under the new name STILL has the cold UNION branch
-- (watermark lookup matched the new name).
SELECT pg_get_viewdef('public.events_v2'::regclass) LIKE '%duckdb.query(%' AS has_cold_branch;

-- The registry relname migrated to the new view name (name-keyed).
SELECT (schema_name = 'public' AND relname = 'events_v2') AS registry_points_at_new_view,
       hot_table, partition_col
  FROM coldfront.tiered_views;

-- The view's owner renames it with no access to schema coldfront, holding only
-- the CREATE on the schema that PostgreSQL requires for a rename: the hook
-- migrates the registry and watermark rows and rebuilds the view as the
-- extension's owner, which gives the view back to that owner.
CREATE ROLE ddl_rename_view_owner;
GRANT CREATE ON SCHEMA public TO ddl_rename_view_owner;
ALTER VIEW public.events_v2 OWNER TO ddl_rename_view_owner;
SET ROLE ddl_rename_view_owner;
ALTER VIEW public.events_v2 RENAME TO events_v3;
RESET ROLE;
SELECT relname, (SELECT table_name FROM coldfront.archive_watermark) AS watermark,
       pg_get_userbyid((SELECT relowner FROM pg_class
                        WHERE oid = 'public.events_v3'::regclass)) AS view_owner
  FROM coldfront.tiered_views;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events_v3;
DROP TABLE public._events;
REVOKE CREATE ON SCHEMA public FROM ddl_rename_view_owner;
DROP ROLE ddl_rename_view_owner;
