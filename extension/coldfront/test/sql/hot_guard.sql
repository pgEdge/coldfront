-- The hot table's guards: a CHECK on each column of a tiered table's hot table
-- whose type admits a value the cold tier cannot hold unchanged, numeric NaN and
-- date, timestamp or timestamptz infinity, refusing it where it is written.
-- White-box: no catalog, no Iceberg I/O; the archiver's onboarding and the cold
-- tier are ci/journey.sh's.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';
SET coldfront.loopback_dsn = '';

-- The defect the NaN guard keeps out of the hot table. pg_duckdb (c04e6a2,
-- DuckDB v1.5.4) plans every read of a tiered view after its first archive and
-- the archiver's bulk export, and its scan reads a numeric NaN as 0. When this
-- output changes, pg_duckdb keeps or refuses NaN, and the NaN guard rests on
-- DuckDB's postgres extension alone (ci/journey.sh TC-234).
CREATE TABLE guard_scan_probe (n numeric(10,2));
INSERT INTO guard_scan_probe VALUES ('NaN');
SET duckdb.force_execution = true;
SELECT n FROM guard_scan_probe;
RESET duckdb.force_execution;
DROP TABLE guard_scan_probe;

-- A hot table as the archiver leaves it: partitioned, renamed, registered.
CREATE TABLE public._guarded (id bigint, ts timestamptz NOT NULL, amount numeric(10,2),
                              due date, logged timestamp, note text)
    PARTITION BY RANGE (ts);
CREATE TABLE public._guarded_p1 PARTITION OF public._guarded
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
INSERT INTO public._guarded VALUES (1, '2026-01-05', 1.25, '2026-02-01', '2026-01-05 10:00', 'x');

-- One guard per numeric, date or timestamp column and none for the others,
-- recorded NOT VALID so adding them scans nothing; the partition inherits them.
SELECT coldfront._guard_hot_table('public._guarded'::regclass);
SELECT conrelid::regclass AS rel, conname, convalidated, pg_get_constraintdef(oid) AS def
  FROM pg_constraint WHERE conname LIKE 'coldfront_guard_%' ORDER BY 1, 2;

-- A second call finds the guards and adds nothing.
SELECT coldfront._guard_hot_table('public._guarded'::regclass);
SELECT count(*) AS checks FROM pg_constraint
 WHERE conrelid = 'public._guarded'::regclass AND contype = 'c';

-- Validation scans the rows already there, in a transaction of its own, under
-- the lock VALIDATE CONSTRAINT takes, SHARE UPDATE EXCLUSIVE, which INSERT,
-- UPDATE and DELETE do not wait for.
BEGIN;
SELECT coldfront._validate_hot_guards('public._guarded'::regclass);
SELECT mode FROM pg_locks
 WHERE locktype = 'relation' AND relation = 'public._guarded'::regclass
   AND pid = pg_backend_pid()
 ORDER BY mode;
COMMIT;
SELECT conrelid::regclass AS rel, conname, convalidated
  FROM pg_constraint WHERE conname LIKE 'coldfront_guard_%' ORDER BY 1, 2;

-- NaN and infinity are refused where they are written, by INSERT and by UPDATE;
-- NULL is neither.
INSERT INTO public._guarded VALUES (2, '2026-01-06', 'NaN', NULL, NULL, 'y');
UPDATE public._guarded SET amount = 'NaN' WHERE id = 1;
INSERT INTO public._guarded VALUES (2, '2026-01-06', 1, 'infinity', NULL, 'y');
UPDATE public._guarded SET logged = '-infinity' WHERE id = 1;
INSERT INTO public._guarded VALUES (3, '2026-01-07', NULL, NULL, NULL, 'z');
SELECT id, amount, due, logged FROM public._guarded ORDER BY id;

-- A timestamptz column refuses infinity as well.
CREATE TABLE public._guarded_tz (ts timestamptz NOT NULL, seen timestamptz) PARTITION BY RANGE (ts);
CREATE TABLE public._guarded_tz_p1 PARTITION OF public._guarded_tz
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
SELECT coldfront._guard_hot_table('public._guarded_tz'::regclass);
INSERT INTO public._guarded_tz VALUES ('2026-01-05', 'infinity');
INSERT INTO public._guarded_tz VALUES ('2026-01-05', '-infinity');
DROP TABLE public._guarded_tz;

-- A guard is named after its column. A column name longer than the 47 bytes the
-- prefix leaves is hashed instead, so two long names that share their first 47
-- bytes get a guard each.
CREATE TABLE public._guarded_long (ts timestamptz NOT NULL,
    amount_in_the_reporting_currency_before_any_tax_a numeric(10,2),
    amount_in_the_reporting_currency_before_any_tax_b numeric(10,2))
    PARTITION BY RANGE (ts);
SELECT coldfront._guard_hot_table('public._guarded_long'::regclass);
SELECT a.attname, c.conname FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
 WHERE c.conrelid = 'public._guarded_long'::regclass AND c.contype = 'c'
 ORDER BY a.attnum;
DROP TABLE public._guarded_long;

-- A row that already holds NaN fails the validation, which names the guard and
-- so the column.
CREATE TABLE public._guarded_nan (ts timestamptz NOT NULL, amount numeric(10,2)) PARTITION BY RANGE (ts);
CREATE TABLE public._guarded_nan_p1 PARTITION OF public._guarded_nan
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
INSERT INTO public._guarded_nan VALUES ('2026-01-05', 'NaN');
SELECT coldfront._guard_hot_table('public._guarded_nan'::regclass);
SELECT coldfront._validate_hot_guards('public._guarded_nan'::regclass);
DROP TABLE public._guarded_nan;

-- A column added through the DDL hook gets its guard from the view rebuild, which
-- runs on every node. Under the apply-worker role the Iceberg mirror is skipped,
-- so this needs no catalog.
CREATE VIEW public.guarded AS SELECT * FROM public._guarded;
INSERT INTO coldfront.tiered_views(schema_name, relname, hot_table, iceberg_table, partition_col)
VALUES ('public', 'guarded', 'public._guarded', 'ice.default.guarded', 'ts');
SET session_replication_role = replica;
ALTER TABLE public._guarded ADD COLUMN fee numeric(8,3);
SET session_replication_role = DEFAULT;
SELECT conname, convalidated FROM pg_constraint
 WHERE conrelid = 'public._guarded'::regclass AND contype = 'c' ORDER BY conname;

-- A guard follows its column through a rename, on the partitions too, so a
-- column that later takes the old name gets a guard of its own.
SET session_replication_role = replica;
ALTER TABLE public._guarded RENAME COLUMN fee TO fee_old;
ALTER TABLE public._guarded ADD COLUMN fee numeric(8,3);
SET session_replication_role = DEFAULT;
SELECT c.conrelid::regclass AS rel, c.conname, a.attname, c.convalidated
  FROM pg_constraint c
  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
 WHERE c.conrelid IN ('public._guarded'::regclass, 'public._guarded_p1'::regclass)
   AND c.contype = 'c' AND a.attname LIKE 'fee%'
 ORDER BY 1, 2;

-- Unregistering returns the hot table to its owner as it was, guards gone.
SELECT coldfront._unregister_iceberg('public', 'guarded');
SELECT count(*) AS checks FROM pg_constraint
 WHERE conrelid = 'public.guarded'::regclass AND contype = 'c';
DROP TABLE public.guarded;
