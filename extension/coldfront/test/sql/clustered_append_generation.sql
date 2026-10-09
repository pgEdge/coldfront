-- An append to a clustered table in the async ordering assigns its rows to the
-- centroid generation live when it stages and takes the claim at commit. A
-- retrain that commits in between replaces that generation, so the commit
-- callback, under the claim, compares the generation the assignment used with
-- the live one and fails the transaction with serialization_failure where they
-- differ, for the client to retry; a commit that meets no retrain lands.
-- Observed end to end: a DuckDB temporary table stands in for the Iceberg
-- table, the registry holds a clustered table of one generation, and the
-- retrain is the bakery's loopback, pointed at this server, bumping it. Each
-- staged INSERT stores the generation it is assigned against, read as the
-- assignment reads it, from the session variable the write pins.
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
SELECT set_config('coldfront.loopback_dsn',
                  format('host=%s dbname=%s user=%s',
                         trim(split_part(current_setting('unix_socket_directories'), ',', 1)),
                         current_database(), current_user), false) <> '' AS loopback_set;
SET coldfront.iceberg_async_parquet = on;
SET coldfront.iceberg_bakery_patch = on;
SELECT duckdb.raw_query('CREATE TEMP TABLE cf_gen (id INTEGER, v FLOAT[], cf_v_list INTEGER)') IS NOT NULL AS created;

CREATE TABLE public._cf_gen (id int, v real[]);
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col, vec_columns)
VALUES ('public', 'cf_gen', 'public._cf_gen', 'temp.main.cf_gen', 'id', '{v}');
INSERT INTO coldfront.vector_config(schema_name, table_name, column_name, nlist, nprobe, generation)
VALUES ('public', 'cf_gen', 'v', 2, 1, 1);

-- (1) No retrain between staging and commit: the append lands.
BEGIN;
SELECT coldfront._exec_iceberg_with_claim('temp.main.cf_gen',
    format('INSERT INTO temp.main.cf_gen SELECT 1, [0.1, 0.2], getvariable(%L)', coldfront._vec_generation_var('public', 'cf_gen', 'v')));
COMMIT;

-- (2) A retrain commits in between: the commit fails and nothing lands.
BEGIN;
SELECT coldfront._exec_iceberg_with_claim('temp.main.cf_gen',
    format('INSERT INTO temp.main.cf_gen SELECT 2, [0.3, 0.4], getvariable(%L)', coldfront._vec_generation_var('public', 'cf_gen', 'v')));
SELECT coldfront._loopback('UPDATE coldfront.vector_config SET generation = 2 WHERE table_name = ''cf_gen'' RETURNING generation') AS retrained_elsewhere;
COMMIT;

-- (3) The check reads the live generation under REPEATABLE READ too, whose
--     statements would see the one the transaction started with.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT generation FROM coldfront.vector_config WHERE table_name = 'cf_gen';
SELECT coldfront._exec_iceberg_with_claim('temp.main.cf_gen',
    format('INSERT INTO temp.main.cf_gen SELECT 3, [0.5, 0.6], getvariable(%L)', coldfront._vec_generation_var('public', 'cf_gen', 'v')));
SELECT coldfront._loopback('UPDATE coldfront.vector_config SET generation = 3 WHERE table_name = ''cf_gen'' RETURNING generation') AS retrained_elsewhere;
COMMIT;

-- (4) The next attempt, assigned against the live generation, lands.
BEGIN;
SELECT coldfront._exec_iceberg_with_claim('temp.main.cf_gen',
    format('INSERT INTO temp.main.cf_gen SELECT 4, [0.7, 0.8], getvariable(%L)', coldfront._vec_generation_var('public', 'cf_gen', 'v')));
COMMIT;
SELECT r['id']::int AS id, r['cf_v_list']::int AS generation_used
  FROM duckdb.query('SELECT id, cf_v_list FROM temp.main.cf_gen') AS t(r) ORDER BY 1;
