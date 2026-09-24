-- coldfront.adopt_iceberg_table gives a table that already exists in the Iceberg
-- catalog a PG wrapper view and a registry row, so it reads (and, when armed,
-- writes) like one create_iceberg_table made. The schema is read from the
-- catalog rather than declared, so most of the verb needs a live catalog and is
-- asserted in ci/journey.sh; what is checked here is everything it refuses
-- before it gets there, the registration it ends in, and its inverse.
--
-- White-box: no Iceberg I/O. coldfront.warehouse is empty, so every check below
-- runs ahead of the first DuckDB statement.

SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.local_pg_dsn = '';

-- Both names are required: without them there is no relation to build and no ref
-- to build it from.
SELECT coldfront.adopt_iceberg_table(NULL, 'orders');
SELECT coldfront.adopt_iceberg_table('public', NULL);

-- Writes are armed or not; there is no third answer to default to.
SELECT coldfront.adopt_iceberg_table('public', 'orders', p_writable => NULL);

-- Catalog writes stay off a replica. On a primary the guard passes.
SELECT coldfront._reject_on_standby('adopt an Iceberg table');

-- Adoption binds a name once. Whatever registration stands under it is refused,
-- the same call again, one that would arm writes, one from another namespace,
-- and the refusal names the exit. Nothing about the row changes.
CREATE VIEW public.orders AS SELECT 1 AS order_id;
INSERT INTO coldfront.tiered_views(schema_name, relname, iceberg_table, is_iceberg_only, is_writable)
VALUES ('public', 'orders', '"ice"."lake"."orders"', true, false);
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake');
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake', p_writable => true);
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'warehouse');
SELECT count(*) AS registry_rows, bool_and(NOT is_writable) AS still_read_only
  FROM coldfront.tiered_views WHERE relname = 'orders';

-- A tiered relation's name is bound the same way: its cold tier is already
-- managed, and the row under the name says so.
CREATE TABLE public._sales (id int, ts timestamptz);
CREATE VIEW public.sales AS SELECT * FROM public._sales;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'sales', 'public._sales', 'ice.default.sales', 'ts');
SELECT coldfront.adopt_iceberg_table('public', 'sales', 'default');
DELETE FROM coldfront.tiered_views WHERE relname = 'sales';
DROP VIEW public.sales;
DROP TABLE public._sales;

-- One relation per Iceberg ref, refused by name rather than by constraint
-- violation, because the caller chose both names. Two PG schemas adopting the
-- same namespace and table build the same ref, which is the collision.
CREATE SCHEMA reporting;
SELECT coldfront.adopt_iceberg_table('reporting', 'orders', 'lake');
SELECT count(*) AS registry_rows FROM coldfront.tiered_views WHERE schema_name = 'reporting';

-- Every registration stores, and every claim takes, one spelling of a ref: each
-- part quoted and embedded quotes doubled, as pgx.Identifier.Sanitize spells the
-- archiver's and the compactor's. A part that needs no quotes gets them anyway,
-- so the spelling does not depend on a keyword list, which changes between
-- PostgreSQL majors: format('%I', 'json') is json on 16 and "json" on 17.
SELECT coldfront._iceberg_ref('lake', 'orders') AS plain,
       coldfront._iceberg_ref('Lake-EU', 'say "hi"') AS needs_quotes,
       coldfront._iceberg_ref('public', 'json') AS keyword;

-- Adoption puts a wrapper view under the name, so a relation already standing
-- there, a table or a view coldfront did not put there, is refused before the
-- registry is touched.
CREATE TABLE reporting.orders (order_id bigint);
SELECT coldfront.adopt_iceberg_table('reporting', 'orders', 'warehouse');
DROP TABLE reporting.orders;
CREATE VIEW public.spectators AS SELECT 1 AS id;
SELECT coldfront.adopt_iceberg_table('public', 'spectators', 'lake');
DROP VIEW public.spectators;
SELECT count(*) AS registry_rows FROM coldfront.tiered_views;

-- The view needs a PG schema to land in, and the Iceberg namespace is not one:
-- ice.lake.invoices adopts into any schema that exists. One that does not is
-- refused by name ahead of the catalog read, not by CREATE VIEW after it.
SELECT coldfront.adopt_iceberg_table('lake', 'invoices', 'lake');

-- With no catalog configured there is no schema to read, and saying so beats
-- failing against a catalog that was never attached.
SELECT coldfront.adopt_iceberg_table('reporting', 'invoices', 'lake');
DROP SCHEMA reporting;

