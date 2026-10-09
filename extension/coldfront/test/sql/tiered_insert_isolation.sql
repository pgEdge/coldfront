-- Both tiers of a tiered INSERT see one snapshot, the one PostgreSQL gave the
-- statement, whatever another session commits meanwhile, and the transaction's
-- isolation level holds across the tiers: READ COMMITTED streams each statement
-- from its own snapshot, REPEATABLE READ streams from the transaction's, and
-- SERIALIZABLE fails as native tables do. The other session is the bakery's
-- loopback, pointed at this server. cold_rows is NULL when the cold rows
-- streamed and their count when the sink wrote them.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET TIME ZONE 'UTC';
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SELECT set_config('coldfront.local_pg_dsn',
                  format('host=%s dbname=%s user=%s',
                         trim(split_part(current_setting('unix_socket_directories'), ',', 1)),
                         current_database(), current_user), false) <> '' AS dsn_set;
SELECT set_config('coldfront.loopback_dsn',
                  format('host=%s dbname=%s user=%s',
                         trim(split_part(current_setting('unix_socket_directories'), ',', 1)),
                         current_database(), current_user), false) <> '' AS loopback_set;
SELECT duckdb.raw_query('CREATE TEMP TABLE cf_iso (id BIGINT, ts TIMESTAMPTZ, status VARCHAR)') IS NOT NULL AS created;

CREATE TABLE public._cf_iso (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL, status text);
CREATE VIEW public.cf_iso AS SELECT * FROM public._cf_iso;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'cf_iso', 'public._cf_iso', 'temp.main.cf_iso', 'ts');
INSERT INTO coldfront.archive_watermark(schema_name, table_name, cutoff_time)
VALUES ('public', 'cf_iso', '2026-03-01'::timestamptz);
CREATE TABLE public.cf_iso_src (ts timestamptz, status text);
INSERT INTO public.cf_iso_src VALUES ('2026-01-01', 'cold'), ('2026-05-01', 'hot');
CREATE VIEW public.cf_iso_cold AS
    SELECT r['ts']::timestamptz AS ts, r['status']::text AS status
      FROM duckdb.query('SELECT * FROM temp.main.cf_iso') AS t(r);

-- (1) READ COMMITTED: another session commits a change to the source while
--     the statement runs, between its hot half and its cold half. A statement
--     trigger on the hot table fires before the hot INSERT and commits the
--     change through the loopback. The cold half reads the statement's
--     snapshot, so the cold tier holds the row as the hot half saw it.
CREATE FUNCTION public.cf_iso_meddle() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM coldfront._loopback('UPDATE public.cf_iso_src SET status = ''late'' WHERE status = ''cold''');
    RETURN NULL;
END;
$$;
CREATE TRIGGER cf_iso_meddle BEFORE INSERT ON public._cf_iso
    FOR EACH STATEMENT EXECUTE FUNCTION public.cf_iso_meddle();
INSERT INTO public.cf_iso (ts, status) SELECT ts, status FROM public.cf_iso_src;
DROP TRIGGER cf_iso_meddle ON public._cf_iso;
SELECT status FROM public.cf_iso_cold;
SELECT status FROM public.cf_iso_src ORDER BY 1;

-- (2) A second streamed statement in one READ COMMITTED transaction cannot
--     give the second session a fresh snapshot, so it goes through the sink;
--     a VALUES source reads no table and streams regardless.
BEGIN;
INSERT INTO public.cf_iso (ts, status) SELECT ts, 'rc1' FROM public.cf_iso_src;
INSERT INTO public.cf_iso (ts, status) SELECT ts, 'rc2' FROM public.cf_iso_src;
INSERT INTO public.cf_iso (ts, status) VALUES ('2026-01-02', 'rc3');
COMMIT;
SELECT status FROM public.cf_iso_cold WHERE status LIKE 'rc%' ORDER BY 1;

-- (3) REPEATABLE READ: the cold half reads the transaction's snapshot, so a
--     row another session commits after it is on neither tier, and the second
--     statement streams from the same snapshot.
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) AS seen FROM public.cf_iso_src;
SELECT coldfront._loopback('INSERT INTO public.cf_iso_src VALUES (''2026-01-03'', ''rr-late'') RETURNING status') AS committed_elsewhere;
INSERT INTO public.cf_iso (ts, status) SELECT ts, status || '/rr1' FROM public.cf_iso_src;
INSERT INTO public.cf_iso (ts, status) SELECT ts, status || '/rr2' FROM public.cf_iso_src;
COMMIT;
SELECT status FROM public.cf_iso_cold WHERE status LIKE '%/rr%' ORDER BY 1;
SELECT status FROM public._cf_iso WHERE status LIKE '%/rr%' ORDER BY 1;
SELECT status FROM public.cf_iso_src ORDER BY 1;

-- (4) SERIALIZABLE: this transaction reads the source and writes the hot
--     table; the other session read the hot table and wrote the source, and
--     committed first. The cycle fails this transaction, as it would native
--     tables, and the cold tier keeps nothing from it.
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT count(*) AS seen FROM public.cf_iso_src WHERE status IN ('late', 'hot');
SELECT coldfront._loopback('BEGIN ISOLATION LEVEL SERIALIZABLE; SELECT count(*) FROM public._cf_iso; UPDATE public.cf_iso_src SET status = ''skew'' WHERE status = ''late''; COMMIT; SELECT ''committed''') AS committed_elsewhere;
INSERT INTO public.cf_iso (ts, status) SELECT ts, status || '/ser' FROM public.cf_iso_src WHERE status IN ('late', 'hot');
COMMIT;
SELECT count(*) AS serializable_rows
  FROM (SELECT status FROM public.cf_iso_cold UNION ALL SELECT status FROM public._cf_iso) AS u
 WHERE status LIKE '%/ser';
