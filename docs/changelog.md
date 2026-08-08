# Changelog

All notable changes to pgEdge ColdFront will be documented in this
file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
