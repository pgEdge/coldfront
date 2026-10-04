-- Column changes on a decoupled table: the DDL hook applies each to the Iceberg
-- table through the bakery and rebuilds the wrapper view from its current
-- columns plus the change, keeping the view's grants and owner. White-box like
-- ddl_alter_column: under the apply-worker role the Iceberg step is skipped, so
-- the rebuild runs with no live catalog; ci/journey.sh runs the cold tier.

SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;
RESET client_min_messages;

SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

SELECT coldfront._register_iceberg_view('public', 'dk', '"ice"."default"."dk"',
    '[{"name": "id", "cast": "bigint"}, {"name": "qty", "cast": "integer"},
      {"name": "amount", "cast": "numeric(10,2)"}, {"name": "doc", "cast": "json"}]', '{}', true);
CREATE ROLE dk_reader;
CREATE ROLE dk_owner;
GRANT SELECT, INSERT ON public.dk TO dk_reader;
ALTER VIEW public.dk OWNER TO dk_owner;

-- The four column changes, under the apply-worker role.
SET session_replication_role = replica;
ALTER TABLE public.dk ADD COLUMN note text;
ALTER TABLE public.dk RENAME COLUMN note TO memo;
ALTER TABLE public.dk ALTER COLUMN qty TYPE bigint;
ALTER TABLE public.dk ALTER COLUMN amount TYPE numeric(12,2);
SELECT attname, format_type(atttypid, atttypmod) AS type FROM pg_attribute
 WHERE attrelid = 'public.dk'::regclass AND attnum > 0 ORDER BY attnum;
SELECT pg_get_viewdef('public.dk'::regclass);
ALTER TABLE public.dk DROP COLUMN memo;
-- Column changes share a statement.
ALTER TABLE public.dk ADD COLUMN a1 text, ADD COLUMN a2 date;
SELECT string_agg(attname, ', ' ORDER BY attnum) AS columns FROM pg_attribute
 WHERE attrelid = 'public.dk'::regclass AND attnum > 0;
ALTER TABLE public.dk DROP COLUMN a1, DROP COLUMN a2;
SET session_replication_role = DEFAULT;
SELECT attname, format_type(atttypid, atttypmod) AS type FROM pg_attribute
 WHERE attrelid = 'public.dk'::regclass AND attnum > 0 ORDER BY attnum;

-- The view keeps its grants, its owner and its registration.
SELECT has_table_privilege('dk_reader', 'public.dk', 'SELECT') AS can_select,
       has_table_privilege('dk_reader', 'public.dk', 'INSERT') AS can_insert,
       pg_get_userbyid(relowner) AS owner
  FROM pg_class WHERE oid = 'public.dk'::regclass;
SELECT iceberg_table, is_iceberg_only, is_writable, vec_columns
  FROM coldfront.tiered_views WHERE schema_name = 'public' AND relname = 'dk';

-- What an Iceberg column cannot take is refused, as is a type with no mapping
-- and a statement that mixes a column change with another change.
ALTER TABLE public.dk ADD COLUMN fee numeric(10,2) DEFAULT 0;
ALTER TABLE public.dk ADD COLUMN fee numeric(10,2) NOT NULL;
ALTER TABLE public.dk ADD COLUMN label text COLLATE "C";
ALTER TABLE public.dk ADD COLUMN label text STORAGE EXTERNAL;
ALTER TABLE public.dk ALTER COLUMN amount TYPE numeric(14,2) USING amount * 2;
ALTER TABLE public.dk ADD COLUMN fee numeric(10,2), ALTER COLUMN qty SET DEFAULT 0;
ALTER TABLE public.dk ADD COLUMN ip inet;

-- Only the view's owner changes its columns, as with any ALTER TABLE.
SET ROLE dk_reader;
ALTER TABLE public.dk ADD COLUMN note text;
ALTER TABLE public.dk RENAME COLUMN qty TO quantity;
RESET ROLE;

-- A role holding the owner's privileges makes the change without the SET ROLE
-- on the owner that giving the rebuilt view back would need as that role: the
-- rebuild runs as the extension's owner. The Iceberg change runs as the
-- caller, who needs the cold access grant_app_access gives an application role
-- (here USAGE on schema coldfront and SELECT on the registry).
CREATE ROLE dk_member;
GRANT dk_owner TO dk_member WITH INHERIT TRUE, SET FALSE;
GRANT USAGE ON SCHEMA coldfront TO dk_member;
GRANT SELECT ON coldfront.tiered_views TO dk_member;
SET session_replication_role = replica;
SET ROLE dk_member;
ALTER TABLE public.dk ADD COLUMN note text;
ALTER TABLE public.dk RENAME COLUMN note TO memo;
ALTER TABLE public.dk DROP COLUMN memo;
RESET ROLE;
SET session_replication_role = DEFAULT;
REVOKE SELECT ON coldfront.tiered_views FROM dk_member;
REVOKE USAGE ON SCHEMA coldfront FROM dk_member;
SELECT has_table_privilege('dk_reader', 'public.dk', 'SELECT') AS can_select,
       has_table_privilege('dk_reader', 'public.dk', 'INSERT') AS can_insert,
       pg_get_userbyid(relowner) AS owner
  FROM pg_class WHERE oid = 'public.dk'::regclass;

-- A vector column is neither added nor changed.
ALTER TABLE public.dk ADD COLUMN v vector(3);
ALTER TABLE public.dk ALTER COLUMN qty TYPE vector(3);
SELECT coldfront._register_iceberg_view('public', 'dkv', '"ice"."default"."dkv"',
    '[{"name": "id", "cast": "bigint"}, {"name": "emb", "cast": "real[]"}]', '{emb}', true);
ALTER TABLE public.dkv DROP COLUMN emb;
ALTER TABLE public.dkv RENAME COLUMN emb TO emb2;
ALTER TABLE public.dkv ALTER COLUMN emb TYPE real[];

-- A read-only table refuses every column change.
SELECT coldfront._register_iceberg_view('public', 'dkr', '"ice"."default"."dkr"',
    '[{"name": "id", "cast": "bigint"}]', '{}', false);
ALTER TABLE public.dkr ADD COLUMN note text;
ALTER TABLE public.dkr RENAME COLUMN id TO ident;

-- Nothing refused changed a view.
SELECT attrelid::regclass AS view, string_agg(attname, ', ' ORDER BY attnum) AS columns
  FROM pg_attribute WHERE attrelid IN ('public.dk'::regclass, 'public.dkv'::regclass, 'public.dkr'::regclass)
   AND attnum > 0
 GROUP BY attrelid ORDER BY 1;

-- Cleanup. Unregister first: the DDL hook blocks DROP of a registered view.
DELETE FROM coldfront.tiered_views WHERE schema_name = 'public' AND relname IN ('dk', 'dkv', 'dkr');
DROP VIEW public.dk, public.dkv, public.dkr;
DROP ROLE dk_member;
DROP ROLE dk_reader;
DROP ROLE dk_owner;
