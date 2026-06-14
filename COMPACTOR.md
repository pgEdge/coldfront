# COMPACTOR — Iceberg small-file compaction for ColdFront cold tiers

ColdFront's cold tier writes **one Parquet file per Iceberg append**, and nothing
in the read/write stack consolidates them (pg_duckdb passes raw SQL through;
duckdb-iceberg has no `OPTIMIZE`/`rewrite_data_files`; Lakekeeper is a catalog).
At scale this reaches tens of thousands of tiny files per table, which inflates
metadata, slows planning, and wastes object-store round-trips.

`cmd/compactor` is a standalone tool that consolidates a table's below-target
Parquet data files into fewer large ones via [apache/iceberg-go]'s
`RewriteDataFiles`, on **any** ColdFront backend, serialized through the
ColdFront bakery so it can never 409 against concurrent cold writers.

It is deliberately a **separate Go module** from the archiver: iceberg-go pulls a
heavy dependency tree (Arrow + cloud SDKs) that must never link into the lean
~9 MB archiver. The compactor builds `CGO_ENABLED=0` static at ~78 MB.

[apache/iceberg-go]: https://github.com/apache/iceberg-go

---

## 1. Formal verification (the bakery first)

Per the project rule, the bakery change was proved in TLA+ *before* the code.
The compactor introduces **no protocol change**: it is a **stock-ordering
claimant** — it takes the *same* claim a cold write takes
(`coldfront._claim_iceberg_external`), holds it across the entire
read → rewrite → commit, and releases it at PG commit via coldfront's C
`XactCallback`. Because iceberg-go has no bakery-aware re-stamp patch, the CAS
parent snapshot is captured **under the held claim** — the stock-ordering
discipline (`AsyncParquet = FALSE`).

`docs/formal/Bakery_v2.tla` models this claimant. All safe configs report *"No
error has been found"*, and `Bakery_v2_race.cfg` still violates
`NoLakekeeperConflict` — the standing proof that the bakery patch remains
mandatory. See `docs/formal/README.md` → *Compaction commits*.

---

## 2. How it works

```
LoadConfig ─▶ openCatalog ─▶ planCompaction ─▶ [bakery claim] ─▶ rewrite ─▶ [release at PG commit]
  (YAML)      (Lakekeeper)    (detection)        (mutual excl.)    (iceberg-go)
```

1. **Config** (`config.go`) — the *same* deployment YAML the archiver reads:
   `postgres.dsn` (for the bakery claim) + `iceberg.{warehouse,lakekeeper_endpoint,namespace}`
   + exactly one cold-store stanza (`s3:` or `azure:`).
2. **Catalog** (`compact.go` `openCatalog`) — connects to the Lakekeeper REST
   catalog for the warehouse, handing it the fileio credentials for the backend
   so the table's data files can be read and written.
3. **Plan / detect** (`compact.go` `planCompaction`) — `LoadTable` →
   `Scan().PlanFiles` → `compaction.PlanCompaction`, which bin-packs
   below-target data files into rewrite groups. **Detection self-gates**: an
   empty plan is a clean no-op (exit 0, nothing written). `--dry-run` stops here
   and prints the plan.
4. **Bakery claim** (`bakery.go` `withBakeryClaim`) — opens one PG transaction
   and calls `coldfront._claim_iceberg_external($1)`, which on a mesh node takes
   the Ricart-Agrawala claim (`_claim_iceberg_lock` + deferred `_enqueue_release`)
   and on a vanilla node takes the local advisory xact lock — the *same*
   chokepoint cold writes use. The claim key is
   `pgx.Identifier{"ice", namespace, table}.Sanitize()`, **byte-identical** to
   the archiver/hook key (`cmd/archiver/main.go`, `coldfront--0.1.sql`
   `tiered_views.iceberg_table`), so the compactor mutually-excludes with cold
   writers.
5. **Rewrite** (`compact.go` `rewrite`) — `txn.RewriteDataFiles(groups)` →
   `txn.Commit`, committing straight to Lakekeeper *while the claim is held*.
   Committing the PG transaction fires the C `XactCallback`, which releases the
   claim; any error rolls back (vanilla: advisory lock auto-releases; mesh: the
   claim is reaped) and no Iceberg commit lands.

Target sizing follows `--target-size-mb` (default 128): a file ≥ 75 % of target
is "optimal" and one > 180 % is oversized, so only genuinely small files are
rewritten.

---

## 3. Backends

One binary reaches every ColdFront cold store through iceberg-go's gocloud
fileio (`_ "github.com/apache/iceberg-go/io/gocloud"`). `config.go`
`storageProps()` maps the ColdFront config to iceberg-go fileio props:

