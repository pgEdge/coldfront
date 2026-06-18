# Changelog

All notable changes to pgEdge ColdFront will be documented in this
file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
