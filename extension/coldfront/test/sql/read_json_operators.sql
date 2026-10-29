-- The json/jsonb operators DuckDB lacks (#>, #>>, ?, ?|, ?&, @>, <@) on a read
-- DuckDB runs. DuckDB's parser has no # or ? operator character and DuckDB has no
-- containment operator, so the read rewrite turns each into the JSON functions
-- pg_duckdb hands to DuckDB (json_extract, json_extract_string, json_exists,
-- json_contains, json_type). White-box: DuckDB executes the rewritten read against
-- the heap (duckdb.force_execution) through a view that casts jsonb to json, as a
-- tiered view does, and PostgreSQL runs the same operators on the heap; no
-- Iceberg I/O.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;
SET TIME ZONE 'UTC';
-- White-box: checks the generated SQL, not Iceberg I/O.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._docs (id int, ts timestamptz, data jsonb);
CREATE VIEW public.docs AS SELECT id, ts, data::json AS data FROM public._docs;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'docs', 'public._docs', 'ice.default.docs', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'docs', '2026-03-01'::timestamptz);
-- An object whose keys a JSON Pointer or a JSONPath would misread ("-1", "01",
-- "", "a/b", "t~", "*", a quote, a backslash), an array, a bare string, a bare
-- number and SQL NULL.
INSERT INTO public._docs VALUES
  (1, '2026-01-01', '{"k": 1, "a": [1, 2, 3], "o": {"b": "c"}, "-1": "neg", "01": "pad", "": "empty", "a/b": "slash", "t~": "tilde", "*": "star", "q\"k": "quote", "b\\s": "bslash", "n": null}'),
  (2, '2026-01-02', '["k", ["k"], 1, "0", {"k": 1}, null]'),
  (3, '2026-01-03', '"k"'),
  (4, '2026-01-04', '5'),
  (5, '2026-01-05', NULL);

-- (A) A path into an array, and a key test through the ::jsonb cast.
SET duckdb.force_execution = true;
SELECT data #> '{a,0}' AS a0 FROM public.docs WHERE id = 1;
SELECT id FROM public.docs WHERE (data::jsonb) ? 'k' ORDER BY id;
RESET duckdb.force_execution;

-- (B) #> and #>>. A path element reaches an array element or an object key, as
-- PostgreSQL's does: a negative, zero-padded or signed index counts on an array
-- and names a key on an object.
SET duckdb.force_execution = true;
SELECT id, data #>> '{a,0}' AS a0, data #>> '{a,-1}' AS alast, data #>> '{a,01}' AS apad,
       data #>> '{a,+1}' AS asign, data #>> '{a,-4}' AS aout, data #>> '{-1}' AS neg,
       data #>> '{01}' AS pad, data #>> '{""}' AS empty, data #>> '{a/b}' AS slash,
       data #>> '{t~}' AS tilde, data #>> '{*}' AS star, data #>> ARRAY['q"k'] AS quote,
       data #>> ARRAY['b\s'] AS bslash, data #>> '{o,b}' AS ob, data #>> '{4,k}' AS nested,
       data #>> '{n}' AS jnull, data #>> '{a,NULL}' AS nullelem, data #> '{0}' AS first
  FROM public.docs ORDER BY id;
RESET duckdb.force_execution;
SELECT id, data #>> '{a,0}' AS a0, data #>> '{a,-1}' AS alast, data #>> '{a,01}' AS apad,
       data #>> '{a,+1}' AS asign, data #>> '{a,-4}' AS aout, data #>> '{-1}' AS neg,
       data #>> '{01}' AS pad, data #>> '{""}' AS empty, data #>> '{a/b}' AS slash,
       data #>> '{t~}' AS tilde, data #>> '{*}' AS star, data #>> ARRAY['q"k'] AS quote,
       data #>> ARRAY['b\s'] AS bslash, data #>> '{o,b}' AS ob, data #>> '{4,k}' AS nested,
       data #>> '{n}' AS jnull, data #>> '{a,NULL}' AS nullelem, data #> '{0}' AS first
  FROM public._docs ORDER BY id;

-- An empty path is the whole value; DuckDB renders a container compactly, as it
-- does for ->.
SET duckdb.force_execution = true;
SELECT id, data #>> '{}' AS whole, data #> '{o}' AS o FROM public.docs WHERE id IN (1, 3) ORDER BY id;
RESET duckdb.force_execution;
SELECT id, data #>> '{}' AS whole, data #> '{o}' AS o FROM public._docs WHERE id IN (1, 3) ORDER BY id;

