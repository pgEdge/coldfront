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
`RETURNING`.

Follow the guide for the mode you want:

- [Using ColdFront in Tiered Mode](../usage_tiered.md) archives aging
  partitions to Iceberg while recent rows stay in the PostgreSQL heap.
- [Using ColdFront in Decoupled Mode](../usage_decoupled.md) keeps every row
  in Iceberg from the start.
- [Using ColdFront in Standalone Partitioned Mode](../usage_partitioner.md)
  manages plain PostgreSQL partitions with no cold tier at all.

Operational topics shared across modes - caveats, vended credentials,
reading and writing, supported types, and distributed (mesh) setup - are
documented under Administration, starting with
[Caveats](../caveats.md).

