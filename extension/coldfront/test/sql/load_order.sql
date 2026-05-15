-- Verify the extension loads and its catalog table exists.
CREATE EXTENSION IF NOT EXISTS coldfront;

SELECT count(*) FROM coldfront.tiered_views;

-- GUCs are settable (coldfront doesn't register them; ensure_attached()
-- reads them via current_setting(..., missing_ok=true)). SET them to known
-- values so SHOW output is deterministic across environments.
SET coldfront.warehouse = 'wh';
SET coldfront.lakekeeper_endpoint = 'http://example/catalog';
SHOW coldfront.warehouse;
SHOW coldfront.lakekeeper_endpoint;
