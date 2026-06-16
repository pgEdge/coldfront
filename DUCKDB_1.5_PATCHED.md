# PATCHED — duckdb-iceberg patches & build (DuckDB 1.5.x)

ColdFront runs on a **custom-built DuckDB 1.5.3 base image** that carries a
small set of patches against `duckdb-iceberg` `v1.5-variegata`. This is the one
home for *what* we patch, *why*, *how the base is built*, and *how it is wired
and verified*. The cold-tier compactor's own story (and the three interop
patches' details) lives in [COMPACTOR.md](COMPACTOR.md).

> **Why a custom build at all?** There is no released pg_duckdb bundling
> DuckDB 1.5.x, so the stack is assembled off pg_duckdb PR #1025 + the
> `v1.5-variegata` extension branch. DuckDB 1.5.x is required for Azure ADLS
> `abfss://` Iceberg **reads** (`read_avro` on `abfss`); the base then layers
> ColdFront's patches on top.

## The two patch families the base carries

| Patch family | Files | Purpose | Without it |
|---|---|---|---|
| **Bakery-aware commit-refresh** | `docker/iceberg-bakery-aware-commit-refresh-v15.patch` | makes the async parquet-upload ordering safe → the **no-409** guarantee for concurrent cold writers, at contended-upload throughput | cold writes still work and still never 409 — they fall back to serialized (claim-first) uploads (see [DUCKDB_1.5_UNPATCHED.md](DUCKDB_1.5_UNPATCHED.md)) |
| **Strict-reader interop** (upstreamable) | `docker/iceberg-manifest-list-format-version-v15.patch`, `docker/iceberg-manifest-content-v15.patch`, `docker/iceberg-data-file-format-v15.patch` | make the manifests duckdb-iceberg *writes* readable by strict Apache readers (apache/iceberg-go) | the cold-tier **compactor cannot read the table** — see [COMPACTOR.md](COMPACTOR.md). pg_duckdb's own reads/writes are unaffected. |

All four patches apply cleanly to a **pristine** `duckdb-iceberg` @ `0fad545a`
(branch `v1.5-variegata`); `docker/Dockerfile.duckdb15-base` `git apply --check`s
each before applying, failing the build loudly on patch rot.

---

## 1. The agnostic cold-write code path (bakery patch is a *performance* feature)

ColdFront has **one** cold-write code path; the bakery patch never changes it.
`coldfront._exec_iceberg_with_claim` (the single chokepoint for decoupled
INSERTs, archiver batches, tiered UPDATE/DELETE) picks its strategy at runtime —
the SQL is identical whichever iceberg binary is loaded:

```sql
IF v_armed AND v_async THEN          -- PATCHED: patched binary + BOTH GUCs on
                                     -- (v_async := coldfront._iceberg_async_active())
    PERFORM duckdb.raw_query(p_sql);                  -- upload parquet in the background (OUTSIDE the claim)
    my_ticket := coldfront._claim_iceberg_lock(...);  -- claim only to wrap the deferred commit POST
    PERFORM coldfront._enqueue_release(my_ticket);
ELSIF v_armed THEN                   -- UNPATCHED (or async requested w/o the marker): claim-first
    my_ticket := coldfront._claim_iceberg_lock(...);  -- claim FIRST
    PERFORM coldfront._enqueue_release(my_ticket);
    PERFORM duckdb.raw_query(p_sql);                  -- upload+commit INSIDE the held ticket
ELSE                                 -- vanilla single-node: local advisory lock
    PERFORM pg_advisory_xact_lock(...);
    PERFORM duckdb.raw_query(p_sql);
END IF;
```

- `coldfront.iceberg_async_parquet` and `coldfront.iceberg_bakery_patch` are
  **placeholder GUCs**, default `false` (read with `current_setting(..., true)`).
  No C definition, no recompile.
