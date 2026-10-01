-- A transaction block in which a statement failed still ends: ROLLBACK, COMMIT
-- and ROLLBACK TO SAVEPOINT each leave the session usable, though they reach
-- coldfront's hooks after the transaction's resources are released.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

BEGIN;
SELECT 1/0;
ROLLBACK;
SELECT 'rollback ended the block' AS result;

BEGIN;
SELECT 1/0;
COMMIT;
SELECT 'commit ended the block' AS result;

BEGIN;
SAVEPOINT s;
SELECT 1/0;
ROLLBACK TO SAVEPOINT s;
SELECT 'the block continues after the savepoint' AS result;
COMMIT;
