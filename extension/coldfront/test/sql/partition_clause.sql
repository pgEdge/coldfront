-- The PARTITIONED BY clause a decoupled table is created with, and the vector
-- layout properties beside it. Both are text the CREATE TABLE is built from, so they
-- are asserted here; the tables themselves are asserted in ci/journey.sh against a
-- real catalog, which pg_regress does not have.
--
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

-- Each element is one DuckDB PARTITIONED BY term, joined as given.
SELECT coldfront._partition_clause(
           '[{"name":"ts","type":"timestamptz"},{"name":"region","type":"text"}]',
           '{month(ts), region}') AS clause;

-- No terms, no clause: the table is created unpartitioned.
SELECT coldfront._partition_clause('[{"name":"ts","type":"timestamptz"}]', NULL) = ''
    AS null_terms;
SELECT coldfront._partition_clause('[{"name":"ts","type":"timestamptz"}]', '{}') = ''
    AS empty_terms;

-- A time transform takes a timestamp or date column. The engine finds the column
-- whatever its case, quoted or not, and so does the check. An element that holds
-- double quotes is itself double-quoted in the array literal, with the inner
-- quotes backslashed, as PostgreSQL reads array literals.
SELECT coldfront._partition_clause('[{"name":"d","type":"date"}]', '{DAY(d)}') AS on_date;
SELECT coldfront._partition_clause('[{"name":"Ts","type":"timestamp"}]', '{"hour(\"Ts\")"}')
    AS on_timestamp;

-- Anything else is refused while the table does not exist yet: the engine accepts
-- the term at CREATE and then fails every write. hour needs a time of day.
SELECT coldfront._partition_clause('[{"name":"Status","type":"text"}]', '{"month(\"Status\")"}');
SELECT coldfront._partition_clause('[{"name":"d","type":"date"}]', '{hour(d)}');

-- Every other term reaches the engine as written, which judges it. An element with
-- a comma in it is double-quoted, or the comma splits it.
SELECT coldfront._partition_clause('[{"name":"id","type":"bigint"}]',
                                   '{"bucket(16, id)", bogus(id)}') AS passed_through;

-- A clustered table's layout properties. The file-size target goes only on an
-- unpartitioned table: the engine refuses it on a partitioned one.
SELECT coldfront._vec_layout_props('_cf_vec_list_e,id', false) AS unpartitioned;
SELECT coldfront._vec_layout_props('_cf_vec_list_e,id', true) AS partitioned;
SELECT coldfront._vec_layout_props(NULL, true) = '' AS no_vector;
