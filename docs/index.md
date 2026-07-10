# pgEdge ColdFront

!!! warning "Pre-release beta software"

    ColdFront is pre-release beta software under active development. Do
    not use it in production. Interfaces, on-disk formats, and behaviour
    may change without notice, and data loss is possible.

ColdFront keeps tables in PostgreSQL and cold data in Apache Iceberg
(Parquet on S3-compatible, Azure, or GCS storage), and the cold tier is
both readable and writable through the same SQL with no application
changes. The application queries every table as an ordinary PostgreSQL
relation, and both operating modes present the same standard SQL
surface.

ColdFront provides two operating modes:

- Tiered mode keeps recent data in native PostgreSQL partitions and
  archives older data to Iceberg on a watermark; the application reads a
  single unified view, and the archiver moves rows from hot to cold on a
  schedule.
- Decoupled mode stores the table entirely in Iceberg from the first
  row; PostgreSQL holds a thin wrapper view and a registry row, and the
  coldfront extension handles every data-modifying statement on that
  view.

Both modes coexist within one database, and you choose the mode per
table at creation time. The SQL surface is identical for both modes:
standard SELECT, INSERT, UPDATE, and DELETE against the relation.

Decoupled mode scales out horizontally across many PostgreSQL nodes that
share one Lakekeeper catalog and one object store. The bakery protocol
in the coldfront extension serializes Iceberg commits on the PostgreSQL
side using Spock-replicated Snowflake tickets, so concurrent writers
never collide at the catalog. The protocol implements Lamport mutual
exclusion with the Ricart-Agrawala deferred-reply optimization, and the
[formal model](formal/README.md) verifies its safety with TLA+.

## How It Works

ColdFront runs inside PostgreSQL and rewrites each statement to the
correct tier, so the application sees one relation:

```text
Application
  |
  |-- SELECT * FROM events            reads hot + cold transparently
  |-- INSERT INTO events ...          hot via PG, cold via raw_query
  |-- UPDATE events SET ... WHERE ... rewritten to the right tier
  |-- DELETE FROM events WHERE ...    rewritten to the right tier
         |
  PostgreSQL 16/17/18 + pg_duckdb + coldfront
    _events (partitioned hot data, native PG)
    events  VIEW (hot + cold, replaces the original table)
    coldfront extension (rewrites DML to the right tier)
    pg_duckdb (Iceberg reads + writes via DuckDB, in-process)
         |
  Lakekeeper (Iceberg REST catalog)
         |
  S3-compatible object store (Parquet data + Iceberg metadata)
         |
  Archiver (Go binary, cron) moves expired PG partitions to Iceberg
```

## Quickstart

Build the image (see the [Installation](installation.md) guide) and
bring up the stack:

```bash
docker compose up -d --build
```

Bootstrap Lakekeeper and create a warehouse (see the one-time setup in
the [Using ColdFront](usage.md) guide), then create a table in psql:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');

-- Decoupled (iceberg-only) table, stored entirely in Iceberg on S3:
SELECT coldfront.create_iceberg_table('public', 'events',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},{"name":"note","type":"text"}]'::jsonb);
INSERT INTO events VALUES (1, now(), 'hello');
SELECT count(*) FROM events;
```

For compliance environments that cannot store an object-store credential,
`coldfront.set_storage_secret_vended()` runs with no credential in the
database: Lakekeeper mints short-lived per-table credentials at access
time. See [Vended credentials](usage.md#vended-minted-credentials).

## Least-privilege application roles

Application roles need no superuser and no server-file access, yet they
read and write the cold tier through the same transparent view.
Onboarding an application role is a single call:

```sql
SELECT coldfront.grant_app_access('alice');
```

grant_app_access grants only the minimum the cold path needs: membership
in duckdb.postgres_role, schema USAGE, SELECT on the registry, DML on
every registered view and the hot table and sequences behind it (all
derived from the registry, not hardcoded), plus EXECUTE on a fixed
allow-list of runtime cold-path functions. The
call is idempotent and is not executable by PUBLIC, so an application
role can never self-grant. The role is never granted
pg_read_server_files or pg_write_server_files, so it has no host-file
access. CREATE ROLE and GRANT both replicate over Spock, so you onboard
a role once on any node and it propagates across the mesh.

For how the non-superuser path works under the hood - the `SECURITY
DEFINER` attach helpers, the `PGC_SUSET` / `GUC_SUPERUSER_ONLY` config
hardening, the turnkey `duckdb.postgres_role` default, and how least
privilege holds across a Spock mesh - see [Architecture: non-superuser
app roles](architecture.md#non-superuser-app-roles-least-privilege).

## Caveats

Iceberg on Azure ADLS Gen2 requires Blob soft-delete, container
soft-delete, and change feed (blob events) to be OFF on the storage
account. Lakekeeper warehouse creation otherwise fails with HTTP 409
("This endpoint does not support BlobStorageEvents or SoftDelete").
Disable those features on the storage account before using it as a cold
tier.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Installation](installation.md) guide covers building ColdFront
  and bringing up the stack.
- The [Using ColdFront](usage.md) guide covers both modes, the
  standalone partition manager, supported types, and tuning.
- The [Object Store Setup](object_store.md) guide takes you from an
  empty bucket to a working cold tier on cloud S3.
- The [Architecture](architecture.md) overview explains the shared
  mechanics and links to the per-mode deep dives.
