-- DuckDB names its spill files from a per-instance counter that starts at 0
-- (duckdb_temp_storage_<size>-<index>.tmp), so two backends sharing one
-- duckdb.temporary_directory write the same paths and read each other's bytes,
-- and a backend whose instance is torn down deletes every duckdb_temp_* file in
-- the directory, including a peer's live spills. coldfront gives each backend
-- its own subdirectory of the configured path, named after the backend PID, and
-- reclaims the subdirectories of backends that are gone. White-box: this checks
-- the GUC the backend ends up with; the reclaim is exercised in ci/journey.sh.
-- Suppress the run-order-dependent "already exists" NOTICE: in the shared regress
-- db an earlier test may have created the extensions, standalone not.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

-- The session's own PID is the last path component.
SELECT current_setting('duckdb.temporary_directory') LIKE '%/' || pg_backend_pid() AS ends_with_pid;

-- Appended once, however many statements the session has run: the PID does not
-- appear as an interior component, and the base path is still there.
SELECT current_setting('duckdb.temporary_directory')
         NOT LIKE '%/' || pg_backend_pid() || '/%' AS appended_once,
       current_setting('duckdb.temporary_directory') LIKE '%/pg_duckdb/temp/%' AS keeps_base;

-- A session that sets the path itself keeps what it asked for: that setting
-- outranks the source coldfront assigns, which is what makes coldfront's value
-- survive a rollback. RESET returns to this backend's own directory.
SET duckdb.temporary_directory = '/tmp/cf_regress_temp';
SELECT current_setting('duckdb.temporary_directory') = '/tmp/cf_regress_temp'
         AS session_set_wins;
RESET duckdb.temporary_directory;
SELECT current_setting('duckdb.temporary_directory') LIKE '%/' || pg_backend_pid()
         AS reset_returns_own;

-- The value holds across a rollback, so nothing re-sets it on a later statement
-- (pg_duckdb refuses this setting once its instance exists, which would then
-- error on an unrelated statement).
BEGIN;
SELECT 1 AS in_txn;
ROLLBACK;
SELECT current_setting('duckdb.temporary_directory') LIKE '%/' || pg_backend_pid()
         AS survives_rollback;
