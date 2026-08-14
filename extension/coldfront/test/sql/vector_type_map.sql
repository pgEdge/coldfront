-- pgvector must be present in the image: a tiered vector table carries the type
-- on its hot side, and both the cold read and cold write paths rely on
-- pgvector's implicit vector -> real[] cast.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared
-- regress db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;

-- The decoupled path's type map is the twin of the archiver's Go map
-- (pgFormatTypeToDuckDB). Both must return the same pair or a column stores one
-- way and reads another, so these same literals are asserted on the Go side in
-- TestPgFormatTypeToDuckDB.
SELECT t,
       coldfront._iceberg_storage_type(t)   AS storage,
       coldfront._iceberg_view_cast_type(t) AS view_cast
  FROM unnest(ARRAY['vector(1536)', 'vector', 'halfvec(768)', 'halfvec']) AS t;

-- sparsevec is refused rather than densified: float4[65536] is a 100x storage
-- blowup, so it stays hot-only.
SELECT coldfront._iceberg_storage_type('sparsevec(65536)');

-- format_type output is what both maps actually receive, dimension included.
CREATE TABLE vec_map_probe (id bigint, embedding vector(3));
SELECT format_type(atttypid, atttypmod) AS format_type
  FROM pg_attribute
 WHERE attrelid = 'vec_map_probe'::regclass AND attname = 'embedding';
DROP TABLE vec_map_probe;
