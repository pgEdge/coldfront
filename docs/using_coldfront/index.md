# Using ColdFront

ColdFront offers three operating modes. Pick one per table; tables in
different modes can coexist in the same database. The following table
compares the two modes that use the cold Iceberg tier:

| | Tiered (hot + cold) | Decoupled (iceberg-only) |
|---|---|---|
| Where rows live | Recent rows are hot in the PG heap, and archived rows are cold in Iceberg. | Every row is in Iceberg. |
| Setup | Create a partitioned table and let the archiver convert it on the first run that finds a partition older than `hot_period`. | One SQL call, `coldfront.create_iceberg_table(...)`, sets up the table. |
| Archiver | The archiver is required; it runs from cron and moves old partitions to cold. | The archiver is not used. |
| Best when | The workload has a recent-row OLTP part that benefits from PG indexes and transactional ergonomics. | The workload is purely analytic or append-mostly, and you want zero PG storage and stateless compute. |

Once a tiered or decoupled table exists, **the SQL surface is identical**:
`SELECT`, `INSERT`, `UPDATE`, `DELETE` all work normally against the relation
name (e.g. `events`), except that a write touching the cold tier rejects
`RETURNING`, as the following examples show:

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

Follow the guide for the mode you want:

- [Using ColdFront in Tiered Mode](../usage_tiered.md) archives aging
  partitions to Iceberg while recent rows stay in the PostgreSQL heap.
- [Using ColdFront in Decoupled Mode](../usage_decoupled.md) keeps every row
  in Iceberg from the start.
- [Using ColdFront in Standalone Partitioned Mode](../usage_partitioner.md)
  manages plain PostgreSQL partitions with no cold tier at all.

Operational topics shared across modes - caveats, vended credentials,
supported types, and distributed (mesh) setup - are documented under
Administration, starting with [Caveats](../caveats.md).