- **The patched base sets BOTH `on`** (entrypoint): the binary re-stamps the
  parent at the deferred commit POST, so the background upload is safe, and the
  `iceberg_bakery_patch` marker tells `coldfront._iceberg_async_active()` the
  patch is present. Stock leaves both off → claim-first. Async **requested
  without the marker** → gate false → claim-first (fail-safe). **409 is
  impossible in every branch**; the flag only trades upload *overlap* for
  *serialized* upload. `_tiered_insert_cold` is always claim-first.
- **Why it pays off:** the S3/ADLS parquet upload is the slow part of a cold
  write; the Lakekeeper commit POST is fast. PATCHED lets concurrent writers'
  uploads overlap and serializes only the commit — measured ≈ **2.6×** contended
  throughput. It is a performance feature; UNPATCHED is equally correct.

## 2. What the bakery patch does (v1.5)

`docker/iceberg-bakery-aware-commit-refresh-v15.patch`, three files in
`src/catalog/rest/transaction/` (no signature change). The problem: ColdFront
uploads parquet *outside* the R-A bakery and takes the ticket only for the commit
POST, so by POST time a peer may have advanced the catalog head — a commit
against *session-cached* metadata fails `assert-ref-snapshot-id` (HTTP **409**),
and (worse) an append built from the stale cached manifest list would **silently
drop the peer's data**. The fix, inside `DoTableUpdates` (PG `PRE_COMMIT`, while
the ticket is held):

1. Re-read the table's `table_metadata` from Lakekeeper before
   `GetTransactionRequest` builds the commit. v1.5 derives the parent +
   `sequence_number` + assert-ref **lazily at commit** from that metadata, so a
   single refresh yields the correct values automatically — **zero manual
   re-stamping**: the patch just refreshes, and v1.5's existing lazy derivation
   produces the correct parent + sequence number + assert-ref.
2. Call `RefreshExistingManifestList()` to re-read the source manifest list that
   was cached at `AddSnapshot` time from the *stale* head — so the new list is
   built on the peer's manifests instead of dropping them. **Skipping it = silent
   peer-manifest loss** (verified: a no-refresh build lost 3 of 4 concurrent cold
   writes).
3. **The subtle part:** `RefreshExistingManifestList` is a `read_avro` table
   scan, which needs a `ClientContext` with an **active transaction**. It must
   run on the fresh `temp_con` that `IcebergTransaction::Commit` opens —
   **not** `IcebergTransactionData`'s stored (main) context, which has no active
   transaction during the commit callback. So the cache/refresh helpers take an
   explicit `scan_context`. Using the wrong context throws
   `TransactionContext::ActiveTransaction called without active transaction`.

**Formally verified** before the code (the project rule): `docs/formal/Bakery_v2.tla`
models the async ordering; `Bakery_v2_async.cfg` (patched) holds
`NoLakekeeperConflict`, `Bakery_v2_race.cfg` (async **without** the patch)
violates it — the standing proof the patch is mandatory for async. **Validated**
over Azure ADLS: journey 6b (4 concurrent mixed-tier writers → 8/8, 0 loss) and
9b (8 concurrent cold writers → 8/8).

## 3. The three strict-reader interop patches

duckdb-iceberg's write path only ever round-trips through its **own** reader,
which derives version/content/format from table metadata and ignores the Avro
metadata keys a strict Apache reader needs. iceberg-go (the compactor) *is*
strict. Three small, **upstreamable** patches — each verified inert to
pg_duckdb's own reads — make the manifests cross-engine-readable:

- `iceberg-manifest-list-format-version-v15.patch` — declare the manifest-list `format-version`.
- `iceberg-manifest-content-v15.patch` — write the manifest file's real `content` (`data`/`deletes`), not a hardcoded `"data"`.
- `iceberg-data-file-format-v15.patch` — upper-case the data-file `file_format` to the spec enum (`PARQUET`).

Full rationale, the iceberg-go errors each one fixes, and the safety argument are
in [COMPACTOR.md §4](COMPACTOR.md). They are independent of the bakery patch.

## 4. NOT shipped — no `Commit(ClientContext&)` rewrite

