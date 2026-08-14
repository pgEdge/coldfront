-- Four cold-write paths render a value for DuckDB, and they share two decisions
-- so a value cannot round-trip through one path and corrupt through another:
-- _cold_placeholder / _cold_value for the INSTEAD OF trigger (create_iceberg_table
-- for a decoupled table, _rebuild_tiered_view for a tiered one, view.go for the Go
-- twin), and _render_cold_value for the per-row loops that read a jsonb payload.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared
-- regress db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
CREATE EXTENSION IF NOT EXISTS vector;

-- The trigger's pair. The view exposes a vector as real[], whose text form is
-- PG's {1,2,3}; DuckDB's list cast takes [1,2,3] only, so translate rewrites the
-- delimiters and the placeholder supplies the Iceberg column's type.
SELECT t,
       coldfront._cold_placeholder(t)         AS placeholder,
       coldfront._cold_value('embedding', t)  AS value
  FROM unnest(ARRAY['vector(3)', 'halfvec(3)']) AS t;

-- Every other type keeps the spelling it already had.
SELECT t,
       coldfront._cold_placeholder(t)  AS placeholder,
       coldfront._cold_value('c', t)   AS value
  FROM unnest(ARRAY['bytea', 'jsonb', 'json', 'interval', 'bigint',
                    'double precision', 'text']) AS t;

-- The per-row loops read their value out of a jsonb payload, which spells a
-- vector as a string and a real[] as an array, so both arrive bracketed already
-- and only the cast is added. Whitespace between elements is accepted by DuckDB.
SELECT coldfront._render_cold_value('[1,2,3]', 'vector(3)')    AS vec_tight,
       coldfront._render_cold_value('[1, 2, 3]', 'vector(3)')  AS vec_spaced;

-- bytea arrives as PG's '\xHEX'; the hex digits are what DuckDB rebuilds from.
SELECT coldfront._render_cold_value('\xcafe', 'bytea')  AS blob,
       coldfront._render_cold_value('2.5', 'double precision') AS dbl,
       coldfront._render_cold_value('a''b', 'text')     AS quoted;

-- The per-row serialiser keeps a NULL vector's positional slot. The Iceberg schema
-- declares one cluster column per vector column unconditionally, so the prefix
-- carries one assignment per vector column whatever this row holds; an entry
-- missing from the prefix would shift every following value one column left.
SELECT coldfront._move_row_literal(
    '{"id": 8, "cf_new_ts": "2026-06-01 00:00:00+00", "embedding": "[1,2,3]"}'::jsonb,
    ARRAY['id','ts','embedding'],
    ARRAY['bigint','timestamp with time zone','vector(3)'],
    'ts', 'public', 'chunks') AS vec_row;
SELECT coldfront._move_row_literal(
    '{"id": 7, "cf_new_ts": "2026-06-01 00:00:00+00", "embedding": null}'::jsonb,
    ARRAY['id','ts','embedding'],
    ARRAY['bigint','timestamp with time zone','vector(3)'],
    'ts', 'public', 'chunks') AS null_vec_row;