-- One column's cast, which is what the adoption loop decides per column: the
-- observed Iceberg type through the reverse map, spelled as the PG type the view
-- casts to. A list<float> is real[] and nothing else; whether it is a clustered
-- vector column is its cluster sibling's business.
SELECT d AS duckdb_type,
       coldfront._adopt_column_type('c', d, NULL) AS view_cast
  FROM unnest(ARRAY['VARCHAR', 'DECIMAL(12,2)', 'FLOAT[]', 'DOUBLE', 'BLOB']) WITH ORDINALITY AS u(d, ord)
 ORDER BY ord;

-- A p_types override wins only where it maps to the observed storage type, and
-- the view then casts to the override's surface: json for jsonb, real[] for a
-- pgvector type, the observed type where the override stores as it does
-- already. An override for another column changes nothing here.
SELECT coldfront._adopt_column_type('meta', 'VARCHAR', '{"meta":"jsonb"}'::jsonb)      AS jsonb_over_varchar,
       coldfront._adopt_column_type('ts',   'TIMESTAMP WITH TIME ZONE',
                                    '{"ts":"timestamptz"}'::jsonb)                     AS tstz_spellings_agree,
       coldfront._adopt_column_type('amt',  'DECIMAL(12, 2)', '{"amt":"numeric(12,2)"}'::jsonb) AS decimal_whitespace,
       coldfront._adopt_column_type('emb',  'FLOAT[]', '{"emb":"vector(3)"}'::jsonb)    AS vector_over_float_list,
       coldfront._adopt_column_type('n',    'INTEGER', '{"n":"smallint"}'::jsonb)       AS smallint_over_integer,
       coldfront._adopt_column_type('other','VARCHAR', '{"meta":"jsonb"}'::jsonb)       AS override_for_another_column;

-- An override that would reinterpret the stored bytes is refused, and the
-- message names the column, the override, and both storage types.
SELECT coldfront._adopt_column_type('amount', 'DECIMAL(12,2)', '{"amount":"bigint"}'::jsonb);

-- An unmappable column is refused by name whether or not p_types mentions it.
SELECT coldfront._adopt_column_type('payload', 'STRUCT(x INTEGER)', NULL);

-- The registration adoption ends in, exercised directly: the wrapper view casts
-- each column to the type it was given, and the registry row carries the
-- writability and the vector columns whose cluster siblings stayed out of the
-- projection.
SELECT coldfront._register_iceberg_view(
    'public', 'lakeside', 'ice."Lake-EU".lakeside',
    '[{"name":"id","cast":"bigint"},
      {"name":"payload","cast":"json"},
      {"name":"amount","cast":"numeric(12,2)"},
      {"name":"blob_col","cast":"bytea"},
      {"name":"embedding","cast":"real[]"}]'::jsonb,
    ARRAY['embedding'], false);

SELECT pg_get_viewdef('public.lakeside'::regclass, true);
SELECT attname, format_type(atttypid, atttypmod) AS view_type
  FROM pg_attribute WHERE attrelid = 'public.lakeside'::regclass AND attnum > 0
 ORDER BY attnum;
SELECT schema_name, relname, hot_table, iceberg_table, partition_col,
       is_iceberg_only, is_writable, vec_columns
  FROM coldfront.tiered_views WHERE relname = 'lakeside';

-- Releasing hands the relation back: the view and the registry row go, and no
-- Iceberg I/O happens, so the table keeps every row. The name is free again.
SELECT coldfront.release_iceberg_table('public', 'lakeside');
SELECT count(*) AS registry_rows FROM coldfront.tiered_views WHERE relname = 'lakeside';
SELECT count(*) AS view_left FROM pg_class WHERE relname = 'lakeside';

-- Releasing what was never registered is refused.
SELECT coldfront.release_iceberg_table('public', 'nosuch');

-- So is releasing a tiered registration: its cold rows would become unreachable
-- while the hot table returned under the relation's name.
CREATE TABLE public._events (id int, ts timestamptz, status text);
CREATE VIEW public.events AS SELECT * FROM public._events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
SELECT coldfront.release_iceberg_table('public', 'events');

-- Plain DROP VIEW stays blocked, and the hint names both exits.
DROP VIEW public.events;

-- Training and assigning both rewrite the cold table, so both refuse a relation
-- adopted read-only, ahead of any DuckDB statement.
INSERT INTO coldfront.tiered_views(schema_name, relname, iceberg_table, is_iceberg_only, vec_columns, is_writable)
VALUES ('public', 'chunks', 'ice.lake.chunks', true, ARRAY['embedding'], false);
INSERT INTO coldfront.vector_config (schema_name, table_name, column_name, nlist, nprobe, generation)
VALUES ('public', 'chunks', 'embedding', 2, 1, 1);

CALL coldfront.vector_train('public', 'chunks', 'embedding');
CALL coldfront.vector_assign('public', 'chunks', 'embedding');

-- Cleanup.
DELETE FROM coldfront.vector_config WHERE table_name = 'chunks';
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
DROP VIEW public.orders;
