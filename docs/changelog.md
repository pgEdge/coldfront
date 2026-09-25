# Changelog

All notable changes to pgEdge ColdFront will be documented in this
file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Cold tables are partitioned. The archiver creates a tiered table's
  Iceberg table partitioned the way the hot table is, `month(ts)` or
  `day(ts)` on the time column, led by the LIST column of a two-level
  table, so each export is one partition and a query with a time filter
  skips the months outside it before reading anything.
- `coldfront.create_iceberg_table()` takes `p_partition_cols`, the
  partitioning as DuckDB's own `PARTITIONED BY` terms: `'{month(ts)}'`,
  `'{month(ts), region}'`, `'{"bucket(16, id)"}'`.
- The base image carries a fourth duckdb-iceberg patch, a port of upstream
  d3c3348271, so the month of a `timestamptz` partition column is its UTC
  month whatever the session's time zone.
- `coldfront.adopt_iceberg_table()` gives a table that already exists in
  the Iceberg catalog a PostgreSQL wrapper view and a registry row, so it
  reads like one ColdFront created. The schema comes from the catalog, and
  `p_types` restores a type Iceberg cannot record. Adoption is read-only
  unless `p_writable => true` arms the write path.
- `coldfront.release_iceberg_table()` hands an adopted table back: the
  wrapper view and the registry row go, and the Iceberg table keeps every
  row.

### Changed

- `coldfront.tiered_views` carries an `is_writable` column and a unique
  constraint on `iceberg_table`. Every existing registration is writable,
  and one relation is registered per Iceberg table.
- `coldfront.drop_iceberg_table()` refuses a relation adopted read-only,
  and builds its catalog DDL from the stored Iceberg reference rather than
  from the PostgreSQL schema and table names.
- The mesh bakery no longer needs the `dblink` extension. Claims, acks,
  releases and orphan reaping run over a libpq loopback connection that the
  extension opens from `coldfront.dblink_self`.

### Fixed

- After one cold write on a mesh, an app role could run any SQL as the
  loopback connection's user through the `coldfront_self` dblink connection
  the claim left open in its session, and by setting
  `coldfront.dblink_self` it could make the loopback run functions of its
  own as that user. An app role can no longer reach the loopback or set its
  connection string, and the loopback resolves names in `pg_catalog` only.
- A cold write on a mesh that failed or was cancelled during its claim left
  an advisory lock held for the rest of the session, and the node's other
  writers on that table waited on it. Every lock the claim takes now ends
  with a transaction.
- A mesh session whose loopback connection had died failed every later cold
  write. The loopback now reconnects.
- A transaction that made two cold writes to the same table on a mesh hung
  on its own first claim. A transaction now holds one claim per table.
- A writer terminated in the middle of its claim could leave a claim that
  the node's next writer on that table waited behind indefinitely.
- On a server that has `output_plugin_libraries` (PostgreSQL 16.15, 17.11
  and 18.6 in pgEdge's builds), no Spock subscription could create its
  replication slot, because the setting's default leaves out
  `spock_output`. The Docker image adds `spock_output` to it on mesh nodes,
  and the per-node configuration in the usage guide lists it.
- The compactor claimed a table made by `coldfront.create_iceberg_table()`
  under a different spelling of its Iceberg reference than the one cold
  writes to it claimed, so compaction and snapshot expiry did not wait for
  those writes. Every registration now stores the reference with each part
  quoted, which is how the archiver and the compactor spell it.
- The compactor read a table before taking its bakery claim. A run that had
  to wait for a cold write then had its commit refused and exited with an
  error, and an orphan-file pass with `--orphan-age 0s` could delete the
  files that write had just committed. Each step now reads the table under
  its claim.

## [1.0.0-beta2] - 2026-08-08

### Added

- `coldfront.drop_iceberg_table()` drops a decoupled or tiered table, with
  purge or keep-files for the stored objects.
- Vended object-store credentials, so cold access can use
  short-lived credentials issued by Lakekeeper instead of static keys.
- Cross-tier row relocation: an UPDATE that moves a row's partition key
  across the cutoff now moves the row between tiers.
- Multi-arch base images: linux/amd64 and linux/arm64.
- An interactive walkthrough with four demos, runnable in Codespaces.

### Changed

- DuckDB 1.5.4 via the merged pg_duckdb PR #1025.
- Registration refuses unlogged relations, names that the partition naming
  scheme cannot represent, and names differing only by case.

### Fixed

- Cold-tier writes are refused on a standby in every path that reaches them.
- Exotic partition bounds parse correctly, DEFAULT partitions are refused,
  and timestamp-without-time-zone bounds are handled.
- `oid` columns are rejected as unsupported rather than failing later.
- Same-node cold writers serialise through a node-local advisory lock, and
  bakery acknowledgements match on the spock node name.
- Permanent cutover errors stop immediately instead of being retried.

## [1.0.0-beta1] - 2026-06-18

First public beta of pgEdge ColdFront. Pre-release software; not for
production use.

### Added

- Tiered mode keeps recent data in native PostgreSQL partitions and
  archives older data to Apache Iceberg on a watermark, presented to the
  application as a single unified view.
- Decoupled mode stores a table entirely in Iceberg from the first row,
  with PostgreSQL holding a thin wrapper view and the coldfront
  extension handling every data-modifying statement on that view.
- Horizontal scale-out for decoupled mode across multiple PostgreSQL
  nodes sharing one Lakekeeper catalog and one object store, serialised
  by the bakery protocol; the protocol implements Lamport mutual
  exclusion with the Ricart-Agrawala optimisation and its safety is
  verified in TLA+.
- The coldfront PostgreSQL extension at version 1.0.
- Archiver and partitioner binaries for the tiered workflow, plus a
  separate compactor for Iceberg table maintenance.
- Support for PostgreSQL 16, 17, and 18 on stock upstream builds, with
  Iceberg reads and writes through pg_duckdb.
- Support for any S3-compatible object store, Azure Blob Storage, and
  Google Cloud Storage.