-- (C) ?, ?| and ?&: a top-level key, a top-level string element or the bare
-- string itself, never a number and never a nested key. NULL keys are skipped.
SET duckdb.force_execution = true;
SELECT id, (data::jsonb) ? 'k' AS k, (data::jsonb) ? '0' AS zero, (data::jsonb) ? '-1' AS neg,
       (data::jsonb) ? '' AS empty, (data::jsonb) ? '*' AS star, (data::jsonb) ? 'a/b' AS slash,
       (data::jsonb) ? 'q"k' AS quote, (data::jsonb) ? 'b\s' AS bslash, (data::jsonb) ? '5' AS five,
       (data::jsonb) ?| '{zz,k}' AS any_k, (data::jsonb) ?| '{zz}' AS any_zz,
       (data::jsonb) ?| '{}' AS any_none, (data::jsonb) ?& ARRAY['k', 'a'] AS all_ka,
       (data::jsonb) ?& '{k,NULL}' AS all_knull, (data::jsonb) ?& '{}' AS all_none
  FROM public.docs ORDER BY id;
RESET duckdb.force_execution;
SELECT id, (data::jsonb) ? 'k' AS k, (data::jsonb) ? '0' AS zero, (data::jsonb) ? '-1' AS neg,
       (data::jsonb) ? '' AS empty, (data::jsonb) ? '*' AS star, (data::jsonb) ? 'a/b' AS slash,
       (data::jsonb) ? 'q"k' AS quote, (data::jsonb) ? 'b\s' AS bslash, (data::jsonb) ? '5' AS five,
       (data::jsonb) ?| '{zz,k}' AS any_k, (data::jsonb) ?| '{zz}' AS any_zz,
       (data::jsonb) ?| '{}' AS any_none, (data::jsonb) ?& ARRAY['k', 'a'] AS all_ka,
       (data::jsonb) ?& '{k,NULL}' AS all_knull, (data::jsonb) ?& '{}' AS all_none
  FROM public._docs ORDER BY id;

-- (D) @> and <@: containment from the top level down, an array containing a
-- bare scalar, and nothing found deeper than the top.
SET duckdb.force_execution = true;
SELECT id, (data::jsonb) @> '{"o": {"b": "c"}}' AS nested, (data::jsonb) @> '{"b": "c"}' AS deeper,
       (data::jsonb) @> '"k"' AS scalar, (data::jsonb) @> '["k"]' AS arr,
       (data::jsonb) @> '[["k"]]' AS arrarr, (data::jsonb) @> '{"a": [3, 1]}' AS subset,
       (data::jsonb) @> '{}' AS empty_obj, (data::jsonb) @> '[]' AS empty_arr,
       (data::jsonb) <@ '["k", ["k"], 1, "0", {"k": 1}, null, "extra"]' AS within
  FROM public.docs ORDER BY id;
RESET duckdb.force_execution;
SELECT id, (data::jsonb) @> '{"o": {"b": "c"}}' AS nested, (data::jsonb) @> '{"b": "c"}' AS deeper,
       (data::jsonb) @> '"k"' AS scalar, (data::jsonb) @> '["k"]' AS arr,
       (data::jsonb) @> '[["k"]]' AS arrarr, (data::jsonb) @> '{"a": [3, 1]}' AS subset,
       (data::jsonb) @> '{}' AS empty_obj, (data::jsonb) @> '[]' AS empty_arr,
       (data::jsonb) <@ '["k", ["k"], 1, "0", {"k": 1}, null, "extra"]' AS within
  FROM public._docs ORDER BY id;

-- DuckDB compares JSON numbers by kind, so an integer never contains or matches
-- the same value written as a decimal, which PostgreSQL's numeric comparison
-- does (a documented difference).
INSERT INTO public._docs VALUES (6, '2026-01-06', '{"p": 10.0}');
SET duckdb.force_execution = true;
SELECT (data::jsonb) @> '{"p": 10.0}' AS same_kind, (data::jsonb) @> '{"p": 10}' AS int_in_decimal
  FROM public.docs WHERE id = 6;
RESET duckdb.force_execution;
SELECT (data::jsonb) @> '{"p": 10.0}' AS same_kind, (data::jsonb) @> '{"p": 10}' AS int_in_decimal
  FROM public._docs WHERE id = 6;
