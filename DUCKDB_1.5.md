# DuckDB 1.5.x bump — build method (Azure ADLS read+write)

> **Status: HEADLINE PROVEN ✅.** The assembled DuckDB 1.5.3 stack (pg_duckdb PR#1025 +
> iceberg/avro/azure `v1.5-variegata`) does **Azure ADLS `abfss://` Iceberg READ *and*
> WRITE** end-to-end — verified live against a real ADLS Gen2 account
> via Lakekeeper `wh-azure`:
> - raw `COPY … TO 'abfss://…/t.parquet'` wrote 5 rows; read back 5 (abfss FS write+read).
> - Iceberg: `ATTACH` + `CREATE TABLE ice."default".probe` + `INSERT` (3 rows → data parquet
>   **+ avro manifests on abfss**) + `SELECT count(*)` → **3, `a,b,c`** (`read_avro` on the
>   abfss manifest list — the *exact* step that fails on 1.4.3).
>
> Both 1.4.3 blockers are gone: abfss **write** (`CreateDirectory`, fixed by azure
> `v1.5-variegata` ⊇ commit `391df596`) and abfss **read** (`read_avro`, fixed by DuckDB
> 1.5.x). There is **no official pg_duckdb release bundling DuckDB 1.5** — so we "wing it"
> off the open pg_duckdb PR. This file records the build method **that actually works**.
>
> **Safety:** the working **DuckDB 1.4.3** patched-iceberg is the committed baseline-of-record
> (see PATCHED.md, `docker/iceberg-bakery-aware-commit-refresh.patch`, commit `c18a99f`);
> `main` is the revert target. All 1.5 work is on `feat/azure-duckdb-1.5` and never overwrites
> the 1.4.3 artifacts.

## Version pins (resolved from real source)

