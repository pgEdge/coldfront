-- An UPDATE that assigns the partition column of a tiered view is blocked: such
-- a SET can move the row across the hot/cold cutoff, which the in-place rewrite
-- would lose silently (GitHub #20). The hook must ereport(ERROR) with SQLSTATE
-- 0A000 (ERRCODE_FEATURE_NOT_SUPPORTED) regardless of coldfront.allow_mixed_writes
-- and regardless of which tier the WHERE selects. Relocating the row is a separate
-- feature; until then the partition column is read-only via the view.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET TIME ZONE 'UTC';
-- White-box: checks the hooks' SQL/DDL, not Iceberg I/O. Real cold I/O is ci/journey.sh; see README.md.
SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

CREATE TABLE public._events (id int, ts timestamptz, status text);
INSERT INTO public._events VALUES (1, '2026-04-01 12:00:00+00', 'hot_orig');
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'events', 'public._events', 'ice.default.events', 'ts');
INSERT INTO coldfront.archive_watermark(table_name, cutoff_time)
VALUES ('events', '2026-03-01'::timestamptz);

-- Permissive mode (default): a partition-column SET is still blocked, because
-- the move is not implemented and the dual-tier rewrite would lose the row.
SET coldfront.allow_mixed_writes = on;

-- Cold→hot crossing (the #20 repro): blocked.
UPDATE public.events SET ts = '2026-06-18 10:00:00+00' WHERE status = 'hot_orig';

-- Hot→cold crossing: blocked too (symmetric loss).
UPDATE public.events SET ts = '2026-01-05 10:00:00+00' WHERE ts = '2026-04-01 12:00:00+00';

-- Same-tier constant SET is also blocked (blunt block; no per-value proof).
UPDATE public.events SET ts = '2026-04-02 12:00:00+00' WHERE ts = '2026-04-01 12:00:00+00';

-- Non-constant partition-column SET (could cross per-row): blocked.
UPDATE public.events SET ts = ts + interval '6 months' WHERE id = 1;

-- A tier-deterministic WHERE does not rescue a partition-column SET: blocked.
UPDATE public.events SET ts = '2026-06-18 10:00:00+00' WHERE ts = '2026-01-15 01:00:00+00';

-- Strict mode: same block.
SET coldfront.allow_mixed_writes = off;
UPDATE public.events SET ts = '2026-06-18 10:00:00+00' WHERE status = 'hot_orig';

-- A SET that does NOT touch the partition column is unaffected (still routes by
-- WHERE tier — here hot, plain PG).
UPDATE public.events SET status = 'ok' WHERE ts = '2026-04-01 12:00:00+00';

-- _events: only the status update applied; every ts-changing statement errored.
SELECT id, ts, status FROM public._events ORDER BY id;

-- Cleanup. Unregister before dropping: the DDL hook blocks DROP of a
-- registered tiered table/view.
DELETE FROM coldfront.tiered_views;
DELETE FROM coldfront.archive_watermark;
DROP VIEW public.events;
DROP TABLE public._events;
