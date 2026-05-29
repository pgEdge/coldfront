-- The archiver detaches partitions from the hot parent during cutover
-- (ALTER TABLE _events DETACH PARTITION ...). That is coldfront's OWN internal
-- machinery, not a user schema change. The DDL hook must pass non-column-shape
-- ALTERs straight through — it must NOT rebuild the transparent view, which
-- would bloat the archiver's ACCESS EXCLUSIVE lock window and churn the
-- registry view_oid on every archive cycle.
--
-- Regression guard: only ADD/DROP COLUMN and ALTER COLUMN TYPE (and RENAME)
-- trigger a rebuild. DETACH PARTITION, SET STATISTICS, storage params, etc.
-- are none of coldfront's business.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.dblink_self = '';

CREATE TABLE public._events (id int, ts timestamptz, status text)
  PARTITION BY RANGE (ts);
CREATE TABLE public._events_p1 PARTITION OF public._events
  FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE VIEW public.events AS SELECT * FROM public._events;

INSERT INTO coldfront.tiered_views(view_oid, hot_table, iceberg_table, partition_col)
VALUES ('public.events'::regclass, 'public._events', 'ice.default.events', 'ts');

-- (1) Archiver-style DETACH PARTITION on the hot parent must pass through with
-- NO view rebuild. The view OID stays put — a rebuild would DROP+CREATE and
-- mint a new OID.
SELECT 'public.events'::regclass::oid AS oid_before \gset
ALTER TABLE public._events DETACH PARTITION public._events_p1;
SELECT ('public.events'::regclass::oid = :oid_before) AS detach_left_view_intact;

-- (2) A non-column ALTER (SET STATISTICS) also passes through untouched.
SELECT 'public.events'::regclass::oid AS oid_before2 \gset
ALTER TABLE public._events ALTER COLUMN status SET STATISTICS 50;
SELECT ('public.events'::regclass::oid = :oid_before2) AS setstats_left_view_intact;

-- (3) But a real column change DOES still rebuild (gate works both ways): the
-- view OID changes because _rebuild_tiered_view DROP+CREATEs the view.
SELECT 'public.events'::regclass::oid AS oid_before3 \gset
ALTER TABLE public._events ADD COLUMN extra text;
SELECT ('public.events'::regclass::oid <> :oid_before3) AS addcolumn_rebuilt_view;
SELECT attname FROM pg_attribute
 WHERE attrelid = 'public.events'::regclass AND attnum > 0 AND NOT attisdropped
 ORDER BY attnum;

-- Cleanup.
DELETE FROM coldfront.tiered_views;
DROP VIEW public.events;
DROP TABLE public._events;
DROP TABLE public._events_p1;
