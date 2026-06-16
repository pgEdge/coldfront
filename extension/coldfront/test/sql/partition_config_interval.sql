-- coldfront.partition_config.hot_period / retention_period are native PostgreSQL
-- `interval` columns (migrated from text). White-box: prove the column type is the
-- write-time backstop — a valid interval is accepted and stored canonically, a
-- non-interval is rejected at INSERT regardless of who writes it. The retention >
-- hot_period rule is operator-config policy enforced at the CLI boundary
-- (partition.ValidatePeriods), NOT a CHECK; the live register/archiver flow is
-- exercised in ci/journey.sh.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- Both lifecycle-period columns are interval-typed (partition_period stays text —
-- it is a cadence enum, not a duration).
SELECT attname, format_type(atttypid, atttypmod) AS type
  FROM pg_attribute
 WHERE attrelid = 'coldfront.partition_config'::regclass
   AND attname IN ('partition_period', 'hot_period', 'retention_period')
 ORDER BY attname;

-- A valid PG interval (a compound form the old "N unit" parser could never take)
-- is accepted and stored as a real interval. Compared as an interval (not its
-- text rendering) so the result is independent of the session's IntervalStyle.
INSERT INTO coldfront.partition_config (schema_name, table_name, partition_period, retention_period)
VALUES ('ivt', 'good', 'monthly', '1 year 2 mons');
SELECT retention_period = interval '1 year 2 mons' AS stored_ok
  FROM coldfront.partition_config WHERE schema_name = 'ivt' AND table_name = 'good';

-- A non-interval value is rejected by the column type at write time.
INSERT INTO coldfront.partition_config (schema_name, table_name, partition_period, retention_period)
VALUES ('ivt', 'bad', 'monthly', 'banana');

DELETE FROM coldfront.partition_config WHERE schema_name = 'ivt';
