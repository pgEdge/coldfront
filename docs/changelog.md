# Changelog

All notable changes to pgEdge ColdFront will be documented in this
file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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

### Fixed

- On a server that has `output_plugin_libraries` (PostgreSQL 16.15, 17.11
  and 18.6 in pgEdge's builds), no Spock subscription could create its
  replication slot, because the setting's default leaves out
  `spock_output`. The Docker image adds `spock_output` to it on mesh nodes,
  and the per-node configuration in the usage guide lists it.

## [1.0.0-beta2] - 2026-08-08

### Added

- `coldfront.drop_iceberg_table()` drops a decoupled or tiered table, with
  purge or keep-files for the stored objects.
- Vended (minted) object-store credentials, so cold access can use
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
