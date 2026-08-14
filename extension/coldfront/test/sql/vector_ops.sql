-- The distance operators a caller writes against the real[] the view exposes.
-- Installed into pgvector's own schema so `<=>` resolves unqualified, with each
-- function named for the DuckDB function it becomes on the cold side.
--
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;
RESET client_min_messages;

SELECT coldfront.install_vector_ops();

-- Unqualified resolution is the point: these are written the way a caller writes
-- them, with no schema and no cast to vector.
SELECT round((ARRAY[1,0,0]::real[] <=> ARRAY[0,1,0]::real[])::numeric, 6) AS cosine_orthogonal,
       round((ARRAY[1,0,0]::real[] <=> ARRAY[1,0,0]::real[])::numeric, 6) AS cosine_same,
       round((ARRAY[1,0,0]::real[] <-> ARRAY[0,1,0]::real[])::numeric, 6) AS l2,
       round((ARRAY[1,2,3]::real[] <#> ARRAY[1,2,3]::real[])::numeric, 6) AS neg_inner;

-- The names are what pg_duckdb hands to DuckDB, so they are part of the contract.
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
  FROM pg_proc p
 WHERE p.proname IN ('list_cosine_distance', 'list_distance', 'list_negative_inner_product')
   AND pg_get_function_arguments(p.oid) = 'real[], real[]'
 ORDER BY p.proname;

-- Idempotent: onboarding runs it for every vector table, repeatedly.
SELECT coldfront.install_vector_ops();
SELECT count(*) AS operators FROM pg_operator
 WHERE oprname IN ('<=>', '<->', '<#>')
   AND oprleft = 'real[]'::regtype AND oprright = 'real[]'::regtype;

-- A vector-typed argument needs no cast from the caller: pgvector's vector -> real[]
-- cast is implicit, so operator resolution reaches the real[] shim.
SELECT round((ARRAY[1,0,0]::real[] <=> '[0,1,0]'::vector)::numeric, 6) AS mixed_operands;

-- A same-shaped operator in an unrelated schema does not satisfy install: the
-- caller resolves unqualified through pgvector's schema, so the operator has to
-- exist there. Drop one installed operator, plant a foreign clash, reinstall.
CREATE SCHEMA cf_opclash;
CREATE FUNCTION cf_opclash.zero_dist(real[], real[]) RETURNS double precision
LANGUAGE sql IMMUTABLE AS 'SELECT 0::double precision';
DO $$
DECLARE v_nsp text;
BEGIN
    SELECT n.nspname INTO v_nsp
      FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
     WHERE t.typname = 'vector';
    EXECUTE format('DROP OPERATOR %I.<-> (real[], real[])', v_nsp);
    CREATE OPERATOR cf_opclash.<-> (LEFTARG = real[], RIGHTARG = real[], FUNCTION = cf_opclash.zero_dist);
END $$;
SELECT coldfront.install_vector_ops();
SELECT count(*) AS l2_in_vector_schema
  FROM pg_operator o
 WHERE o.oprname = '<->' AND o.oprleft = 'real[]'::regtype AND o.oprright = 'real[]'::regtype
   AND o.oprnamespace = (SELECT t.typnamespace FROM pg_type t WHERE t.typname = 'vector');
-- Unqualified resolution lands on the reinstalled operator, not the clash.
SELECT round((ARRAY[1,0,0]::real[] <-> ARRAY[0,1,0]::real[])::numeric, 6) AS l2_after_reinstall;
DROP OPERATOR cf_opclash.<-> (real[], real[]);
DROP FUNCTION cf_opclash.zero_dist(real[], real[]);
DROP SCHEMA cf_opclash;
