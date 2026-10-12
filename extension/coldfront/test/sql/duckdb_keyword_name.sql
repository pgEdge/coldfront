-- A table or column name DuckDB cannot parse is refused wherever ColdFront gives
-- it a cold tier. pg_duckdb c04e6a2 hands DuckDB each identifier quoted the way
-- PostgreSQL quotes it, so a name PostgreSQL leaves bare reaches DuckDB bare, and
-- DuckDB's parser takes some of those as keywords (duckdb/pg_duckdb#1019).
-- White-box like ddl_alter_column: each refusal comes before any Iceberg call, so
-- no catalog is needed. ci/journey.sh covers registration, the archive pass,
-- adoption and a rename on an archived table.

SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

-- 1. The upstream defect, with nothing of ColdFront's involved: each statement
--    quotes the name and pg_duckdb hands it to DuckDB bare, as a column, as the
--    qualifier of a table's columns in a view it expands, and as that view's
--    alias. Once these succeed the defect is gone, and
--    coldfront._require_duckdb_name goes with it.
CREATE TABLE public.kw_heap (id int, "by" int);
CREATE TEMP TABLE kw_stage USING duckdb AS SELECT "id", "by" FROM public.kw_heap;
CREATE TABLE public."show" (id int);
CREATE VIEW public.kw_over_show AS SELECT id FROM public."show";
CREATE TEMP TABLE kw_qual USING duckdb AS SELECT id FROM public.kw_over_show;
CREATE VIEW public."at" AS SELECT id FROM public.kw_heap;
CREATE TEMP TABLE kw_alias USING duckdb AS SELECT id FROM public."at";

-- 2. The refused names, derived from both parsers: every DuckDB keyword that
--    PostgreSQL leaves bare and that DuckDB's parser rejects as a column, or as
--    a table's alias and the qualifier of its columns. A pin move that changes
--    either set changes the output below, and each name the derivation finds
--    must be refused as that kind of name.
CREATE TEMP TABLE kw_duckdb AS
SELECT r['w']::text AS w
  FROM duckdb.query($$SELECT DISTINCT keyword_name AS w FROM duckdb_keywords()$$) AS r;
SELECT format($f$SELECT 'column' AS k, n FROM (VALUES %1$s) AS v(n)
                  WHERE (json_serialize_sql('SELECT ' || n || ' FROM t')->>'error')::BOOLEAN
                 UNION ALL
                 SELECT 'table', n FROM (VALUES %1$s) AS v(n)
                  WHERE (json_serialize_sql('SELECT ' || n || '.id FROM (SELECT 1 AS id) ' || n)->>'error')::BOOLEAN$f$,
              string_agg(format('(%L)', w), ', ')) AS derive
  FROM kw_duckdb WHERE quote_ident(w) = w \gset
CREATE TEMP TABLE kw_rejected AS
SELECT r['k']::text AS k, r['n']::text AS n FROM duckdb.query(:'derive') AS r;
SELECT k, string_agg(n, ' ' ORDER BY n) AS rejected_by_duckdb FROM kw_rejected GROUP BY k ORDER BY k;
SELECT format('SELECT coldfront._require_duckdb_name(%L, %L)', k, n) FROM kw_rejected ORDER BY k, n \gexec
-- Any other name comes back unchanged: one PostgreSQL quotes (a reserved word
-- there, or not lower case), a DuckDB keyword its parser takes as a name, and a
-- refused word in another case, which PostgreSQL quotes.
SELECT n, coldfront._require_duckdb_name('column', n) = n
      AND coldfront._require_duckdb_name('table', n) = n AS kept
  FROM unnest(ARRAY['id', 'order', 'Mixed Case', 'columns', 'generated', 'By']) AS n;

-- 3. create_iceberg_table and adopt_iceberg_table refuse before their first
--    Iceberg call, leaving no view and no registry row.
SELECT coldfront.create_iceberg_table('public', 'kw_dec',
    '[{"name": "id", "type": "bigint"}, {"name": "show", "type": "integer"}]'::jsonb);
SELECT coldfront.create_iceberg_table('public', 'pivot',
    '[{"name": "id", "type": "bigint"}]'::jsonb);
SELECT coldfront.adopt_iceberg_table('public', 'qualify');
SELECT n, to_regclass(format('public.%I', n)) IS NULL AS no_view,
       NOT EXISTS (SELECT 1 FROM coldfront.tiered_views WHERE relname = n) AS no_row
  FROM unnest(ARRAY['kw_dec', 'pivot', 'qualify']) AS n;

-- 4. A change on a registered table refuses such a name, and the hot ALTER rolls
--    back: an added or renamed column, before the Iceberg ALTER, and the view or
--    the hot table renamed to one.
CREATE TABLE public._kw_events (id int, ts timestamptz);
CREATE VIEW public.kw_events AS SELECT * FROM public._kw_events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'kw_events', 'public._kw_events', 'ice.default.kw_events', 'ts');
ALTER TABLE public._kw_events ADD COLUMN by int;
ALTER TABLE public._kw_events RENAME COLUMN id TO at;
ALTER VIEW public.kw_events RENAME TO qualify;
ALTER TABLE public._kw_events RENAME TO glob;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public._kw_events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;
SELECT relname FROM pg_class
 WHERE relnamespace = 'public'::regnamespace
   AND relname IN ('kw_events', '_kw_events', 'qualify', 'glob')
 ORDER BY relname;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a registered
-- tiered table/view.
DELETE FROM coldfront.tiered_views WHERE relname = 'kw_events';
DROP VIEW public.kw_events, public."at", public.kw_over_show;
DROP TABLE public._kw_events, public.kw_heap, public."show";
