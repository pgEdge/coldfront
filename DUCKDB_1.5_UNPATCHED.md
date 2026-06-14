# DUCKDB_1.5_UNPATCHED — stock duckdb-iceberg 1.5.x (no ColdFront patches)

How to build and run the DuckDB 1.5.x base **without** ColdFront's patches, and
the two consequences of doing so. The patched base is the default and the full
build story is [DUCKDB_1.5_PATCHED.md](DUCKDB_1.5_PATCHED.md).

## What "unpatched 1.5" is

The *same* 1.5.x stack — pg_duckdb PR #1025 + `duckdb-iceberg` `v1.5-variegata`
@ `0fad545a` + avro/azure/postgres_scanner, libcurl 8.11, the same vcpkg/libasan
toolchain and version pins — built with the four ColdFront patches **omitted**.
It is still a locally-built (unsigned) extension; there is no signed upstream
1.5.x iceberg to auto-install (no released pg_duckdb bundles DuckDB 1.5).

## The build delta (vs the patched base)

In `docker/Dockerfile.duckdb15-base`, drop the `COPY` + `git apply --check` +
`git apply` of all four patches:

- `iceberg-bakery-aware-commit-refresh-v15.patch`
- `iceberg-manifest-list-format-version-v15.patch`
- `iceberg-manifest-content-v15.patch`
- `iceberg-data-file-format-v15.patch`

Everything else — libcurl, vcpkg deps, the pins, the extension config, the
runtime stage — is identical. In `docker/entrypoint.sh`, leave
`coldfront.iceberg_bakery_patch` **unset** (and optionally
`coldfront.iceberg_async_parquet = off`); with the marker off,
`coldfront._iceberg_async_active()` is false. That is the entire delta — no
separate Dockerfile is maintained; "unpatched" = the patched build minus those
apply steps.

## Consequence 1 — cold writes: still correct, still no-409, just serialized

ColdFront's cold-write code path is **agnostic** (see
[DUCKDB_1.5_PATCHED.md §1](DUCKDB_1.5_PATCHED.md)) and fails safe: with
`iceberg_bakery_patch` off, every cold write is **claim-first** — the bakery
ticket is held across the parquet upload *and* the commit, so concurrent writers
to one table serialize their (slow) uploads. This is correct and **never 409s**.
The only thing lost is the ≈ 2.6× contended-upload throughput the bakery patch
buys by overlapping uploads. Single-writer/sequential writes, writes to different
tables, and tiered `INSERT`s (always claim-first) are unaffected either way.

## Consequence 2 — the COMPACTOR will NOT work

The cold-tier small-file compactor (`cmd/compactor`, apache/iceberg-go) reads the
Iceberg manifests that pg_duckdb / duckdb-iceberg wrote. Stock duckdb-iceberg's
write path is **not** strict-Apache-reader compliant — it only ever round-trips
through its own metadata-driven reader, which ignores the Avro metadata keys a
strict reader checks. So iceberg-go rejects the manifests at:

- **format-version** — the manifest *list* never declares it, so a strict reader
  defaults to v1 and then conflicts with the v2 manifest files.
- **content** — the manifest *file* hardcodes `"data"`, conflicting with a delete
  manifest's list entry (`"deletes"`).
- **file_format** — written lowercase `"parquet"`, but the spec enum is `PARQUET`.

`compactor` therefore fails at `PlanFiles` / read-task building and **nothing
consolidates the cold tier** — at scale, tens of thousands of small Parquet files
accumulate with no go-native compaction path. The three interop patches (carried
in the patched base) are exactly what make the compactor work; see
[COMPACTOR.md](COMPACTOR.md) and [DUCKDB_1.5_PATCHED.md §3](DUCKDB_1.5_PATCHED.md).

**pg_duckdb's own reads and writes of the cold tier are unaffected** — it derives
version/content/format from table metadata, never from the Avro keys iceberg-go
checks. So an unpatched cold tier reads and writes fine through PostgreSQL; it
just can't be compacted by the go-native compactor.

## When unpatched is acceptable

- You don't run the compactor (low cold-write volume, or you compact externally
  with Spark/Trino/PyIceberg — which *may* tolerate stock duckdb-iceberg
  manifests), **and**
- you don't need the contended-upload throughput (low write concurrency).

Otherwise run the patched base ([DUCKDB_1.5_PATCHED.md](DUCKDB_1.5_PATCHED.md)) —
the default.

## Verify (unpatched)

- **Cold writes no-409:** a 3-way overlapping decoupled `INSERT` into one Iceberg
  table (same-node and cross-node) → 3/3, no 409 — claim-first serializes the
  uploads, so each writer reads a fresh catalog head.
- **Compactor blocked (the documented consequence):** `compactor --table <t>
  --dry-run` errors at `PlanFiles` on the format-version / content / file_format
  cross-check.
