-- Every coldfront.* setting is registered in _PG_init: it has a type, a
-- default, bounds and a context, and the prefix is reserved, so a mistyped
-- name is refused instead of being kept as a placeholder.
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
DROP ROLE IF EXISTS cf_settings_app;
RESET client_min_messages;

SELECT name, vartype, context, boot_val, min_val
  FROM pg_settings WHERE name LIKE 'coldfront.%' ORDER BY name COLLATE "C";

-- The bakery's dead-peer window is superuser-only and at least 1 ms.
CREATE ROLE cf_settings_app;
SET ROLE cf_settings_app;
SET coldfront.peer_alive_window_ms = 1;
RESET ROLE;
SET coldfront.peer_alive_window_ms = 0;
SHOW coldfront.peer_alive_window_ms;

-- A name under the reserved prefix that is not a setting is refused.
SET coldfront.peer_alive_window = 1;

-- The async switch stays session-settable: the cross-tier move and the Iceberg
-- ALTER path SET LOCAL it.
BEGIN;
SET LOCAL coldfront.iceberg_async_parquet = off;
SHOW coldfront.iceberg_async_parquet;
COMMIT;

DROP ROLE cf_settings_app;
