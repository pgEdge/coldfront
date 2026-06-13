# PATCHED — duckdb-iceberg with the bakery-aware commit-refresh patch

> ColdFront has **one agnostic code path** for cold writes — it never 409s on any
> binary. The two deployment modes differ only by **(a) which duckdb-iceberg
> binary is loaded** and **(b) the `coldfront.iceberg_async_parquet` +
> `coldfront.iceberg_bakery_patch` GUCs** (the gate `_iceberg_async_active()`
> needs BOTH on for async; the patched image sets both) — not by any code change:
>
> | mode | binary | `async_parquet` / `bakery_patch` | bakery wraps | uploads |
> |---|---|---|---|---|
> | **PATCHED** (this doc) | patched | `on` / `on` | only the commit POST | overlap (async) |
> | **UNPATCHED** (`UNPATCHED.md`) | stock | `off` / `off` (default) | upload **+** commit | serialized |
>
> An unpatched deployment that sets only `async_parquet=on` (without the marker)
> **fails safe to UNPATCHED** — the gate is false, so it claim-firsts; never a 409.
>
> Both are **no-409**. PATCHED buys contended throughput (concurrent parquet
> uploads overlap; only the Lakekeeper commit is serialized) at the cost of
> building + side-loading a patched extension.

---

## 0. The shared code path (identical in both modes)

`coldfront._exec_iceberg_with_claim` is the single chokepoint every cold write
routes through (decoupled INSERTs, archiver batches, tiered UPDATE/DELETE CTEs).
It picks its strategy at runtime; the SQL is the same whichever iceberg binary is
installed:

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
  **placeholder GUCs**, default `false` (read with `current_setting(..., true)`,
  same pattern as `coldfront.peer_alive_window_ms`). No C definition / no recompile.
- **PATCHED deployments set BOTH `on`** (the image entrypoint) — the patched binary
  re-stamps `parent_snapshot_id` at the deferred commit POST, so the background
  upload is safe, and the `iceberg_bakery_patch` marker tells
  `coldfront._iceberg_async_active()` the patch is present. Stock leaves both off →
  claim-first → also safe. Async-requested-without-the-marker → gate false →
  claim-first (fail-safe), never a 409.
- **409 is impossible in either branch.** The flag only trades upload *overlap*
  (patched) for *serialized* upload (stock). `_tiered_insert_cold` is always
  claim-first (it claims before its batch loop), so tiered INSERTs are unaffected
  by the flag.

## 1. Why PATCHED (performance)

The parquet upload to S3 is the slow part of a cold write; the Lakekeeper commit
POST is fast. PATCHED lets concurrent writers' uploads **overlap** (each stages
its parquet outside the bakery) and serializes only the commit POST under the
ticket — measured ≈ **2.6×** contended throughput vs serializing the uploads.
The patch is what makes that overlap safe; it is a **performance** feature, not a
correctness one (UNPATCHED is equally correct, just serialized).

## 2. What the patch changes (`docker/iceberg-bakery-aware-commit-refresh.patch`)

Two files in duckdb-iceberg, additive/relocating — **no signature change**:

1. **`src/storage/iceberg_transaction_data.cpp`** — removes the eager
   `parent_snapshot_id` stamp from **both** snapshot sites
   (`AddSnapshot` = APPEND/DELETE, `AddUpdateSnapshot` = OVERWRITE). The new
   `IcebergSnapshot` keeps its sentinel defaults through Finalize.
2. **`src/storage/irc_transaction.cpp`** — at the top of
   `IRCTransaction::DoTableUpdates` (PG `PRE_COMMIT`, **inside the held bakery
   ticket**): for each dirty table with a staged `ADD_SNAPSHOT` (and not an
   `ASSERT_CREATE`), re-read the fresh catalog head via `IRCAPI::GetTable`, then
   stamp each staged snapshot's `parent_snapshot_id` (first anchors to the fresh
   head, subsequent chain off the predecessor) and assign monotonic
   `sequence_number`s.

