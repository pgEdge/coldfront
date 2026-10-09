# Reading and Writing ColdFront Tables

The same SQL works against the relation name in either mode, as the following
examples show:

```sql
-- Reads - pg_duckdb handles the iceberg side; PG handles the heap side
SELECT count(*) FROM events;
SELECT id, status, data->>'k' FROM events WHERE ts >= '2026-04-01';

-- Inserts, updates, and deletes all go through the coldfront C hook,
-- which rewrites the query into one PG-set-based statement (hot side)
-- + duckdb.raw_query calls (cold side). For iceberg-only mode every write
-- goes cold; for tiered mode the hook splits by ts vs the watermark.
INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{"k":1}');
UPDATE events SET status = 'fixed' WHERE id = 123;
DELETE FROM events WHERE ts < '2025-01-01';

-- Bulk INSERT shapes: the source is read once, the hot rows are one
-- set-based INSERT and the cold rows are written in batches:
INSERT INTO events (ts, status, data) VALUES (...), (...), (...);
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM staging;
INSERT INTO events (ts, status, data) SELECT now() + i*'1s'::interval, 'ok', '{}'
                                       FROM generate_series(1, 1000) i;
-- A WITH clause works in both positions; a nested INSERT takes no RETURNING:
WITH moved AS (DELETE FROM staging RETURNING ts, status, data)
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM moved;
WITH i AS (INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{}'))
SELECT 1;
-- COPY FROM loads the same way, one INSERT per cold_write_batch_size rows:
COPY events (ts, status, data) FROM '/path/to/events.csv' WITH (FORMAT csv);

-- Transactions work; ROLLBACK undoes Iceberg writes too
BEGIN;
  UPDATE events SET status = 'pending' WHERE id = 1;
  SELECT status FROM events WHERE id = 1;   -- sees 'pending' if row 1 is hot
ROLLBACK;
SELECT status FROM events WHERE id = 1;     -- back to whatever it was
```
