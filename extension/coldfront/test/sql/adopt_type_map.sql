-- coldfront._pg_type_from_iceberg maps a DuckDB column type, as DESCRIBE spells
-- it on an attached Iceberg table, to the PostgreSQL type an adopted wrapper
-- view exposes it as. It is the reverse of _iceberg_storage_type, and lossier:
-- Iceberg stores no PG type, so several PG types collapse onto one storage type
-- and come back as whichever one that storage type reads as natively.
--
-- Both spellings of a type have to arrive at the same PG type, because
-- adopt_iceberg_table compares a caller's p_types override against the observed
-- storage type by running both through this function, and the two sides spell
-- some types differently: _iceberg_storage_type returns REAL and TIMESTAMPTZ
-- and keeps the caller's DECIMAL whitespace, while DESCRIBE returns FLOAT,
-- TIMESTAMP WITH TIME ZONE and DECIMAL(P,S).
--
-- Pure SQL: no catalog, no Iceberg I/O.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- The type map, in the spellings DESCRIBE returns.
SELECT d AS duckdb_type, coldfront._pg_type_from_iceberg(d) AS pg_type
  FROM unnest(ARRAY[
      'BOOLEAN', 'INTEGER', 'BIGINT', 'FLOAT', 'DOUBLE', 'DECIMAL(12,2)',
      'DATE', 'TIME', 'TIMESTAMP', 'TIMESTAMP WITH TIME ZONE',
      'VARCHAR', 'UUID', 'BLOB', 'FLOAT[]'
  ]) WITH ORDINALITY AS u(d, ord)
 ORDER BY ord;

-- The spellings _iceberg_storage_type returns for the same types, which DESCRIBE
-- never produces. They must land on the same PG types as their twins above.
SELECT d AS duckdb_type, coldfront._pg_type_from_iceberg(d) AS pg_type
  FROM unnest(ARRAY['REAL', 'TIMESTAMPTZ', 'DECIMAL(12, 2)']) WITH ORDINALITY AS u(d, ord)
 ORDER BY ord;

-- Case and surrounding whitespace are not significant.
SELECT coldfront._pg_type_from_iceberg('  timestamp with time zone  ') AS lower_padded,
       coldfront._pg_type_from_iceberg('Decimal( 9 , 4 )')             AS mixed_case_spaced;

-- Every PG type _iceberg_storage_type accepts, round-tripped. Where two PG types
-- share one storage type the round trip returns the one that storage type reads
-- as natively, so smallint comes back integer, every string type comes back
-- text, and a pgvector column comes back real[], the same as the plain float
-- list it shares its storage with.
SELECT p                                                                   AS pg_type,
       coldfront._iceberg_storage_type(p)                                  AS storage,
       coldfront._pg_type_from_iceberg(coldfront._iceberg_storage_type(p)) AS round_trip
  FROM unnest(ARRAY[
      'bigint', 'int8', 'integer', 'int', 'int4', 'smallint', 'int2',
      'real', 'float4', 'double precision', 'float8', 'boolean', 'bool',
      'timestamp with time zone', 'timestamptz',
      'timestamp without time zone', 'timestamp',
      'date', 'time without time zone', 'time',
      'uuid', 'text', 'bytea',
      'character varying(10)', 'varchar(10)', 'varchar',
      'character(5)', 'char(5)', 'character',
      'numeric(12,2)', 'numeric(12, 2)', 'decimal(10,4)',
      'jsonb', 'json', 'interval',
      'vector(3)', 'halfvec(3)'
  ]) WITH ORDINALITY AS u(p, ord)
 ORDER BY ord;

-- Nanosecond timestamps are refused: PostgreSQL stores microseconds.
SELECT coldfront._pg_type_from_iceberg('TIMESTAMP_NS');

-- Iceberg types with no PostgreSQL equivalent this mode can expose. DuckDB
-- loads and DESCRIBEs all of them, so the refusal is coldfront's.
SELECT coldfront._pg_type_from_iceberg('VARIANT');
SELECT coldfront._pg_type_from_iceberg('GEOMETRY');
SELECT coldfront._pg_type_from_iceberg('STRUCT(x INTEGER, y VARCHAR)');
SELECT coldfront._pg_type_from_iceberg('MAP(VARCHAR, INTEGER)');

-- A list of anything but float: only list<float> has a wrapper-view spelling
-- both engines read the same way.
SELECT coldfront._pg_type_from_iceberg('BIGINT[]');

-- An unbounded DECIMAL never comes from DESCRIBE, which always spells out the
-- precision and scale, and PostgreSQL cannot be told the width otherwise.
SELECT coldfront._pg_type_from_iceberg('DECIMAL');

-- Given the column, the refusal names it: this is the message adopt_iceberg_table
-- shows, and the column is what tells the caller which one to leave behind.
SELECT coldfront._pg_type_from_iceberg('STRUCT(x INTEGER, y VARCHAR)', 'payload');

-- STRICT: a NULL type yields NULL rather than raising.
SELECT coldfront._pg_type_from_iceberg(NULL) IS NULL AS null_in_null_out;
