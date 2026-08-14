-- vector_assign refuses before it writes. Both checks run ahead of any DuckDB
-- statement, which is what lets pg_regress reach them with no Iceberg attached; the
-- assignment itself is asserted in ci/journey.sh against a real cold tier.
--
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

-- A column nothing registered. Naming the caller's own arguments back is what makes
-- a typo in a scripted call readable.
CALL coldfront.vector_assign('public', 'chunks', 'embedding');

CREATE TABLE public._chunks (id bigint, ts timestamptz, embedding vector(3));
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col, vec_columns)
VALUES ('public', 'chunks', 'public._chunks', 'ice.default.chunks', 'ts', ARRAY['embedding']);

-- Registered, but the column named is not the clustered one.
CALL coldfront.vector_assign('public', 'chunks', 'other');

-- Registered and clustered, with nothing trained. Assigning here would rewrite
-- every row to the NULL it already holds, so it refuses rather than reporting
-- success over a full rewrite that changed nothing.
CALL coldfront.vector_assign('public', 'chunks', 'embedding');

INSERT INTO coldfront.vector_config (schema_name, table_name, column_name, nlist, nprobe, generation)
VALUES ('public', 'chunks', 'embedding', 2, 1, 0);

-- Generation 0 is the same case spelled differently: a configuration row exists but
-- no generation was ever written.
CALL coldfront.vector_assign('public', 'chunks', 'embedding');

-- Cleanup.
DELETE FROM coldfront.vector_config WHERE table_name = 'chunks';
DELETE FROM coldfront.tiered_views WHERE relname = 'chunks';
DROP TABLE public._chunks;
