-- coldfront.create_iceberg_namespace refuses a name it cannot send. The refusal
-- comes before any Iceberg call, so no catalog is needed. ci/journey.sh covers
-- the namespace the call creates.

SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
RESET client_min_messages;

SET coldfront.warehouse = '';
SET coldfront.lakekeeper_endpoint = '';

SELECT coldfront.create_iceberg_namespace(NULL);
SELECT coldfront.create_iceberg_namespace('');