| Component | Pin | Notes |
|---|---|---|
| pg_duckdb | **PR #1025 head** (`9c9fbcd`, "bump up duckdb…") | no released tag carries 1.5.x; `git fetch origin pull/1025/head`. Sets `DUCKDB_VERSION=v1.5.3`. |
| DuckDB | **v1.5.3** (submodule `9a64d338`) | what PR #1025 pins (v1.5.3 +13 commits). PRE_COMMIT iceberg-commit deferral + `duckdb.*` GUCs ColdFront relies on are **unchanged** by the PR. |
| duckdb-iceberg | **`v1.5-variegata` @ `0fad545a`** | transaction code moved to `src/catalog/rest/transaction/`. Its duckdb submodule is `14eca11b` (v1.5.x — extension-API-compatible with pg_duckdb's `9a64d338`). |
| avro | **`7f423d69`** | the pin iceberg `v1.5-variegata` uses. |
| azure | **`v1.5-variegata` @ `563589b2`** | the ABI-matched sibling of iceberg's branch. **NOT `main`** — azure `main` tracks duckdb `main` and collides with `14eca11b` (`multiple definition of duckdb::FileFlags::FILE_FLAGS_NULL_IF_NOT_EXISTS` at link). Built bundled into the iceberg build (same DuckDB → ABI-safe). |
| postgres_scanner | duckdb-postgres **`main` @ `916d862b`** | the `postgres` ext (pglocal write path). No v1.5 branch exists; built bundled (against `14eca11b` → ABI-matched, stamped v1.5.3). **SHIPPED in the image**, never downloaded: extensions.duckdb.org has the v1.5.3 build but the 14.5 MB pull is unreliable, and `install_extension('postgres')` would block on it. Its vcpkg `libpq` build additionally needs **`flex`** + **`bison`** in the builder. |
| libcurl | **≥ 7.77 (we build 8.11.1)** | **REQUIRED** — see the curl note below. |

## ✅ PROVEN: pg_duckdb foundation build (DuckDB 1.5.3)

Builds clean. The **only** non-obvious requirement is a newer libcurl: DuckDB 1.5.3's
httpfs uses `CURLSSLOPT_AUTO_CLIENT_CERT` (libcurl ≥ 7.77, a Windows-Schannel no-op on
Linux but the symbol must exist); the pgEdge base ships **7.76.1**, so the build fails with
`'CURLSSLOPT_AUTO_CLIENT_CERT' was not declared` until a newer libcurl is present.

```bash
# base: ghcr.io/pgedge/pgedge-postgres:18-spock5-minimal   (run --user root)
dnf install -y --setopt=install_weak_deps=False \
    pgedge-postgresql18-devel gcc gcc-c++ make cmake ninja-build git \
    redhat-rpm-config openssl-devel libcurl-devel lz4-devel zlib-devel libicu-devel \
    pkgconf-pkg-config python3 wget tar gzip
export PATH=/usr/pgsql-18/bin:$PATH PG_CONFIG=/usr/pgsql-18/bin/pg_config

# --- REQUIRED: libcurl >= 7.77 (DuckDB 1.5.3 httpfs needs CURLSSLOPT_AUTO_CLIENT_CERT) ---
cd /tmp && wget -q https://curl.se/download/curl-8.11.1.tar.gz && tar xf curl-8.11.1.tar.gz && cd curl-8.11.1
./configure --with-openssl --prefix=/usr --disable-static \
    --without-libpsl --without-libssh2 --without-nghttp2 --without-brotli --without-zstd
make -j"$(nproc)" && make install && ldconfig    # /usr/include/curl now has AUTO_CLIENT_CERT

# --- pg_duckdb from PR #1025 (DuckDB 1.5.3) ---
mkdir -p /build && cd /build
git clone https://github.com/duckdb/pg_duckdb /build/pg_duckdb
cd /build/pg_duckdb
git fetch origin pull/1025/head && git checkout FETCH_HEAD      # DUCKDB_VERSION=v1.5.3
git submodule update --init --recursive                         # third_party/duckdb == 9a64d338
# pgEdge propagates -fexcess-precision=standard into CXXFLAGS; gcc rejects it for C++:
printf '\noverride CXXFLAGS := $(filter-out -fexcess-precision=standard,$(CXXFLAGS))\n' >> Makefile.global
make -j"$(nproc)" with_llvm=no                                  # -> pg_duckdb.so  ✅
```

## ⏳ IN VALIDATION: iceberg + avro + azure extensions (DuckDB 1.5.x ABI)

Built in the manylinux+vcpkg toolchain (`quay.io/pypa/manylinux_2_28_x86_64`, gcc-toolset-14,
vcpkg supplies a recent curl so the curl-8 hack above is **not** needed here).

**REQUIRED package (root cause of the first failure):** the extension build's
`extension_configuration` phase builds a throwaway `duckdb_platform_binary` (platform-string
detector) with **`-DCMAKE_BUILD_TYPE=Debug`**, and DuckDB's Debug type turns on
AddressSanitizer → the link needs `-lasan` + `libasan_preinit.o`. The stock
manylinux_2_28 image does **not** ship the gcc-toolset ASAN runtime, so the build dies with
`ld: cannot find -lasan`. Install it (this matches DuckDB's own extension-CI images):

```bash
dnf install -y gcc-toolset-14-libasan-devel gcc-toolset-14-libubsan-devel
```

This affects only the Debug helper binary — the shipped `build/release/*.duckdb_extension`
is Release (no ASAN). *(The first failure was misdiagnosed as an azure-vcpkg link issue; it
was not — it reproduced identically with azure removed. Root cause is libasan, full stop.)*

**Bundled build (all three against ONE DuckDB → ABI-safe).** Add all three to the iceberg
`extension_config.cmake` and `make release` once. iceberg + avro are confirmed built (49M +
12M). azure MUST be pinned to `v1.5-variegata` (`563589b2`), not `main` — see the pin table.
The Azure SDK vcpkg deps (`azure-storage-blobs`, `azure-storage-files-datalake`,
`azure-identity`, `azure-storage-common`) build cleanly under vcpkg. extension_config.cmake:

```cmake
if (NOT EMSCRIPTEN)
duckdb_extension_load(avro  GIT_URL https://github.com/duckdb/duckdb-avro  GIT_TAG 7f423d69709045e38f8431b3470e0395fce1a595 EXTENSION_VERSION v1.5.3)
duckdb_extension_load(azure GIT_URL https://github.com/duckdb/duckdb-azure GIT_TAG 563589b2f24290a4dcdd4247eaedf2b544f9dbcd EXTENSION_VERSION v1.5.3)
endif()
duckdb_extension_load(iceberg SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR} EXTENSION_VERSION v1.5.3)
```

iceberg+avro `extension_config.cmake`:
```cmake
if (NOT EMSCRIPTEN)
duckdb_extension_load(avro GIT_URL https://github.com/duckdb/duckdb-avro
        GIT_TAG 7f423d69709045e38f8431b3470e0395fce1a595 EXTENSION_VERSION v1.5.3)
endif()
duckdb_extension_load(iceberg SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR} EXTENSION_VERSION v1.5.3)
```
Build env: `VCPKG_TOOLCHAIN_PATH`/`VCPKG_ROOT`=vcpkg, `VCPKG_TARGET_TRIPLET=x64-linux`,
`USE_MERGED_VCPKG_MANIFEST=1`, `EXT_CONFIG=<…>/extension_config.cmake`,
`OVERRIDE_GIT_DESCRIBE=v1.5.3`, then `make -j release`.

All three must be built against **DuckDB v1.5.x** (extension-API-compatible with pg_duckdb's
`9a64d338`) and pre-placed (per PATCHED.md §8) at
`$PGDATA/pg_duckdb/extensions/v1.5.3/<platform>/` with the runtime `COLDFRONT_DUCKDB_VERSION=v1.5.3`.

## v1.5 architecture notes (verified against real source — corrects the planning research)

- **`IcebergTransaction::Commit()` still opens a fresh `temp_con`** but now **copies the
  caller's config** (settings like `s3_access_key_id`, *not* the secret catalog). ColdFront's
  **persistent-secret design still holds and is still required** — a `PERSISTENT SECRET`
  loaded at init is visible to `temp_con`; a session secret would not be.
- Transaction code moved `src/storage/{irc_transaction,iceberg_transaction_data}.cpp` →
  `src/catalog/rest/transaction/iceberg_transaction*.cpp`. `DoTableUpdates` →
  `GetTransactionRequest` builds the commit (parent + `AssertRefSnapshotId` from the
  session-cached `current_snapshot`) — the bakery-refresh injection site.
- **New wrinkle:** v1.5 bakes the snapshot `sequence_number` into the manifest at
  *parquet-write* time (`AddSnapshot`: `last_sequence_number + alters.size() + 1`), i.e.
  *outside* the bakery ticket in async mode. So the bakery-aware-commit-refresh patch is a
  **re-design, not a port**, and its no-409 correctness must be proven by the 3-node bench.

## Bakery patch (v1.5) — and how it differs from the 1.4.3 patch

The bakery is **essential and non-optional**: it is ColdFront's no-409 guarantee for
concurrent cold writers, and the Azure (1.5) image must carry it exactly like the S3 (1.4.3)
image does — *everything is identical except the storage backend*. The patch is a **separate
file** — `docker/iceberg-bakery-aware-commit-refresh-v15.patch` — and does **not** overwrite
the committed 1.4.3 patch (`docker/iceberg-bakery-aware-commit-refresh.patch`), which remains
the revert-to baseline.

**The problem is the same in both versions.** ColdFront uploads parquet *outside* the R-A
bakery and takes the ticket only for the commit POST. By POST time a peer ticket-holder may
have advanced the catalog head, so a writer that commits against its *session-cached*
metadata fails the `assert-ref-snapshot-id` precondition → **HTTP 409**, and (worse) an
append built from the stale cached manifest list would **silently drop the peer's data**. The
fix in both versions: inside `DoTableUpdates` (PG `PRE_COMMIT`, while holding the ticket),
re-read the table's metadata from Lakekeeper *once* before the commit request is built — no
peer can move the head until we release.

**Why the v1.5 patch is leaner than 1.4.3 (the real difference):**

| | **1.4.3** (`src/storage/…`) | **1.5** (`src/catalog/rest/transaction/…`) |
|---|---|---|
| Snapshot fields stamped | **Eagerly at write** (`Finalize`) | **Lazily at commit** (`GetTransactionRequest` reads parent via `GetLatestSnapshot()`; `IcebergCommitState` seeds `next_sequence_number = last_sequence_number + 1`; `CreateUpdate` consumes them) |
| Part A of patch | **Remove** the eager `parent_snapshot_id` stamping in `AddSnapshot`/`AddUpdateSnapshot` | **Not needed** — v1.5 has no eager stamping to remove |
| Part B of patch | Refresh metadata **and manually re-stamp** each staged `AddSnapshot`'s `sequence_number` + `parent_snapshot_id` from the fresh head | **Just refresh** `table_info.table_metadata` from Lakekeeper before `GetTransactionRequest`; v1.5's existing lazy derivation then produces the correct parent + seq# + assert-ref automatically — **zero manual re-stamping** |
| Manifest list | (1.4.3 manifest handling) | Must also call **`RefreshExistingManifestList()`** — re-read the source manifest list cached at `AddSnapshot` time from the *stale* head, so the new list is built on top of the peer's manifests instead of dropping them. v1.5 specifically needs this because `GetTransactionRequest` seeds `commit_state.manifests` from that cache. **Skipping it = silent peer-manifest loss** (verified: a no-scan build lost 3 of 4 concurrent cold writes, non-atomically). |
| Manifest-scan context | n/a | **The fix that took the longest.** `RefreshExistingManifestList` is a `read_avro` table-function SCAN, which needs a `ClientContext` with an **active transaction**. It must run on the fresh `temp_con` that `IcebergTransaction::Commit` opens (`temp_con.BeginTransaction()`) — **NOT** `IcebergTransactionData`'s stored context, which is the original/main connection that, *during the commit xact callback, has no active transaction* (it's mid-commit). Using the main context throws `TransactionContext::ActiveTransaction called without active transaction`. So `CacheExistingManifestList`/`RefreshExistingManifestList` take an explicit `scan_context`: `AddSnapshot`/`AddUpdateSnapshot` pass the member context (active during the INSERT); the commit-time refresh passes `DoTableUpdates`' `context` (= `temp_con`). Pure-cold (9b) happened to survive the wrong context; the dual-CTE mixed-tier path (6b) did not. |
| Manifest seq# | n/a | The `temp_sequence_number` baked into the manifest **file** at write time is **left as-is** — it is overwritten on commit by `AddNewManifestFile` from the fresh `next_sequence_number`, and ADDED entries inherit it (`GetSequenceNumber`). No manifest rewrite. |

**v1.5 patch shape (3 files):** `iceberg_transaction.cpp` (+`#include "duckdb/common/exception/http_exception.hpp"`; the refresh loop in `DoTableUpdates` — skip tables with no staged snapshot and tables being `CREATE`d this txn, which would 404; passes `context`=`temp_con` to the manifest refresh), `iceberg_transaction_data.{cpp,hpp}` (`CacheExistingManifestList` + `RefreshExistingManifestList` take an explicit `scan_context`; `force` flag). Designed + adversarially verified against `v1.5-variegata @ 0fad545a`; `git apply --check` clean; compiles. **VALIDATED ✅** over Azure ADLS on the good link: journey 6b (4 concurrent mixed-tier dual-CTE writers) → **8/8, 0 errors, 0 loss** (cold=4, hot=4), and 9b (8 concurrent cold writers) → 8/8. *(Watch out for read-after-commit convergence lag: a read taken mid-flight during the concurrent-write window can transiently under-count before the Iceberg snapshot settles — measure after the writers join.)*

## Cutover-vs-cold-write race surfaced by Azure (story 9) — FIXED

While validating the bakery patch over Azure, `ci/journey.sh` **story 9**
(archiver-vs-cold-write race) exposed a **separate, pre-existing** gap — *not*
an Iceberg/409 issue and *not* in the patch above:

`coldfront.cutover_archive` took `LOCK … ACCESS EXCLUSIVE` on the partition
**without going through the bakery**, so it merely *raced* a concurrent cold
write for the partition lock. On S3 the racing write's commit was fast enough
that the cutover's ~102 s lock-retry won — so it *looked* flawless. On Azure the
slow commit held the partition `RowExclusive` past the retry budget and all 10
cutover attempts failed with `lock timeout (SQLSTATE 55P03)`; the archiver
deferred (`trigger+delta left for next cycle`). No data was lost, but the cycle
did not complete. "The bakery works flawlessly under S3" was timing luck.

**Fixed:** `cutover_archive` now acquires the **same bakery** the cold-write
path takes (same `v_armed` gate, same `coldfront_iceberg:<ref>` key), threaded
in as a new `p_iceberg_ref` arg (`cmd/archiver/main.go` passes it as `$6`),
**before** its `ACCESS EXCLUSIVE` — so it waits out any in-flight writer's full
commit and blocks new ones. The cold-write path is unchanged. Deadlock-freedom
relies on the cutover's `lock_timeout = 100 ms` (< `deadlock_timeout`) breaking
the unavoidable writer-side `RowExclusive`-before-bakery inversion into bounded
retry — *not* on a global lock order, which is impossible because PG locks a
`ModifyTable`'s result relations at executor startup before any CTE runs.
**VALIDATED ✅** over Azure (vanilla): `phase 4 attempt 1 (cutover): 1m26s`
(the cutover *patiently waiting on the bakery* for the in-flight writer — live
blocking graph confirmed `Lock:advisory`, `blocked_by` the writer), succeeded on
the first attempt, no 409, no cross-tier duplication (`count == count(distinct
id)`). The shared, version-agnostic write-up (applies to the 1.4.x stack too) is
in **`PATCHED.md` §11**.

## Azure secret (`TYPE azure`) — verified syntax + coldfront wiring

Verified against duckdb-azure `src/azure_secret.cpp`, the official azure docs, AND
the on-disk built `azure.duckdb_extension`. Providers: `config` (default),
`credential_chain`, `service_principal`, `access_token`, `managed_identity`.

**There is NO `ACCOUNT_KEY` parameter.** A storage-account **access key** (shared
key, the non-Entra path) is supplied *only* inside the CONFIG provider's
`CONNECTION_STRING`:

```sql
CREATE OR REPLACE PERSISTENT SECRET cf_storage (
    TYPE azure,
    CONNECTION_STRING 'DefaultEndpointsProtocol=https;AccountName=<acct>;AccountKey=<key>;EndpointSuffix=core.windows.net'
);
```

This one secret serves both `abfss://` (ADLS Gen2 / dfs) reads+writes and `az://`
(blob). `ACCOUNT_NAME` is optional when paths are fully qualified.

**coldfront wiring (implemented):** `coldfront.storage_secret` gained a
`storage_type` discriminator (`'s3'`|`'azure'`) + a `connection_string` column
(`key_id`/`secret` now nullable, CHECKs enforce per-type); a PURE
`coldfront._build_storage_secret_opts(row)` builds the secret body (s3 vs azure)
and `materialize_storage_secret()` calls it; new `coldfront.set_storage_secret_azure(connection_string)`
setter. Unit test `extension/coldfront/test/sql/storage_secret_azure.sql` asserts
the pure builder for both branches (the trigger's `CREATE PERSISTENT SECRET (TYPE
azure)` raw_query is NOT exercised in pg_regress — it needs the azure extension
staged, i.e. the 1.5.x image). **Beware:** a green pg_regress run does NOT mean
azure I/O works — that is gated on this whole 1.5.x stack + the e2e below.

## Status (shipped to `main`)

The 1.5.x stack is the default stack on `main`. All of the original "remaining"
work is done:

- [x] iceberg+avro+azure built (all 3, v1.5.3 footer; azure `v1.5-variegata`).
- [x] 1.5.3 stack assembled + **Azure abfss read+write e2e PROVEN** (status banner).
- [x] Coldfront tiered flow over azure (archiver → view read) — matrix azure cells
      green (vanilla·tiered·azure 92/0, mesh·tiered·azure 108/0).
- [x] `TYPE azure` in `materialize_storage_secret()` + `storage_secret` schema +
      `storage_secret_azure.sql` regress test (registered in the Makefile).
- [x] **Image wiring — now a base/app split** (see "Image build" below):
      `docker/Dockerfile.duckdb15-base` (pg_duckdb 1.5.3 + patched iceberg) →
      private GHCR base; `docker/Dockerfile.duckdb15` (thin coldfront app) `FROM`s it;
      `docker/entrypoint.sh` sets `COLDFRONT_DUCKDB_VERSION=v1.5.3`, pre-places the
      extensions, and sets `iceberg_async_parquet` **and** `iceberg_bakery_patch`.
- [x] Bakery patch re-authored for v1.5 (`docker/iceberg-bakery-aware-commit-refresh-v15.patch`)
      and **formally verified** — `docs/formal/Bakery_v2.tla` models the async ordering;
      `Bakery_v2_async.cfg` (patched) holds `NoLakekeeperConflict`, `Bakery_v2_race.cfg`
      (async without the patch) violates it. The runtime guard
      (`coldfront._iceberg_async_active()`, gated on `iceberg_bakery_patch`) enforces it.
- [x] Full matrix on the 1.5.x image: s3 cells green (PG16/17/18 × {vanilla,mesh} ×
      {tiered,decoupled} × {primary,standby} = 24, **29/0**); aws/azure/gcs creds-gated.
- [x] PATCHED / README / CLAUDE updated (CLAUDE.md now mandates TLA+-first for any
      mesh/bakery change).

## Image build (base/app split + the bakery-patch marker)

The expensive, **stable** compiles (libcurl 8.11, pg_duckdb 1.5.3 from PR #1025,
the patched duckdb-iceberg/avro/azure/postgres_scanner) are built once into a
**base** image and published **PRIVATE/INTERNAL** to
`ghcr.io/pgedge/coldfront-duckdb-base:pg{16,17,18}` (it embeds the bakery patch —
ColdFront IP). The **app** image is a thin layer that only compiles the coldfront
extension on top — so CI and local builds are fast (~minutes, not the cold
~30–60 min iceberg compile) and always test the current source.

| File | Role |
|---|---|
| `docker/Dockerfile.duckdb15-base` | base: §"PROVEN foundation" + §"iceberg extensions" build, **plus** the bakery patch git-applied; runtime stage = pg_duckdb + the 4 extensions + entrypoint, **no coldfront**. |
| `docker/Dockerfile.duckdb15` | app: a `cf-build` stage compiles coldfront (PG devel only — coldfront links libpq, not pg_duckdb), then `FROM ${COLDFRONT_BASE}` copies the coldfront `.so`/SQL on top. |
| `.github/workflows/base-image.yml` | builds + pushes the private base via `GITHUB_TOKEN` (workflow_dispatch; base rebuilds are rare). |

Building the app locally needs `docker login ghcr.io` (read:packages) to pull the
private base, or a locally-built base tagged `ghcr.io/pgedge/coldfront-duckdb-base:pg<major>`.

**The `iceberg_bakery_patch` marker (the async safety gate).** The async upload
ordering (stage parquet outside the claim, re-stamp `parent_snapshot_id` at the
commit POST) is correct **only** on the patched binary. The entrypoint of the
patched base therefore sets BOTH `coldfront.iceberg_async_parquet = on` AND
`coldfront.iceberg_bakery_patch = on`. `coldfront._iceberg_async_active()` returns
true only when both are on; otherwise `_exec_iceberg_with_claim` **fails safe to
the stock ordering** (claim-first, serialized upload — never a 409) and logs a
one-time server-log advisory. So flipping only the async flag on a stock/bare-metal
deployment can never silently 409 — verified by `Bakery_v2_race.cfg` and the
`async_requires_patch` pg_regress test. Rebuild + republish the base (via
`base-image.yml` or a locally-built push) whenever the entrypoint or patch changes,
or async silently downgrades to stock.

## CI coverage for the azure backend (why it's creds-gated, not hermetic)

The journey is storage-agnostic, so storage-neutrality is an A/B: the *same*
journey must pass under s3 and under azure (a deployment runs exactly one
backend). `ci/matrix.sh` runs the two **tiered** cells under both backends —
`vanilla·tiered` and `mesh·tiered` (the only cells where storage matters:
storage is orthogonal to PG-major/mode; only topology interacts, via the
bakery × commit-latency that surfaced the cutover race). Verified green over
real ADLS: vanilla·tiered·azure **92/0**, mesh·tiered·azure **108/0**.

**The s3 cells are hermetic (SeaweedFS); the azure cells are NOT — they need
real ADLS, gated on `COLDFRONT_AZURE_*` (RUN when present, else PENDING, never
silently skipped).**

Root cause — why azure can't be hermetic when s3 trivially is: the requirement
is **Lakekeeper's**, not DuckDB's or ours. S3 is itself a flat object API, so
Lakekeeper's `s3` profile (and SeaweedFS) talk to it directly — no extra
endpoint. Azure has two APIs: flat **Blob** (`az://`, the true S3 equivalent,
which Azurite *does* emulate) and **ADLS Gen2 / DFS** (`abfss://`). DuckDB's
azure extension speaks **both** — but **Lakekeeper's only Azure storage profile
is `adls`** (no flat-Blob/`wasb` option at all; `host` defaults to
`dfs.core.windows.net`). So the catalog emits `abfss://` table locations and the
whole stack is forced onto the DFS endpoint, even though the data itself (flat
parquet + avro objects) would sit fine on plain Blob. It is the DFS *endpoint*
that's required, not hierarchical namespace per se — a flat (FNS) ADLS account
also satisfies Lakekeeper; HNS just isn't needed.

And there is no ADLS Gen2 emulator: Azurite ships **Blob/Queue/Table only** and
explicitly **does not implement the DFS endpoint** (its own wiki lists DFS as
"Phase I — not in Azurite", HNS as "Phase II"; tracking issue Azure/Azurite#553
open since 2020). So the one Azure API Azurite *can* serve (Blob) is the one
Lakekeeper *won't* use — a hermetic azure cell is unreachable without changing
the catalog layer (or upstream Lakekeeper gaining a flat-Blob Azure profile).
The practical
"runs in CI" answer is a **scheduled/secret-injected job** that sets
`COLDFRONT_AZURE_*` from CI secrets and runs those two cells periodically (not
every PR). The storage-*divergent* code (secret rendering, config selection) is
covered for both backends with **no creds** by the unit + pg_regress layer
(`TestColdSecretSQL_S3/_Azure`, `TestValidate_AzureMode`,
`storage_secret_azure.sql`), which runs on every PR.