DELETE FROM public._docs WHERE id = 6;

-- (E) The function spellings of the same operators.
SET duckdb.force_execution = true;
SELECT id, json_extract_path_text(data, 'a', '-1') AS f1, jsonb_extract_path_text(data::jsonb, 'o', 'b') AS f2,
       jsonb_exists(data::jsonb, 'k') AS f3
  FROM public.docs ORDER BY id;
RESET duckdb.force_execution;
SELECT id, json_extract_path_text(data::json, 'a', '-1') AS f1, jsonb_extract_path_text(data, 'o', 'b') AS f2,
       jsonb_exists(data, 'k') AS f3
  FROM public._docs ORDER BY id;

-- (F) A path or key set taken from a column cannot be rewritten, and says so.
SELECT data #> ARRAY[id::text] FROM public.docs;
SELECT (data::jsonb) ?| ARRAY[id::text] FROM public.docs;

-- (G) A read the hot heap can answer keeps the operator: it never reaches DuckDB.
EXPLAIN (COSTS OFF, VERBOSE)
SELECT data #> '{a,0}' FROM public.docs WHERE ts >= '2026-04-01'::timestamptz;

-- (H) A bound parameter as the path or keys. The rewrite needs its value, so the
-- read is planned from the value on every execution; seven executions cross the
-- plan cache's switch from custom to generic planning after the fifth. The heap
-- answers the same statements.
SET duckdb.force_execution = true;
PREPARE jpath(text[]) AS
  SELECT string_agg(coalesce(data #>> $1, '-'), ',' ORDER BY id) AS v FROM public.docs;
PREPARE jkey(text) AS
  SELECT string_agg(coalesce(((data::jsonb) ? $1)::text, '-'), ',' ORDER BY id) AS v FROM public.docs;
PREPARE jkeys(text[]) AS
  SELECT string_agg(coalesce(((data::jsonb) ?| $1)::text, '-') || '/' ||
                    coalesce(((data::jsonb) ?& $1)::text, '-'), ',' ORDER BY id) AS v FROM public.docs;
PREPARE jdoc(jsonb) AS
  SELECT string_agg(coalesce(((data::jsonb) @> $1)::text, '-'), ',' ORDER BY id) AS v FROM public.docs;
EXECUTE jpath('{a,0}');
EXECUTE jpath('{a,-1}');
EXECUTE jpath('{a,01}');
EXECUTE jpath('{-1}');
EXECUTE jpath('{o,b}');
EXECUTE jpath('{4,k}');
EXECUTE jpath('{""}');
EXECUTE jkey('k');
EXECUTE jkey('0');
EXECUTE jkey('-1');
EXECUTE jkey('');
EXECUTE jkey('*');
EXECUTE jkey('q"k');
EXECUTE jkey('zz');
EXECUTE jkeys('{zz,k}');
EXECUTE jkeys('{k,a}');
EXECUTE jkeys('{}');
EXECUTE jkeys('{k,NULL}');
EXECUTE jkeys('{zz}');
EXECUTE jkeys('{a}');
EXECUTE jkeys('{k}');
EXECUTE jdoc('{"o": {"b": "c"}}');
EXECUTE jdoc('"k"');
EXECUTE jdoc('[["k"]]');
EXECUTE jdoc('{"b": "c"}');
EXECUTE jdoc('{}');
EXECUTE jdoc('[]');
EXECUTE jdoc('{"a": [3, 1]}');
RESET duckdb.force_execution;
PREPARE hpath(text[]) AS
  SELECT string_agg(coalesce(data #>> $1, '-'), ',' ORDER BY id) AS v FROM public._docs;
PREPARE hkey(text) AS
  SELECT string_agg(coalesce(((data::jsonb) ? $1)::text, '-'), ',' ORDER BY id) AS v FROM public._docs;
PREPARE hkeys(text[]) AS
  SELECT string_agg(coalesce(((data::jsonb) ?| $1)::text, '-') || '/' ||
                    coalesce(((data::jsonb) ?& $1)::text, '-'), ',' ORDER BY id) AS v FROM public._docs;
PREPARE hdoc(jsonb) AS
  SELECT string_agg(coalesce(((data::jsonb) @> $1)::text, '-'), ',' ORDER BY id) AS v FROM public._docs;
EXECUTE hpath('{a,0}');
EXECUTE hpath('{a,-1}');
EXECUTE hpath('{a,01}');
EXECUTE hpath('{-1}');
EXECUTE hpath('{o,b}');
EXECUTE hpath('{4,k}');
EXECUTE hpath('{""}');
EXECUTE hkey('k');
EXECUTE hkey('0');
EXECUTE hkey('-1');
EXECUTE hkey('');
EXECUTE hkey('*');
EXECUTE hkey('q"k');
EXECUTE hkey('zz');
EXECUTE hkeys('{zz,k}');
EXECUTE hkeys('{k,a}');
EXECUTE hkeys('{}');
EXECUTE hkeys('{k,NULL}');
EXECUTE hkeys('{zz}');
EXECUTE hkeys('{a}');
EXECUTE hkeys('{k}');
EXECUTE hdoc('{"o": {"b": "c"}}');
EXECUTE hdoc('"k"');
EXECUTE hdoc('[["k"]]');
EXECUTE hdoc('{"b": "c"}');
EXECUTE hdoc('{}');
EXECUTE hdoc('[]');
EXECUTE hdoc('{"a": [3, 1]}');

-- (I) plpgsql variables as the path or key reach the planner through the
-- parameter-fetch hook; each loop crosses the same custom-to-generic switch. The
-- function reads the view, through DuckDB, or the heap.
SET duckdb.unsafe_allow_execution_inside_functions = true;
CREATE FUNCTION public.json_ops_by_var(heap bool) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  out text := '';
  k   text;
  p   text;
BEGIN
  FOREACH k IN ARRAY ARRAY['k', '0', '-1', '', '*', 'zz', 'k'] LOOP
    IF heap THEN
      out := out || (SELECT count(*) FROM public._docs WHERE (data::jsonb) ? k) || ' ';
    ELSE
      out := out || (SELECT count(*) FROM public.docs WHERE (data::jsonb) ? k) || ' ';
    END IF;
  END LOOP;
  FOREACH p IN ARRAY ARRAY['a,0', 'a,-1', 'a,01', '-1', 'o,b', '4,k', 'a,9'] LOOP
    IF heap THEN
      out := out || (SELECT string_agg(coalesce(data #>> string_to_array(p, ','), '-'), ',' ORDER BY id)
                     FROM public._docs) || ' ';
    ELSE
      out := out || (SELECT string_agg(coalesce(data #>> string_to_array(p, ','), '-'), ',' ORDER BY id)
                     FROM public.docs) || ' ';
    END IF;
  END LOOP;
  RETURN out;
END $$;
SET duckdb.force_execution = true;
SELECT public.json_ops_by_var(false) AS duckdb;
RESET duckdb.force_execution;
SELECT public.json_ops_by_var(true) AS postgres;

-- (J) A jsonb document that is itself a bound parameter, not a ::jsonb cast the
-- rewrite turns into json, reaches the planner hook the same way. The plan counts
-- show every prepared read above ran on custom plans built from its values.
SET duckdb.force_execution = true;
PREPARE jdocpath(jsonb, text[]) AS
  SELECT string_agg(coalesce($1 #>> $2, '-'), ',' ORDER BY id) AS v FROM public.docs;
EXECUTE jdocpath('{"a": [7, 8, 9]}', '{a,1}');
EXECUTE jdocpath('{"a": [7, 8, 9]}', '{a,-1}');
RESET duckdb.force_execution;
SELECT name, generic_plans, custom_plans FROM pg_prepared_statements
 WHERE name IN ('jpath', 'jkey', 'jkeys', 'jdoc', 'jdocpath') ORDER BY name;

-- (K) A path element PostgreSQL may read as an array index or as an object key
-- (-1, 01, +1) doubles the rewritten expression, so a path holds at most eight.
SET duckdb.force_execution = true;
SELECT count(data #> '{-1,-1,-1,-1,-1,-1,-1,-1}') AS eight FROM public.docs;
SELECT count(data #> '{-1,-1,-1,-1,-1,-1,-1,-1,-1}') AS nine FROM public.docs;
RESET duckdb.force_execution;

-- Cleanup.
DEALLOCATE jdocpath;
DEALLOCATE jpath;
DEALLOCATE jkey;
DEALLOCATE jkeys;
DEALLOCATE jdoc;
DEALLOCATE hpath;
DEALLOCATE hkey;
DEALLOCATE hkeys;
DEALLOCATE hdoc;
DROP FUNCTION public.json_ops_by_var(bool);
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.docs;
DROP TABLE public._docs;