Net: the parent is read from Lakekeeper once, inside the ticket, after the
parquet phase — so under R-A serialization no other writer can move the head
between the refresh and the POST.

> **Baseline of record — never lose this.** The patch above
> (`docker/iceberg-bakery-aware-commit-refresh.patch`, against duckdb-iceberg
> **`ebe0dfaf`** / DuckDB **v1.4.3**, avro `7b75062f`, `EXTENSION_VERSION v1.4.3`)
> is **committed** (`c18a99f`) and is the **known-good, revert-to baseline**;
> `main` always carries this working state. The full code-level diff is §2 above
> plus the committed `.patch`, and the from-scratch rebuild recipe is §5–§8 — so
> the 1.4.3 patched extension is fully recoverable from this doc alone. Any
> DuckDB-1.5.x port is authored as a **separate** patch file + pin set (e.g.
> `iceberg-bakery-aware-commit-refresh-v1.5.patch`) and **does not overwrite this
> one**.

## 3. CRITICAL: ship BAKERY-ONLY — do NOT apply the mvcc-fix patch

`docker/iceberg-extension-mvcc-fix.patch` (rewrites `IRCTransaction::Commit()` to
take a `ClientContext&`) **breaks commit on pg_duckdb v1.1.1**: the iceberg
commit fires from the deferred `PRE_COMMIT` callback where the caller's context
has no active transaction →

```
TransactionContext Error: Failed to commit: ... ActiveTransaction called without active transaction
```

It targets a 403-on-non-AWS-S3 bug that does **not** manifest here (stock writes
to the S3-compatible store fine for single writers). **Build the bakery patch
only.**

## 4. Version pinning (do not drift)

| Component | Pin | Confirm |
|---|---|---|
| pg_duckdb | `v1.1.1` | `Makefile: DUCKDB_VERSION = v1.4.3` |
| DuckDB core | `v1.4.3` (`d1dc88f9`) | pg_duckdb `third_party/duckdb` submodule |
| duckdb-iceberg | **`ebe0dfaf`** ("Bump to v1.4.3") | its `duckdb` submodule == `d1dc88f9` == `refs/tags/v1.4.3` |

Both patches apply cleanly to a **pristine** `ebe0dfaf`. A *dirty* checkout that
already holds the bakery post-image will fail `git apply --check` — **always
build from a fresh clone.**

## 5. BUILD

Out-of-band, clean toolchain container (`manylinux_2_28_x86_64` = gcc-toolset-14,
sidesteps a GCC-11 avro bug). Cold build ≈ 11 min; only the two artifacts ship.

```bash
docker pull quay.io/pypa/manylinux_2_28_x86_64
docker run -d --name iceberg-builder quay.io/pypa/manylinux_2_28_x86_64 sleep infinity
docker exec iceberg-builder dnf install -y --setopt=install_weak_deps=False \
    ninja-build perl-IPC-Cmd ccache jq wget zip unzip tar autoconf libtool kernel-headers cmake git make

docker exec iceberg-builder bash -c '
  cd /build
  git clone --filter=blob:none --no-checkout https://github.com/duckdb/duckdb-iceberg
  cd duckdb-iceberg && git checkout ebe0dfaf
  git submodule update --init --recursive --depth 1 --jobs 8
  git clone https://github.com/microsoft/vcpkg /build/vcpkg && /build/vcpkg/bootstrap-vcpkg.sh'

# Slim build config + the BAKERY patch only (NOT the mvcc-fix):
docker cp docker/iceberg-only-extension-config.cmake       iceberg-builder:/build/duckdb-iceberg/extension_config.cmake
docker cp docker/iceberg-bakery-aware-commit-refresh.patch iceberg-builder:/tmp/
docker exec iceberg-builder bash -c '
  cd /build/duckdb-iceberg
  git apply --check /tmp/iceberg-bakery-aware-commit-refresh.patch   # fail fast on patch rot
  git apply        /tmp/iceberg-bakery-aware-commit-refresh.patch'

docker exec -w /build/duckdb-iceberg \
  -e VCPKG_TOOLCHAIN_PATH=/build/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -e VCPKG_ROOT=/build/vcpkg -e VCPKG_TARGET_TRIPLET=x64-linux -e VCPKG_HOST_TRIPLET=x64-linux \
  -e USE_MERGED_VCPKG_MANIFEST=1 -e EXT_CONFIG=/build/duckdb-iceberg/extension_config.cmake \
  -e OVERRIDE_GIT_DESCRIBE=v1.4.3 \
  iceberg-builder bash -c 'source /opt/rh/gcc-toolset-*/enable 2>/dev/null;
                           CMAKE_BUILD_PARALLEL_LEVEL=$(nproc) MAKEFLAGS=-j$(nproc) make release'

docker cp iceberg-builder:/build/duckdb-iceberg/build/release/extension/iceberg/iceberg.duckdb_extension .
docker cp iceberg-builder:/build/duckdb-iceberg/build/release/extension/avro/avro.duckdb_extension .
```

