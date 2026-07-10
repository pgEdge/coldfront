-- White-box test for vended (minted) credential mode. Vended rows carry NO
-- object-store credentials: _build_storage_secret_opts returns NULL (nothing is
-- materialized as a DuckDB secret), the CHECK guards allow the creds-NULL row,
-- and _attach_delegation_mode() reports VENDED_CREDENTIALS so ensure_attached
-- turns on catalog credential vending. This asserts row/constraint/mode shaping,
-- not DuckDB I/O (the live vend is the 1.5.x e2e's job); the s3/azure opts
-- branches themselves are covered by storage_secret_azure.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

-- ---- vended rows produce NO secret body, for either backend
SELECT coldfront._build_storage_secret_opts(ROW(
    'cf_storage','s3',NULL,NULL,NULL,'us-east-1','path',false,NULL,true
)::coldfront.storage_secret) IS NULL AS s3_vended_opts_null;

SELECT coldfront._build_storage_secret_opts(ROW(
    'cf_storage','azure',NULL,NULL,NULL,'us-east-1','path',false,NULL,true
)::coldfront.storage_secret) IS NULL AS azure_vended_opts_null;

-- ---- constraint relaxation: a vended s3 row with NULL key_id/secret is
-- accepted, but a NON-vended s3 row still needs creds (ss_s3_creds unchanged).
SET coldfront.local_pg_dsn = '';
ALTER TABLE coldfront.storage_secret DISABLE TRIGGER coldfront_storage_secret_materialize;
DELETE FROM coldfront.storage_secret;

INSERT INTO coldfront.storage_secret (name, storage_type, vended)
       VALUES ('v', 's3', true);
DELETE FROM coldfront.storage_secret;
-- still rejected when not vended
INSERT INTO coldfront.storage_secret (name, storage_type) VALUES ('bad', 's3');

-- ---- delegation mode + setter round-trips. Empty table ⇒ NONE.
SELECT coldfront._attach_delegation_mode() AS mode_no_row;

SELECT coldfront.set_storage_secret_vended();
SELECT storage_type, key_id, secret, connection_string, vended
  FROM coldfront.storage_secret WHERE name = 'cf_storage';
SELECT coldfront._attach_delegation_mode() AS mode_vended;

-- azure vended keeps storage_type='azure' (so ensure_attached still LOADs azure)
SELECT coldfront.set_storage_secret_vended('azure');
SELECT storage_type, vended FROM coldfront.storage_secret WHERE name = 'cf_storage';

-- unsupported backend rejected
SELECT coldfront.set_storage_secret_vended('gcs');

-- a static setter flips vended back off and restores creds
SELECT coldfront.set_storage_secret('admin', 'adminsecret');
SELECT storage_type, key_id, secret, vended
  FROM coldfront.storage_secret WHERE name = 'cf_storage';
SELECT coldfront._attach_delegation_mode() AS mode_static;

ALTER TABLE coldfront.storage_secret ENABLE ALWAYS TRIGGER coldfront_storage_secret_materialize;
DELETE FROM coldfront.storage_secret;
