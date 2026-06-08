-- White-box test for the storage-secret opts builder and the azure setter.
-- We assert the GENERATED DuckDB secret body (coldfront._build_storage_secret_opts)
-- for the s3 (regression guard) and azure branches; we do NOT fire the
-- materialize trigger's duckdb.raw_query (no live DuckDB secret dir, and a
-- TYPE azure secret needs the azure extension — that's the 1.5.x e2e's job).
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- ---- pure opts builder: s3, AWS default (no endpoint) — byte-identical to legacy
SELECT coldfront._build_storage_secret_opts(ROW(
    'cf_storage','s3','admin','adminsecret',NULL,'us-east-1','path',false,NULL
)::coldfront.storage_secret);

-- ---- pure opts builder: s3, S3-compatible (endpoint set → path-style + USE_SSL)
SELECT coldfront._build_storage_secret_opts(ROW(
    'cf_storage','s3','admin','adminsecret','seaweedfs:8333','us-east-1','path',true,NULL
)::coldfront.storage_secret);

-- ---- pure opts builder: azure CONFIG provider via CONNECTION_STRING (shared key
-- rides inside AccountKey=… — duckdb-azure has no ACCOUNT_KEY param)
SELECT coldfront._build_storage_secret_opts(ROW(
    'cf_storage','azure',NULL,NULL,NULL,'us-east-1','path',false,
    'DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=Zm9v;EndpointSuffix=core.windows.net'
)::coldfront.storage_secret);

-- ---- CHECK guards: a bad row is rejected BEFORE the AFTER trigger fires
-- azure row with no connection_string → ss_azure_conn
INSERT INTO coldfront.storage_secret (name, storage_type) VALUES ('bad', 'azure');
-- s3 row with no secret → ss_s3_creds
INSERT INTO coldfront.storage_secret (name, storage_type, key_id) VALUES ('bad2', 's3', 'k');

-- ---- setter row-shaping round-trip. DISABLE the materialize trigger first (on a
-- build without the azure extension its raw_query CREATE PERSISTENT SECRET
-- (TYPE azure) would raise); clear local_pg_dsn so install_extension is skipped.
-- This asserts the ROW each setter writes, not DuckDB I/O.
SET coldfront.local_pg_dsn = '';
ALTER TABLE coldfront.storage_secret DISABLE TRIGGER coldfront_storage_secret_materialize;
DELETE FROM coldfront.storage_secret;

SELECT coldfront.set_storage_secret_azure(
    'DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=Zm9v;EndpointSuffix=core.windows.net');
SELECT storage_type, key_id, secret, endpoint, connection_string
  FROM coldfront.storage_secret WHERE name = 'cf_storage';

-- s3 setter must flip storage_type back to s3 and clear connection_string
SELECT coldfront.set_storage_secret('admin', 'adminsecret');
SELECT storage_type, key_id, secret, connection_string
  FROM coldfront.storage_secret WHERE name = 'cf_storage';

ALTER TABLE coldfront.storage_secret ENABLE ALWAYS TRIGGER coldfront_storage_secret_materialize;
DELETE FROM coldfront.storage_secret;