v1.5's `IcebergTransaction::Commit` already copies the caller's `ClientConfig`
into its commit-time connection, so `s3_access_key_id` etc. are available — the
non-AWS-S3 commit-time 403 that the old "mvcc-fix" targeted does not arise. Do
**not** rewrite `Commit` to run under the caller's `ClientContext`: on the
deferred `PRE_COMMIT` callback that context has no active transaction and throws
`ActiveTransaction called without active transaction`. Build the bakery + interop
patches only.

---

## 5. Version pins (do not drift)

| Component | Pin | Notes |
|---|---|---|
| pg_duckdb | **PR #1025 head** (`9c9fbcd`) | no released tag carries 1.5.x; `git fetch origin pull/1025/head`. Sets `DUCKDB_VERSION=v1.5.3`. |
| DuckDB | **v1.5.3** (submodule `9a64d338`) | the `duckdb.*` GUCs + PRE_COMMIT iceberg-commit deferral ColdFront relies on are unchanged by the PR. |
| duckdb-iceberg | **`v1.5-variegata` @ `0fad545a`** | transaction code lives in `src/catalog/rest/transaction/`; the four patches apply here. |
| avro | **`7f423d69`** | the pin `v1.5-variegata` uses. |
| azure | **`v1.5-variegata` @ `563589b2`** | the ABI-matched sibling of iceberg's branch. **NOT `main`** — azure `main` collides at link (`multiple definition of duckdb::FileFlags::FILE_FLAGS_NULL_IF_NOT_EXISTS`). |
| postgres_scanner | duckdb-postgres **`main` @ `916d862b`** | the `postgres` ext; built bundled (ABI-matched, stamped v1.5.3), **shipped** in the image (never downloaded). Its vcpkg `libpq` build needs **flex** + **bison**. |
| libcurl | **build 8.11.1** (≥ 7.77) | **REQUIRED** — DuckDB 1.5.3 httpfs uses `CURLSSLOPT_AUTO_CLIENT_CERT` (≥ 7.77); the pgEdge base ships 7.76.1. |

## 6. Build — `docker/Dockerfile.duckdb15-base`

The base build *is* the recipe; read it as the source of truth. Its non-obvious
requirements (each a real build failure if missing):

- **libcurl ≥ 7.77** built from source in the pg_duckdb stage (the
  `CURLSSLOPT_AUTO_CLIENT_CERT` symbol). The bundled httplib client is what runs
  at runtime — libcurl is a *compile-time* dependency of httpfs only.
- **`gcc-toolset-14-libasan-devel` + `-libubsan-devel`** in the iceberg-builder
  (`manylinux_2_28_x86_64`, gcc-toolset-14). The extension's
  `extension_configuration` phase builds a Debug `duckdb_platform_binary` that
  links AddressSanitizer; without the runtime the build dies with `ld: cannot
  find -lasan`. Affects only the Debug helper — the shipped extensions are Release.
- **`flex` + `bison`** for the `postgres_scanner` vcpkg `libpq` build.
- **azure pinned `v1.5-variegata` (`563589b2`), not `main`** (link collision).
- iceberg/avro/azure/postgres_scanner are built **bundled** against one DuckDB
  (`make release`, `OVERRIDE_GIT_DESCRIBE=v1.5.3`) so they are ABI-safe; build
  config is `docker/iceberg-azure-extension-config-v15.cmake`.
