-- A column name DuckDB cannot parse is refused wherever ColdFront gives a column
-- a cold tier. pg_duckdb c04e6a2 hands DuckDB each column name quoted the way
-- PostgreSQL quotes it, so a name PostgreSQL leaves bare reaches DuckDB bare, and
-- DuckDB's parser takes some of those as keywords (duckdb/pg_duckdb#1019).
-- White-box like ddl_alter_column: each refusal comes before any Iceberg call, so
-- no catalog is needed. ci/journey.sh covers registration, the archive pass and
-- adoption.

SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

-- 1. The upstream defect, with nothing of ColdFront's involved: the statement
--    quotes "by" and pg_duckdb hands it to DuckDB bare. Once this succeeds the
--    defect is gone, and coldfront._require_duckdb_column_name goes with it.
CREATE TABLE public.kw_heap (id int, "by" int);
CREATE TEMP TABLE kw_stage USING duckdb AS SELECT "id", "by" FROM public.kw_heap;

-- 2. The refused names, derived from both parsers: every DuckDB keyword that
--    PostgreSQL leaves bare and that DuckDB's parser rejects as a column. A pin
--    move that changes this set changes the output below, and each name the
--    derivation finds must be refused.
CREATE TEMP TABLE kw_duckdb AS
SELECT r['w']::text AS w
  FROM duckdb.query($$SELECT DISTINCT keyword_name AS w FROM duckdb_keywords()$$) AS r;
SELECT format($f$SELECT string_agg(n, ' ' ORDER BY n) AS names FROM (VALUES %s) AS v(n)
                 WHERE (json_serialize_sql('SELECT ' || n || ' FROM t')->>'error')::BOOLEAN$f$,
              string_agg(format('(%L)', w), ', ')) AS derive
  FROM kw_duckdb WHERE quote_ident(w) = w \gset
CREATE TEMP TABLE kw_rejected AS
SELECT unnest(string_to_array(r['names']::text, ' ')) AS n FROM duckdb.query(:'derive') AS r;
SELECT string_agg(n, ' ' ORDER BY n) AS rejected_by_duckdb FROM kw_rejected;
SELECT format('SELECT coldfront._require_duckdb_column_name(%L)', n) FROM kw_rejected ORDER BY n \gexec
-- Any other name comes back unchanged: one PostgreSQL quotes (a reserved word
-- there, or not lower case), a DuckDB keyword its parser takes as a name, and a
-- refused word in another case, which PostgreSQL quotes.
SELECT n, coldfront._require_duckdb_column_name(n) = n AS kept
  FROM unnest(ARRAY['id', 'order', 'Mixed Case', 'columns', 'generated', 'By']) AS n;

-- 3. create_iceberg_table refuses before its first Iceberg call, leaving no view
--    and no registry row.
SELECT coldfront.create_iceberg_table('public', 'kw_dec',
    '[{"name": "id", "type": "bigint"}, {"name": "show", "type": "integer"}]'::jsonb);
SELECT to_regclass('public.kw_dec') IS NULL AS no_view,
       NOT EXISTS (SELECT 1 FROM coldfront.tiered_views WHERE relname = 'kw_dec') AS no_row;

-- 4. A column change on a registered table refuses an added or renamed column
--    with such a name before the Iceberg ALTER, and the hot ALTER rolls back.
CREATE TABLE public._kw_events (id int, ts timestamptz);
CREATE VIEW public.kw_events AS SELECT * FROM public._kw_events;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'kw_events', 'public._kw_events', 'ice.default.kw_events', 'ts');
ALTER TABLE public._kw_events ADD COLUMN by int;
ALTER TABLE public._kw_events RENAME COLUMN id TO at;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public._kw_events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a registered
-- tiered table/view.
DELETE FROM coldfront.tiered_views WHERE relname = 'kw_events';
DROP VIEW public.kw_events;
DROP TABLE public._kw_events, public.kw_heap;
