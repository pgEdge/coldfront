-- What a probed read is made of: which clusters to look in, the predicate that
-- says so, and the view definition the predicate is added to. Nothing here
-- executes a cold read (pg_regress has no Iceberg attached); the assertions are on
-- the generated SQL, and ci/journey.sh runs it against a real cold tier.
--
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;
RESET client_min_messages;
SET TIME ZONE 'UTC';
-- The cutoff literal is deparsed into the view definition asserted below, so both
-- of the settings that render a timestamptz are pinned.
SET DateStyle = 'ISO, MDY';
-- White-box: checks the generated SQL, not Iceberg I/O.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

SELECT coldfront.install_vector_ops();

-- Three orthogonal centroids, and a query vector plainly nearest the second.
INSERT INTO coldfront.vector_config (schema_name, table_name, column_name, nlist, nprobe, generation)
VALUES ('public', 'chunks', 'embedding', 3, 2, 1);
INSERT INTO coldfront.vector_centroids (schema_name, table_name, column_name, generation, centroid_id, centroid)
VALUES ('public', 'chunks', 'embedding', 1, 0, ARRAY[1,0,0]::real[]),
       ('public', 'chunks', 'embedding', 1, 1, ARRAY[0,1,0]::real[]),
       ('public', 'chunks', 'embedding', 1, 2, ARRAY[0,0,1]::real[]);

-- nprobe comes from the configuration unless the caller overrides it, and the ids
-- come back ascending so one probe set makes one predicate whatever order the
-- distances arrived in.
SELECT coldfront._vec_probe_ids('public', 'chunks', 'embedding', ARRAY[0.1,0.9,0.2]::real[]) AS nprobe_from_config;
SELECT coldfront._vec_probe_ids('public', 'chunks', 'embedding', ARRAY[0.1,0.9,0.2]::real[], 1) AS nearest_only;
SELECT coldfront._vec_probe_ids('public', 'chunks', 'embedding', ARRAY[0.1,0.9,0.2]::real[], 3) AS exhaustive;

-- Nothing to probe against is not an error: the read loses its predicate and scans
-- exactly, which is correct. An unconfigured table, and a configured but untrained
-- one.
SELECT coldfront._vec_probe_ids('public', 'absent', 'embedding', ARRAY[1,0,0]::real[]) IS NULL AS unconfigured;
UPDATE coldfront.vector_config SET generation = 0 WHERE table_name = 'chunks';
SELECT coldfront._vec_probe_ids('public', 'chunks', 'embedding', ARRAY[1,0,0]::real[]) IS NULL AS untrained;
UPDATE coldfront.vector_config SET generation = 1 WHERE table_name = 'chunks';

-- The predicate. The null arm is not optional: a row another engine appended
-- straight to Iceberg carries no assignment, and a bare IN would drop it.
SELECT coldfront._vec_probe_qual('embedding', ARRAY[1,2]) AS qual;
SELECT coldfront._vec_probe_qual('embedding', coldfront._vec_probe_ids('public', 'chunks', 'embedding',
                                                          ARRAY[0.1,0.9,0.2]::real[])) AS qual_from_probe;
SELECT coldfront._vec_probe_qual('embedding', NULL) IS NULL  AS no_probe_set,
       coldfront._vec_probe_qual('embedding', '{}') IS NULL  AS empty_probe_set;

-- A real tiered view, built by the generator, so the definition the rewrite
-- appends to is the one the product actually creates.
CREATE TABLE public._chunks (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz, body text, embedding vector(3));
ALTER TABLE public._chunks ADD COLUMN IF NOT EXISTS "_cf_vec_embedding" real[] GENERATED ALWAYS AS ("embedding"::real[]) STORED;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col, vec_columns)
VALUES ('public', 'chunks', 'public._chunks', 'ice.default.chunks', 'ts', ARRAY['embedding']);
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'chunks', '2026-03-01'::timestamptz);
SELECT coldfront._rebuild_tiered_view('public', 'chunks');

-- Neither branch of the view projects the cluster column: a caller's query cannot
-- name it, which is why the predicate has to be added inside the definition.
SELECT count(*) AS cluster_column_in_view
  FROM pg_attribute
 WHERE attrelid = 'public.chunks'::regclass AND attname = coldfront._vec_list_col('embedding');

-- The probed definition. The tail is what matters: the qual lands inside the cold
-- arm's WHERE, after the cutoff comparison, and the hot arm is untouched.
SELECT coldfront._vec_probed_viewdef('public', 'chunks', coldfront._vec_probe_qual('embedding', ARRAY[1,2]));

-- It reparses, which is the whole contract: the rewrite substitutes this for the
-- view reference and PostgreSQL has to accept it. IN becomes = ANY on the way in.
DO $do$
BEGIN
    EXECUTE format('CREATE VIEW public.chunks_probed AS %s',
                   coldfront._vec_probed_viewdef('public', 'chunks',
                       coldfront._vec_probe_qual('embedding', ARRAY[1,2])));
END
$do$;
SELECT right(pg_get_viewdef('public.chunks_probed'::regclass), 120) AS reparsed_tail;

-- Declining is silent. No probe set, and a table with no vector column.
SELECT coldfront._vec_probed_viewdef('public', 'chunks', NULL) IS NULL AS no_qual;
UPDATE coldfront.tiered_views SET vec_columns = NULL WHERE relname = 'chunks';
SELECT coldfront._vec_probed_viewdef('public', 'chunks', coldfront._vec_probe_qual('embedding', ARRAY[1,2])) IS NULL AS no_vector_column;
UPDATE coldfront.tiered_views SET vec_columns = ARRAY['embedding'] WHERE relname = 'chunks';

-- A tiered view with no cutoff is hot-only: it has no cold arm, so there is nothing
-- to probe.
DELETE FROM coldfront.archive_watermark WHERE table_name = 'chunks';
SELECT coldfront._vec_probed_viewdef('public', 'chunks', coldfront._vec_probe_qual('embedding', ARRAY[1,2])) IS NULL AS hot_only;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a registered
-- tiered table/view.
DROP VIEW public.chunks_probed;
DELETE FROM coldfront.tiered_views WHERE relname = 'chunks';
DELETE FROM coldfront.vector_centroids WHERE table_name = 'chunks';
DELETE FROM coldfront.vector_config WHERE table_name = 'chunks';
DROP VIEW public.chunks;
DROP TABLE public._chunks;
DROP FUNCTION coldfront.chunks_write();