- The bakery + three interop patches are `COPY`'d in and `git apply --check`'d
  then applied (see the Dockerfile's patch block).

Cold base build is ~30–60 min (vcpkg compiles the Azure SDK + libpq from source);
incremental rebuilds after a patch change recompile only the iceberg extension.

## 7. Install / GUCs / image wiring (base/app split)

The expensive, **stable** compiles live in the **base** image, published to
`ghcr.io/pgedge/coldfront-duckdb-base:pg{16,17,18}`. The thin **app** image layers
only the coldfront extension on top, so CI/local builds are fast and always test
current source.

| File | Role |
|---|---|
| `docker/Dockerfile.duckdb15-base` | base: pg_duckdb 1.5.3 (PR #1025) + libcurl 8.11 + patched iceberg/avro/azure/postgres_scanner; runtime stage = the 4 extensions + entrypoint, **no coldfront**. |
| `docker/Dockerfile.duckdb15` | app: a `cf-build` stage compiles coldfront (PG devel only — coldfront links libpq, not pg_duckdb), then `FROM ${COLDFRONT_BASE}` copies the `.so`/SQL on top. |
| `docker/entrypoint.sh` | first-init: sets `COLDFRONT_DUCKDB_VERSION=v1.5.3`, pre-places the extensions under `$PGDATA/pg_duckdb/extensions/v1.5.3/<platform>/`, writes the GUCs. |
| `docker/iceberg-azure-extension-config-v15.cmake` | the bundled-build extension config (iceberg + avro + azure + postgres_scanner). |
| `.github/workflows/base-image.yml` | builds + pushes the base via `GITHUB_TOKEN` (base rebuilds are rare). |

GUCs the patched-base entrypoint writes to `postgresql.conf`:

- `duckdb.allow_unsigned_extensions = on` — the local extensions are unsigned.
- `duckdb.autoinstall_known_extensions = on`, `duckdb.autoload_known_extensions = on`
  — autoinstall does **not** clobber a pre-placed local extension (verified); it
  only fetches *missing* ones.
- **`coldfront.iceberg_async_parquet = on`** AND **`coldfront.iceberg_bakery_patch = on`**
  — both, together. `coldfront._iceberg_async_active()` is true only when both
  are on; otherwise the cold-write path fails safe to claim-first (never a 409)
  and logs a one-time advisory. Flipping only the async flag on a stock binary
  can never silently 409 — proven by `Bakery_v2_race.cfg` + the
  `async_requires_patch` pg_regress test. **Rebuild + republish the base whenever
  the entrypoint or any patch changes**, or async silently downgrades.

> **GUC gotcha:** the `duckdb.*` GUCs are `PGC_SUSET`, read once at DuckDB init,
> and rejected after. In the image they sit in `postgresql.conf` from first init
> so the trap never arises; on bare metal apply via `ALTER SYSTEM` + reload
> **before** any DuckDB use, one `ALTER SYSTEM` per statement.

> **avro is a hard dependency of iceberg.** With autoinstall **off**, `avro`
> (and `azure` for an Azure cold tier) must be pre-placed beside `iceberg` or
> `LOAD iceberg` fails. The shipped image pre-places all four, so this is moot.

Building the app locally pulls the published base
`ghcr.io/pgedge/coldfront-duckdb-base:pg<major>`, or uses a locally-built
base tagged the same.

## 8. v1.5 architecture notes (verified against source)

- `IcebergTransaction::Commit()` opens a fresh `temp_con` but **copies the
  caller's config** (settings like `s3_access_key_id`, not the secret catalog).
  ColdFront's **persistent-secret design still holds and is still required** — a
  `PERSISTENT SECRET` loaded at init is visible to `temp_con`; a session secret
  would not be.
- Transaction code lives in `src/catalog/rest/transaction/`.
  `GetTransactionRequest` builds the commit
  (parent + `AssertRefSnapshotId` from the session-cached `current_snapshot`) —
  the bakery-refresh injection site.
- v1.5 bakes the snapshot `sequence_number` into the manifest at *parquet-write*
  time (outside the bakery ticket in async mode) — which is why the bakery patch
  is a re-design, not a port, and why its no-409 correctness is proven by the
  3-node bench, not assumed.

## 9. Azure secret (`TYPE azure`)

Verified against duckdb-azure `src/azure_secret.cpp` + the built extension. There
is **no `ACCOUNT_KEY` parameter** — a shared-key account key is supplied only in
the CONFIG provider's `CONNECTION_STRING`:

```sql
CREATE OR REPLACE PERSISTENT SECRET cf_storage (
    TYPE azure,
    CONNECTION_STRING 'DefaultEndpointsProtocol=https;AccountName=<acct>;AccountKey=<key>;EndpointSuffix=core.windows.net'
);
```

One secret serves both `abfss://` (ADLS Gen2 / dfs) and `az://` (blob).
**coldfront wiring:** `coldfront.storage_secret` carries a `storage_type`
(`'s3'`|`'azure'`) discriminator + a `connection_string` column; the pure
`coldfront._build_storage_secret_opts(row)` builds the secret body and
`set_storage_secret_azure(connection_string)` is the setter. Unit test:
`extension/coldfront/test/sql/storage_secret_azure.sql` (the pure builder; the
live `CREATE PERSISTENT SECRET` is exercised only on the 1.5.x image, not in
pg_regress — a green regress run does **not** prove azure I/O).

## 10. CI coverage — why azure is creds-gated, not hermetic

`ci/matrix.sh` runs the same storage-agnostic journey under s3 (hermetic,
SeaweedFS) and azure on the two **tiered** cells (`vanilla·tiered`,
`mesh·tiered` — the only cells where storage interacts, via bakery × commit
latency). Verified green over real ADLS: vanilla·tiered·azure 92/0,
mesh·tiered·azure 108/0. Azure **cannot be hermetic**: Lakekeeper's only Azure
storage profile is `adls` (forces the `abfss://`/DFS endpoint), and Azurite
implements Blob/Queue/Table but **not** the DFS endpoint (Azure/Azurite#553).
So the azure cells are gated on `COLDFRONT_AZURE_*` (RUN when present, else
PENDING — never silently skipped); the storage-divergent code (secret rendering,
config selection) is covered with no creds by the unit + pg_regress layer on
every PR.

## 11. Cutover-vs-cold-write race — FIXED (version-agnostic)

A separate, pre-existing gap (not a 409 issue, not in any iceberg patch),
surfaced over Azure by `ci/journey.sh` story 9. `coldfront.cutover_archive` took
`LOCK … ACCESS EXCLUSIVE` on the partition **without going through the bakery**,
so it merely *raced* a concurrent cold write for the partition lock. On fast S3
the racing commit finished inside the cutover's ~102 s lock-retry budget — it
*looked* flawless; on slow Azure the commit outlasted the budget and all 10
cutover attempts failed with `lock timeout (SQLSTATE 55P03)` (no data lost, but
the cycle deferred). "Flawless on S3" was timing luck.

**Fix:** `cutover_archive` gained a `p_iceberg_ref` parameter and now acquires
the **same bakery** the cold-write path takes (same `v_armed` gate, same
`coldfront_iceberg:<ref>` key), as its **first** lock, before `LOCK TABLE …
ACCESS EXCLUSIVE`. The archiver passes the ref as a new `CALL` argument
(`cmd/archiver/main.go`); the cold-write path is unchanged. Because the bakery
acquire has no `lock_timeout`, the cutover waits out any in-flight writer's full
commit, then takes the uncontended `ACCESS EXCLUSIVE`.

**Deadlock-freedom** comes from the `lock_timeout = 100 ms` (< `deadlock_timeout`)
circuit breaker on the partition lock, **not** a global lock order — which is
impossible because PostgreSQL locks a `ModifyTable`'s result relations at
executor startup, before any CTE runs, so a dual-tier writer is unavoidably
`RowExclusive`-before-bakery (an inversion vs the cutover). Whenever the inversion
forms, the **cutover** yields first (100 ms), frees the bakery, the writer
commits, and the harness retries the cutover — the writer is never the victim.
**Validated** over Azure (vanilla): `phase 4 attempt 1 (cutover): 1m26s` (the
cutover patiently waiting on the bakery for the in-flight writer), first-attempt
success, no 409, no cross-tier duplication (`count == count(distinct id)`).

## 12. Reverting to UNPATCHED

No code change — flip to stock by unsetting `coldfront.iceberg_bakery_patch`
(the gate goes false → claim-first even if the async flag stays on). To run a
genuinely unpatched base, omit the patch `git apply` steps in the base build —
see [DUCKDB_1.5_UNPATCHED.md](DUCKDB_1.5_UNPATCHED.md), including the consequence
that the compactor will not work.