- `docker/iceberg-only-extension-config.cmake` trims to iceberg + avro only and
  re-pins avro to `93da8a19` (the GCC-11-safe head).
- `OVERRIDE_GIT_DESCRIBE=v1.4.3` stamps the ABI/version footer to match DuckDB
  v1.4.3.
- **Per-arch:** x86_64 only here; `linux_arm64`/`darwin-*` need native builders
  with the matching `VCPKG_TARGET_TRIPLET`.

## 6. INSTALLATION

pg_duckdb auto-installs the **signed upstream** iceberg into a per-data-dir
cache. To load the **local, patched** build instead:

1. **Place** the two artifacts at the path DuckDB resolves — default
   `<PGDATA>/pg_duckdb/extensions/v1.4.3/<platform>/` (e.g.
   `.../v1.4.3/linux_amd64/{iceberg,avro}.duckdb_extension`). The `v1.4.3` segment
   is pg_duckdb's DuckDB version. Use the live `$PGDATA`, never a hardcoded path.
2. If you placed over an auto-installed file, **delete** the `*.duckdb_extension.info`
   sidecars (they hold the upstream signature). When baked into the image (§8)
   nothing auto-installs, so there is no `.info` to delete.
3. **GUCs** (all four):
   - `duckdb.allow_unsigned_extensions = on` — required; the local bytes are
     unsigned.
   - `duckdb.autoinstall_known_extensions` — shipped **on** (`docker/entrypoint.sh`).
     Verified empirically (fresh PG 16 container): with the local file present,
     autoinstall does **not** re-download or clobber it (patched iceberg sha identical
     before/after a load) — it only fetches *missing* extensions. (The earlier "must
     be off, else it clobbers the local one" was wrong.) Turning it off instead means
     iceberg's required `avro` dependency — and `azure`, for an Azure cold tier —
     won't auto-install and must be pre-placed (see the avro note below).
   - `duckdb.autoload_known_extensions = on` — keep; lazily LOADs on `ATTACH`.
   - **`coldfront.iceberg_async_parquet = on`** — requests the async-upload code
     path (safe only because the patch is present).
   - **`coldfront.iceberg_bakery_patch = on`** — ASSERTS the loaded duckdb-iceberg
     is the bakery-aware build. `coldfront._iceberg_async_active()` enables the
     async ordering ONLY when BOTH GUCs are on; with the patch present this image
     sets both (entrypoint). On a stock/bare-metal deployment that flips only the
     async flag, the gate is false → `_exec_iceberg_with_claim` fails safe to the
     stock claim-first ordering (never a 409; one-time server-log advisory). The
     patched images set both together; do NOT set `iceberg_bakery_patch` on a stock
     binary.

> **avro is a HARD dependency of iceberg — pre-place BOTH (verified).** iceberg's
> init (`iceberg_duckdb_cpp_init`) requires `avro` and tries to auto-install it at
> load. With `autoinstall` **off** and `avro` absent, `LOAD iceberg` fails:
> *"An error occurred while trying to automatically install the required extension
> 'avro': … avro.duckdb_extension not found."* So whenever autoinstall is off, `avro`
> MUST be pre-placed beside `iceberg` — and the same goes for any other extension a
> feature needs offline (e.g. `azure` for an Azure cold tier). With autoinstall on
> (the shipped default) a missing `avro` is fetched automatically; pre-placing it is
> then belt-and-suspenders (offline/determinism), not strictly required.

### GUC gotchas (learned the hard way)

- The three `duckdb.*` GUCs are `PGC_SUSET` and read **once at DuckDB init**; the
  check hook rejects changing them after init. DuckDB inits the first time a
  session touches it, so apply these via **`ALTER SYSTEM` + reload** before any
  DuckDB use, **one `ALTER SYSTEM` per statement** (two in one `psql -c` =
  "cannot run inside a transaction block"). In `postgresql.conf` (the image path)
  they are present from first init, so this trap never arises.
- **Set `allow_unsigned=on` before any unsigned binary can load.** If a
  bad/unsigned iceberg binary is in place with `allow_unsigned` still off, the
  catalog `ATTACH` raises the first time a tiered view is queried. The catalog is
  attached **lazily** by the C extension hook on the first query that touches a
  tiered view (read or write) — the attach is on demand, with no connect-time
  setup, so a failed `ATTACH` only fails that query rather than refusing connections.
  Always set `allow_unsigned=on` first so the local bytes load cleanly. (The
  cold-tier S3 credentials are independent of these GUCs: they are a persistent
  DuckDB secret materialized by `coldfront.set_storage_secret(...)`, loaded at
  DuckDB init.)

## 7. RUNNING THE E2E (verify before any bench)

```bash
# (A) identity — same patched bytes on every node:
for n in db1 db2 db3; do
  docker exec coldfront-${n}-1 md5sum "$PGDATA/pg_duckdb/extensions/v1.4.3/linux_amd64/iceberg.duckdb_extension"
done                                                   # all md5s identical

# (B) the LOCAL patched build is loaded (not stock):
psql -c "SELECT duckdb.raw_query('SELECT extension_name, loaded, install_path
   FROM duckdb_extensions() WHERE extension_name IN (''iceberg'',''avro'')');"
   # loaded=true, install_path under .../v1.4.3/linux_amd64/ (local, not a URL)

# (C) flag on + 3-way OVERLAPPING decoupled INSERT into one table → 3/3, no 409:
#     same-node (all on db1) AND cross-node (db1+db2+db3).
#     A 409 → flag on without the patched binary (check B). An ActiveTransaction
#     error → the mvcc-fix slipped into the build (see §3).
```

**Live-proven (3-node mesh):** patched binary (md5 `880d485c…`, identical on all
nodes, `loaded=true`, local `install_path`) + `iceberg_async_parquet=on` →
3-way overlap **3/3 no-409, same-node and cross-node**.

## 8. Image wiring (one image, both roles)

`docker/Dockerfile` (`PG_MAJOR ∈ {16,17,18}`) carries the patched binary:

1. **`iceberg-builder` stage** — `FROM quay.io/pypa/manylinux_2_28_x86_64`; run §5
   (fresh `ebe0dfaf` clone, **bakery patch only**, slim cmake,
   `OVERRIDE_GIT_DESCRIBE=v1.4.3`, `make release`); `git apply --check` gates it.
2. **Runtime stage** — `COPY --from=iceberg-builder` the two artifacts to a
   staging path; `ENV COLDFRONT_DUCKDB_VERSION=v1.4.3 COLDFRONT_DUCKDB_PLATFORM=linux_amd64`.
3. **`docker/entrypoint.sh`** (first-init block) — write to `postgresql.conf`:
   `duckdb.allow_unsigned_extensions = on`, `duckdb.autoinstall_known_extensions = on`
   (the actual entrypoint value — `on` is safe per §6: it won't clobber the present
   patched binary, and lets missing deps like `avro` auto-install),
   `duckdb.autoload_known_extensions = on`, **`coldfront.iceberg_async_parquet = on`**,
   **`coldfront.iceberg_bakery_patch = on`** (the marker that asserts this image's
   iceberg is patched — both are set together so `_iceberg_async_active()` enables
   async; see §6);
   then `mkdir -p "$PGDATA/pg_duckdb/extensions/$COLDFRONT_DUCKDB_VERSION/$COLDFRONT_DUCKDB_PLATFORM"`
   and copy the staged binaries in. (The stock/UNPATCHED build does none of this —
   no binary placement, `allow_unsigned` off, and **neither** the async flag nor the
   bakery-patch marker set; autoinstall is on in both.)

Build-cost note: a cold image build includes the ≈ 11 min iceberg compile;
mitigate with BuildKit vcpkg/layer caching, or a separately-tagged
`iceberg-builder` image the app Dockerfile `COPY --from`s.

## 9. Files

| File | Role |
|---|---|
| `docker/iceberg-bakery-aware-commit-refresh.patch` | **Shipped.** Defers `parent_snapshot_id` into `DoTableUpdates` (inside the bakery). |
| `docker/iceberg-only-extension-config.cmake` | Slim build config: iceberg + avro only; avro re-pinned `93da8a19` (GCC-11-safe). |
| `docker/iceberg-extension-mvcc-fix.patch` | **NOT shipped** — breaks commit on pg_duckdb v1.1.1 (§3). |

## 10. Reverting to UNPATCHED

No code change. Flip to stock: unset `coldfront.iceberg_bakery_patch` — with the
marker off, `_iceberg_async_active()` is false, so the code falls back to
claim-first even if the async flag is left on (or also set
`coldfront.iceberg_async_parquet = off`). Restore stock iceberg (delete the local
binaries + `autoinstall = on`, or let autoinstall overwrite), set
`allow_unsigned = off`. See `UNPATCHED.md`.

## 11. FIXED — partition cutover now serializes through the bakery (was a cold-write race)

**Fixed in `coldfront.cutover_archive` + `cmd/archiver/main.go`.** This was a
ColdFront-SQL gap, independent of the iceberg bakery patch above and **identical
in the 1.4.x and 1.5.x stacks** — so the same fix applies to the 1.4.x stack if
it is ever revived. It was *latent under S3* and only surfaced by Azure ADLS's
higher commit latency. "The bakery works flawlessly under S3" was true only by
*timing luck*, not by design. The diagnosis is kept below as the recipe.

**The gap (the bug).** The bakery (`coldfront_iceberg:<ref>` advisory-xact-lock
in vanilla / R-A claim in mesh) serializes cold **writes** against each other —
but the archiver's **phase-4 cutover** (`coldfront.cutover_archive`) did **not**
take it. The proc went straight to `LOCK TABLE … ACCESS EXCLUSIVE` on the parent
+ partition (with `lock_timeout`, retried ~10× / ~102 s by the archiver). So the
cutover was **not a bakery participant** and merely *raced* concurrent cold
writers for the partition lock.

**Symptom.** With a concurrent cold write to a partition being cut over (e.g.
`ci/journey.sh` story 9's race window), the racing write holds the partition
`RowExclusive` **for the full duration of its iceberg commit**. On S3 that
commit is fast, so it finished inside the cutover's retry budget and the cutover
won a retry — *looked flawless*. On a slow store (Azure) the commit took longer
than ~102 s of retries, so all 10 cutover attempts failed with
`ERROR: canceling statement due to lock timeout (SQLSTATE 55P03)`; the archiver
logged `phase 4 (cutover) failed after 10 attempts; trigger+delta left for next
cycle`. Data was never lost (export + write both landed; only the swap deferred),
but the cycle did not complete. Lock graph captured on Azure: the racing
`UPDATE` sat `state=active` holding `RowExclusive` while the archiver's
`CALL cutover_archive` spun on the `ACCESS EXCLUSIVE` it could not get.

**The fix.** `cutover_archive` gained a `p_iceberg_ref` parameter and now
acquires the **same bakery** a cold write takes — same `v_armed` gate
(`pg_advisory_xact_lock(hashtext('coldfront_iceberg:'||ref))` vanilla /
`_claim_iceberg_lock(ref)` + `_enqueue_release` mesh), on the **same key** — *as
its first lock, before* the `SET LOCAL lock_timeout` + `LOCK TABLE … ACCESS
EXCLUSIVE`. The archiver passes the iceberg ref as the new 7th `CALL` argument
(`cmd/archiver/main.go`); the cold-write path (`_exec_iceberg_with_claim`,
`_claim_iceberg_lock`) is **unchanged**. Because the bakery acquire has **no**
`lock_timeout`, the cutover now *waits out any in-flight cold writer's full
commit* (which releases its partition `RowExclusive`) and blocks new writers,
then takes the now-uncontended `ACCESS EXCLUSIVE`.

**Why it is deadlock-free (and why the obvious "global lock order" does not
hold).** Two resources: **A** = the partition heavyweight lock (writer's
`RowExclusive`, cutover's `ACCESS EXCLUSIVE`); **B** = the bakery. The textbook
fix would be a global order *B-before-A everywhere*. The **cutover** obeys it (B
then A). The **dual-tier (TIER_AMBIGUOUS) writer cannot**: PostgreSQL locks a
`ModifyTable`'s result relations (the hot partition `RowExclusive`, A) at
**executor startup**, *before* any `WITH` CTE is evaluated — so no CTE
data-dependency trick can make its cold-CTE bakery claim (B) run first. The
writer is unavoidably **A-before-B**, i.e. a genuine lock-order inversion vs the
cutover. (An adversarial review caught an earlier attempt to "pin" B-before-A
via a leading claim CTE: it is *impossible* for this reason, and the text-append
it required also corrupted the no-`WHERE` UPDATE/DELETE case — it was dropped.)

Deadlock-freedom therefore comes from the **`lock_timeout` circuit breaker on
A**, not from lock ordering: `cutover_archive`'s `LOCK TABLE` uses
`lock_timeout = 100 ms`, which is `<` PostgreSQL's `deadlock_timeout` (1 s, and
also `<` the R-A spin). So whenever the inversion forms (writer holds A, waits
for B; cutover holds B, waits for A), the **cutover** is always the party that
yields first — it errors out in 100 ms, frees B (vanilla: xact-scoped advisory
auto-release; mesh: the C `XactCallback` drains the enqueued release at the
proc's ABORT), the writer then gets B and commits, and the Go harness retries
the whole cutover. The writer is **never** the victim. The common case — a
writer *mid-commit*, already holding **both** A and B (the slow-Azure case) — is
the win: the cutover's no-timeout wait on B blocks until that writer commits and
drops A, then takes the free A on the first try.

**Validated on Azure (vanilla):** `phase 4 attempt 1 (cutover): 1m26s` — the
86 s was the cutover *patiently waiting on B* for the in-flight cold writer
(blocking graph: cutover `Lock:advisory`, `blocked_by` the writer holding
`coldfront_iceberg:"ice"."default"."events"`); it then succeeded on the **first**
attempt, `archive cycle complete`, no 409, and **no cross-tier duplication**
(`count(*) == count(distinct id)` for the raced rows). Contrast the pre-fix
failure: `phase 4 (cutover) failed after 10 attempts`.
