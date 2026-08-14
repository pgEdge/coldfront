-- What vector_status reports is an API, so its column list is asserted here. The
-- numbers are not: filling them reads the cold table through DuckDB, which
-- pg_regress has no Iceberg to do, so the distribution is asserted in ci/journey.sh
-- against a real cold tier.
--
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;
-- White-box: no Iceberg here, so ensure_attached() must be a no-op.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

-- With nothing clustered the loop body never runs, which is the case that says so
-- rather than reporting an empty table and leaving the caller to guess.
CALL coldfront.vector_status();

-- The reported columns. File count and bytes are deliberately absent: reaching them
-- means resolving a metadata location over HTTP, which this layer does not do, and
-- the compactor already reports both.
SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type
  FROM pg_attribute a
 WHERE a.attrelid = 'cf_vector_status'::regclass
   AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY a.attnum;

-- Re-running replaces the previous result rather than appending to it.
CALL coldfront.vector_status();
SELECT count(*) AS reported FROM cf_vector_status;

-- Naming a table that is not registered reports nothing, and is not an error: a
-- caller scripting this against a list of tables should not have to know which of
-- them carry vectors.
CALL coldfront.vector_status('public', 'nosuchtable');
SELECT count(*) AS reported FROM cf_vector_status;

DROP TABLE cf_vector_status;
