# pgEdge ColdFront

ColdFront stores PostgreSQL tables in Apache Iceberg (Parquet on
S3-compatible storage) while the application queries them as ordinary
PostgreSQL relations. ColdFront offers two operating modes, and both
present the same standard SQL surface to the application.

ColdFront provides two operating modes:

- Tiered mode keeps recent data in native PostgreSQL partitions and
  archives older data to Iceberg on a watermark; the application reads a
  single unified view, and the archiver moves rows from hot to cold on a
  schedule.
- Decoupled mode stores the table entirely in Iceberg from the first
  row; PostgreSQL holds a thin wrapper view and a registry row, and the
  coldfront extension handles every data-modifying statement on that
  view.

Both modes coexist within a single database, and you choose the mode per
table at creation time. The SQL surface is identical for both modes:
standard SELECT, INSERT, UPDATE, and DELETE against the relation.

Decoupled mode scales out horizontally across many PostgreSQL nodes that
share one Lakekeeper catalog and one object store. The bakery protocol
in the coldfront extension serializes Iceberg commits on the PostgreSQL
side using Spock-replicated Snowflake tickets, so concurrent writers
never collide at the catalog. The protocol implements Lamport mutual
exclusion with the Ricart-Agrawala deferred-reply optimization, and a
TLA+ model verifies its safety.
