# pgEdge ColdFront

ColdFront keeps tables in PostgreSQL and, in its tiered and decoupled modes,
keeps cold data in Apache Iceberg (Parquet on S3-compatible, Azure, or GCS
storage). The cold tier is both readable and writable through the same SQL,
with no application changes. The application
queries every table as an ordinary PostgreSQL relation, with standard
`SELECT`, `INSERT`, `UPDATE`, and `DELETE`, and `MERGE` on PostgreSQL 17 and
later.

!!! warning "Beta software"

    ColdFront is beta software under active development. Do not use it in
    production. Interfaces, on-disk formats, and behavior may change without
    notice, and data loss is possible.

ColdFront provides three operating modes:

- Tiered mode keeps recent data in native PostgreSQL partitions and archives
  older data to Iceberg on a watermark; the application reads a single unified
  view, and the archiver moves rows from hot to cold on a schedule.
- Decoupled mode stores the table entirely in Iceberg from the first row;
  PostgreSQL holds a thin wrapper view and a registry row, and the `coldfront`
  extension handles every data-modifying statement on that view.
- Standalone partitioned mode manages time- or id-based PostgreSQL range
  partitions with no cold tier; the `partitioner` binary creates upcoming
  partitions and detaches and drops partitions past retention, on stock
  PostgreSQL with no DuckDB or Iceberg.

Tables in different modes can share one database, and you choose the mode for
each table: tiered when you register an existing partitioned table with a hot
period, standalone partitioned when you register one without a hot period,
and decoupled when you create or adopt an Iceberg table.

Decoupled mode scales out horizontally across many PostgreSQL nodes that share
one Lakekeeper catalog and one object store. The bakery protocol in the
`coldfront` extension serializes Iceberg commits on the PostgreSQL side using
Spock-replicated Snowflake tickets, so concurrent writers never collide at the
catalog. The protocol implements
[Lamport mutual exclusion](https://en.wikipedia.org/wiki/Lamport%27s_distributed_mutual_exclusion_algorithm)
with the
[Ricart-Agrawala](https://en.wikipedia.org/wiki/Ricart%E2%80%93Agrawala_algorithm)
deferred-reply optimization, and the
[formal model](formal/README.md) verifies its safety with TLA+.

## How It Works

ColdFront runs inside PostgreSQL and rewrites each statement to the correct
tier, so the application sees one relation:

```text
                            Application
                                │
                SELECT / INSERT / UPDATE / DELETE
                    on one relation: "events"
                                │
   ┌────────────────────────────▼─────────────────────────────┐
   │                 PostgreSQL 16 / 17 / 18                  │
   │                                                          │
   │  events view: reads return hot + cold rows               │
   │  coldfront extension: routes writes by tier.             │
   └───────────┬─────────────────────────────────┬────────────┘
               │                                 │
           HOT TIER                          COLD TIER
    recent rows, local disk         older rows, object storage
               │                                 │
    ┌──────────▼───────────┐        ┌────────────▼────────────┐
    │ _events              │        │ pg_duckdb               │
    │ native PostgreSQL    │        │ in-process DuckDB       │
    │ range partitions     │        │ Iceberg reads + writes  │
    └──────────┬───────────┘        └────────────┬────────────┘
               │                                 │
               │                     ┌───────────▼─────────────┐
               │                     │ Lakekeeper              │
               │                     │ Iceberg REST catalog    │
               │                     └───────────┬─────────────┘
               │                                 │ 
               │                                 │
               │                     ┌───────────▼─────────────────────┐
               │                     │ Object store, S3 / Azure / GCS  │
               │                     │                                 │
               └── Archiver (Go) ───▶│(Parquet data + Iceberg metadata)│
                                     └─────────────────────────────────┘
                   cron job: moves partitions out of the hot window: hot -> cold
```

!!! tip "New to ColdFront?"

    If you are new to ColdFront, review the guided
    [walkthroughs](exploring_coldfront/index.md) to see all three modes in action
    with copy-pasteable commands.

## Exploring ColdFront with Walkthroughs

Use the walkthroughs in the [Exploring ColdFront](exploring_coldfront/index.md)
section to learn more about ColdFront. Perform the steps on the
[Exploring ColdFront - Getting Started](exploring_coldfront/index.md) page
first, which brings up the stack; then continue to the detailed guide for
the mode you want to try:

- [Exploring Tiered Storage](walkthrough_tiered.md)
- [Exploring Decoupled Mode](walkthrough_decoupled.md)
- [Exploring the Standalone Partitioner](walkthrough_partitioner.md)
- [Exploring Distributed Mode](walkthrough_distributed.md)

## Next Steps

To install, configure, and use ColdFront, consult the following guides:

- The [Installation](installation.md) guide details installing ColdFront
  from a package or building it from source.
- The [Configuring ColdFront](configuration.md) guide documents PostgreSQL
  and ColdFront's own configuration.
- The [Configuring Lakekeeper](configure_lakekeeper.md) guide installs,
  configures, and bootstraps it, then installs the extensions
  each database needs.
- The [Configuring your Object Store](object_store.md) guide takes you from
  an empty bucket or container to a working cold tier, for any of four
  supported backends.
- The [Using ColdFront](using_coldfront/index.md) guide compares the three
  operating modes and links to each mode's guide.
- The [Connecting to ColdFront](connecting.md) guide onboards an application
  role with least privilege.
- The [Understanding ColdFront Caveats](caveats.md) guide lists the behaviors
  that differ from native PostgreSQL.
- The [Architecture Guides](architecture_guides/index.md) describe how
  ColdFront works, with a deep dive for each mode.