| Backend | YAML | How |
|---|---|---|
| S3-compatible (SeaweedFS / MinIO) | `s3: {endpoint, region, access_key, secret_key, use_ssl, url_style}` | explicit endpoint + path/vhost addressing |
| AWS S3 | `s3:` with **no** `endpoint` | endpoint/addressing left to the aws-sdk default chain |
| GCS (S3-interop) | `s3:` aimed at `storage.googleapis.com` (HMAC keys) | same S3 path — it *is* the S3 protocol |
| Azure ADLS Gen2 | `azure: {connection_string}` | `DefaultEndpointsProtocol=…;AccountName=…;AccountKey=…;EndpointSuffix=…` |

This mirrors ColdFront's `set_storage_secret` — exactly one of S3 or Azure is
configured per deployment.

---

## 4. Why the base image carries three duckdb-iceberg interop patches

The cold tier's Iceberg manifests are *written* by pg_duckdb / duckdb-iceberg,
whose write path round-trips only through its **own** reader — which derives
everything (version, content, file format) from table metadata and ignores the
Avro metadata keys a strict Apache reader relies on. iceberg-go *is* strict, so
the compactor could not read what the cold tier wrote until three small,
**upstreamable** fixes were carried in `docker/Dockerfile.duckdb15-base` (each is
inert to pg_duckdb's own reads — verified — and only fixes cross-engine interop):

| Patch | Fixes | Without it, iceberg-go says |
|---|---|---|
| `iceberg-manifest-list-format-version-v15.patch` | tags the manifest **list** Avro with `format-version` (the writer emits v2 entries but never declared the version) | *"format-version metadata indicates version 2, but entry from manifest list indicates version 1"* |
| `iceberg-manifest-content-v15.patch` | writes the manifest **file**'s `content` from its real type (`data`/`deletes`) instead of a hardcoded `"data"` | *"'content' metadata indicates \"data\", but entry from manifest list indicates \"deletes\""* |
| `iceberg-data-file-format-v15.patch` | upper-cases the data-file `file_format` to the spec enum (`PARQUET`); duckdb keeps it lowercase internally as the copy-function name | *"only parquet format is implemented, got parquet"* |

These sit alongside — and are independent of — the proprietary
bakery-aware-commit-refresh patch (see `PATCHED.md`).

---

## 5. Build & usage

```sh
make compactor          # vet + lint + test + CGO_ENABLED=0 static build -> bin/compactor (~78 MB)
```

```
compactor --config <yaml> --table <name> [--target-size-mb 128] [--dry-run]
```

- `--table` is the table name in the configured `iceberg.namespace`.
- `--dry-run` plans and reports, changing nothing — the file-count oracle.

**When to run / observe:** query `iceberg_metadata('ice.<ns>.<tbl>')` via
pg_duckdb for `file_count` / average `file_size_in_bytes` (metadata-only, instant)
as the trigger and observability metric; the rewrite also self-gates (no-op when
nothing is below target). Prefer compacting old, settled partitions past the
archive watermark to minimise contention with live cold writers.

**Lakekeeper cleanup (follow-up):** a rewrite *replaces* data files, so the old
small files become orphans and each pass adds a snapshot. Reclaiming that bloat
is Lakekeeper's job — enable its `expire_snapshots` + orphan-removal maintenance
queues. Tracked in the backlog; not yet wired by default.

---

## 6. End-to-end walkthrough (validated)

`ci/journey.sh` `story_compaction` runs in the CI matrix (PG18 · vanilla ·
tiered · primary · S3) and is the executable proof:

1. Six same-day cold `INSERT`s into the January (cold) partition guarantee
   ≥ 5 small Parquet files in one group.
2. `compactor --dry-run` → `1 group(s), 12 small files -> ~1` — it **reads** the
   cold tier's manifests (the three interop patches) and sees the small files.
3. `compactor` (real) → bakery-serialized `RewriteDataFiles` + commit, **no 409**.
4. `compactor --dry-run` again → `nothing to compact` — the small files are
   consolidated, none left below target.
5. `SELECT count(*)` is unchanged — existing positional/equality deletes are
   applied during the rewrite and every surviving row is preserved.

```
6d. Compaction: iceberg-go RewriteDataFiles consolidates small cold files (bakery-serialized)
  PASS: compactor sees small cold files to compact
  PASS: compaction ran (bakery-serialized, no 409)
  PASS: small files consolidated (none left below target)
  PASS: compaction preserved all rows
```
