-- coldfront.cold_write_batch_size is a GUC (DefineCustomIntVariable; default
-- 10000, min 1) that coldfront._tiered_insert_cold reads to size each cold-tier
-- Iceberg flush (one duckdb.raw_query / Parquet file per batch). White-box: this
-- checks the GUC's definition, default, settability, and lower bound — the flush
-- behavior itself is exercised live in ci/journey.sh.

CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- Default is 10000.
SHOW coldfront.cold_write_batch_size;

-- Settable per session.
SET coldfront.cold_write_batch_size = 500;
SHOW coldfront.cold_write_batch_size;

-- Lower bound is 1 (a non-positive batch would never flush) — rejected.
SET coldfront.cold_write_batch_size = 0;

-- RESET returns to the default.
RESET coldfront.cold_write_batch_size;
SHOW coldfront.cold_write_batch_size;
