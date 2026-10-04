-- coldfront._iceberg_storage_type and coldfront._iceberg_view_cast_type are the
-- type map every path stores and reads a column by: the archiver reads a tiered
-- table's columns through them, and create_iceberg_table, the view rebuild and
-- the cold writers call them too. Their input is format_type(atttypid,
-- atttypmod), so the cases below are the columns of a real table.
--
-- Pure SQL: no catalog, no Iceberg I/O.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

CREATE TABLE type_map_probe (
    c_bigint      bigint,
    c_integer     integer,
    c_smallint    smallint,
    c_real        real,
    c_double      double precision,
    c_boolean     boolean,
    c_timestamptz timestamptz,
    c_timestamp   timestamp,
    c_date        date,
    c_time        time,
    c_uuid        uuid,
    c_text        text,
    c_varchar     varchar(255),
    c_varchar_any varchar,
    c_char        char(10),
    c_bytea       bytea,
    c_numeric     numeric(20,5),
    c_numeric38   numeric(38,10),
    c_jsonb       jsonb,
    c_json        json,
    c_interval    interval
);

-- The storage type, and the cast the view applies where the storage type is not
-- the type the column reads as: smallint widens to INTEGER, which is its own
-- surface; DOUBLE and BLOB are not PostgreSQL spellings; json and interval are
-- stored as text and cast back.
SELECT a.attname,
       format_type(a.atttypid, a.atttypmod)                                    AS format_type,
       coldfront._iceberg_storage_type(format_type(a.atttypid, a.atttypmod))   AS storage,
       coldfront._iceberg_view_cast_type(format_type(a.atttypid, a.atttypmod)) AS view_cast
  FROM pg_attribute a
 WHERE a.attrelid = 'type_map_probe'::regclass AND a.attnum > 0
 ORDER BY a.attnum;
DROP TABLE type_map_probe;

-- Refused types. inet, cidr and oid would store, but pg_duckdb cannot plan a
-- query that reads them, and every read of a tiered table after its first
-- archive is planned by pg_duckdb.
SELECT coldfront._iceberg_storage_type('inet');
SELECT coldfront._iceberg_storage_type('cidr');
SELECT coldfront._iceberg_storage_type('oid');
SELECT coldfront._iceberg_storage_type('numeric');
SELECT coldfront._iceberg_storage_type('time with time zone');
SELECT coldfront._iceberg_storage_type('tsvector');
SELECT coldfront._iceberg_storage_type('xml');
CREATE TYPE type_map_mood AS ENUM ('ok');
SELECT coldfront._iceberg_storage_type('type_map_mood');
DROP TYPE type_map_mood;

-- Given the column, a refusal names it. The archiver, the partition CLI,
-- create_iceberg_table and the DDL hook's mirror and view rebuild pass it.
SELECT coldfront._iceberg_storage_type('inet', 'ip');
SELECT coldfront._iceberg_storage_type('numeric', 'amount');

-- A one-dimensional array of a native type stores as an Iceberg list of the
-- element's storage type, and reads back as an array of the element's surface
-- type. text[] keeps its own spelling: the array operators (=, @>, &&) take
-- varchar[] and text[] as different types.
CREATE TABLE type_map_arrays (
    a_bigint   bigint[],
    a_integer  integer[],
    a_smallint smallint[],
    a_real     real[],
    a_double   double precision[],
    a_boolean  boolean[],
    a_date     date[],
    a_time     time[],
    a_ts       timestamp[],
    a_uuid     uuid[],
    a_text     text[],
    a_varchar  varchar(8)[],
    a_char     char(4)[],
    a_bytea    bytea[],
    a_numeric  numeric(12,2)[]
);
SELECT a.attname,
       format_type(a.atttypid, a.atttypmod)                                    AS format_type,
       coldfront._iceberg_storage_type(format_type(a.atttypid, a.atttypmod))   AS storage,
       coldfront._iceberg_view_cast_type(format_type(a.atttypid, a.atttypmod)) AS view_cast
  FROM pg_attribute a
 WHERE a.attrelid = 'type_map_arrays'::regclass AND a.attnum > 0
 ORDER BY a.attnum;
DROP TABLE type_map_arrays;

-- Refused arrays: an element that is itself an array or a vector, an element
-- stored as text and read back through a cast, and an element the map refuses.
SELECT coldfront._iceberg_storage_type('integer[][]');
SELECT coldfront._iceberg_storage_type('vector(3)[]');
SELECT coldfront._iceberg_storage_type('halfvec(3)[]');
SELECT coldfront._iceberg_storage_type('jsonb[]');
SELECT coldfront._iceberg_storage_type('json[]');
SELECT coldfront._iceberg_storage_type('interval[]');
SELECT coldfront._iceberg_storage_type('inet[]');

-- An array type is spelled as format_type spells it, the element followed by
-- []. A decoupled table's column list is the one input that can spell it
-- otherwise, and those spellings are refused.
SELECT coldfront._iceberg_storage_type('integer[3]');
SELECT coldfront._iceberg_storage_type('integer array');

-- An array's refusal names the column too, whichever part of the type refuses.
SELECT coldfront._iceberg_storage_type('jsonb[]', 'docs');
SELECT coldfront._iceberg_storage_type('inet[]', 'ips');

-- timestamptz[] is refused because pg_duckdb (c04e6a2) cannot read the column,
-- and every read of a tiered view after its first archive is a pg_duckdb scan of
-- the hot table. The probe has a tiered view's shape: the DuckDB read in its
-- second branch makes pg_duckdb plan the whole query, hot table included. When
-- the probe reads the value, the refusal can go.
SELECT coldfront._iceberg_storage_type('timestamp with time zone[]');
CREATE TABLE type_map_tstz (a timestamptz[]);
INSERT INTO type_map_tstz VALUES ('{2026-01-02 03:04:05+00}');
SELECT a FROM type_map_tstz
UNION ALL
SELECT NULL::timestamptz[] FROM duckdb.query('SELECT 1') AS t(r);
DROP TABLE type_map_tstz;
