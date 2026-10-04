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
