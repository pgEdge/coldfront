# UNPATCHED — stock duckdb-iceberg

> **⚠ Historical.** This documents the stock-binary mode on the **retired DuckDB
> 1.4.3** stack. The current build is the patched DuckDB 1.5.x base
> (`docker/Dockerfile.duckdb15-base`); see [DUCKDB_1.5.md](DUCKDB_1.5.md). The
> stock-vs-patched concepts below still apply.

> ColdFront has **one agnostic code path** for cold writes — it never 409s on any
> binary. The two deployment modes differ only by **(a) which duckdb-iceberg
> binary is loaded** and **(b) the `coldfront.iceberg_async_parquet` flag** — not
> by any code change:
>
> | mode | binary | `iceberg_async_parquet` | bakery wraps | uploads |
> |---|---|---|---|---|
> | **UNPATCHED** (this doc) | stock | `off` (default) | upload **+** commit | serialized |
> | **PATCHED** (`PATCHED.md`) | patched | `on` | only the commit POST | overlap (async) |
>
> UNPATCHED is the **stock default**: signed upstream iceberg, flag off, the
> bakery ticket held across the parquet upload *and* the commit (claim-first).
> Correct and **no-409**; concurrent writers to one table serialize their
> uploads. Choose it when you don't need PATCHED's contended-upload throughput.

---

## 0. The shared code path (identical in both modes)

`coldfront._exec_iceberg_with_claim` — the single cold-write chokepoint — selects
its strategy at runtime. The SQL is the same whichever iceberg binary is
installed; UNPATCHED simply takes the `ELSIF v_armed` branch (flag off):

```sql
IF v_armed AND v_async THEN          -- PATCHED: patched binary + flag ON
    PERFORM duckdb.raw_query(p_sql);                  -- upload parquet in the background (outside the claim)
    my_ticket := coldfront._claim_iceberg_lock(...);  -- claim only to wrap the deferred commit POST
    PERFORM coldfront._enqueue_release(my_ticket);
ELSIF v_armed THEN                   -- UNPATCHED (THIS MODE): stock binary + flag OFF (default)
    my_ticket := coldfront._claim_iceberg_lock(...);  -- claim FIRST
    PERFORM coldfront._enqueue_release(my_ticket);
    PERFORM duckdb.raw_query(p_sql);                  -- upload+commit INSIDE the held ticket
ELSE                                 -- vanilla single-node: local advisory lock
    PERFORM pg_advisory_xact_lock(...);
    PERFORM duckdb.raw_query(p_sql);
END IF;
```

- `coldfront.iceberg_async_parquet` is a placeholder GUC, **default `false`** —
  so UNPATCHED needs no setting at all; it's the out-of-the-box behavior.
- Claim-first means the bakery ticket is held across the parquet upload, so only
  one writer stages+commits a given table at a time → each reads a fresh catalog
  head and stamps a fresh `parent_snapshot_id` on **stock** iceberg → **no 409**.
- Orphan-safe: the release is enqueued for the C `XactCallback`, which fires on
  **both** `XACT_EVENT_COMMIT` and `XACT_EVENT_ABORT`, so a failed upload inside
  the ticket can't orphan the claim.

## 1. BUILD

**Nothing to build.** pg_duckdb auto-installs the signed upstream
iceberg + avro from `extensions.duckdb.org` (matching DuckDB v1.4.3) on first
use. No `iceberg-builder` stage, no patches, no side-loaded binary — the stock
default satisfies CLAUDE.md's "stock upstream, no fork, no patches."

## 2. INSTALLATION

**Nothing to install or set** beyond the current committed image — these are the
defaults:

- `duckdb.autoinstall_known_extensions = on`  (entrypoint default — fetches signed upstream iceberg/avro)
- `duckdb.autoload_known_extensions = on`     (entrypoint default — lazy LOAD on `ATTACH ... TYPE ICEBERG`)
- `duckdb.allow_unsigned_extensions`          (unset → off; the signed upstream extension loads normally)
- `coldfront.iceberg_async_parquet`           (unset → off → claim-first)

Explicitly **do NOT** add any of `PATCHED.md`: no iceberg-builder stage, no
`COPY` of a `*.duckdb_extension`, no `allow_unsigned`, and leave
`iceberg_async_parquet` unset. The default `docker/Dockerfile` + `entrypoint.sh`
are already the UNPATCHED image.

## 3. RUNNING THE E2E (verify)

```bash
# 3-way OVERLAPPING decoupled INSERT into one Iceberg table → 3/3, no 409:
#   same-node (all on db1) AND cross-node (db1+db2+db3).
# Claim-first serializes the uploads, so each writer reads a fresh head — no 409.
```

**Live-proven (3-node mesh):** stock iceberg + `iceberg_async_parquet=off`
(claim-first) → 3-way overlap **3/3 no-409**, same-node and cross-node. (For
contrast, stock with the flag mistakenly **on** would 409 — which is exactly why
the default is off and only the PATCHED image sets it on.)

No md5 / `install_path` / `allow_unsigned` checks are needed (stock, signed,
auto-installed). There is never an `ActiveTransaction` error (no mvcc-fix patch
in play).

## 4. The trade-off

Claim-first holds the bakery ticket across the parquet **upload + commit**, so
concurrent writers to the same table serialize their (slow) S3 uploads instead of
overlapping them — the inverse of PATCHED's ≈ 2.6× contended throughput. Affected
paths (those routing through `_exec_iceberg_with_claim`): decoupled INSERTs,
archiver batches, tiered UPDATE/DELETE. **Not** affected: single-writer /
sequential writes, writes to different tables, and tiered **INSERT**s
(`_tiered_insert_cold` is always claim-first regardless of the flag).

## 5. UNPATCHED vs PATCHED — same code, different binary + flag

| | UNPATCHED (this doc) | PATCHED |
|---|---|---|
| coldfront code | **identical** (agnostic, flag-gated) | **identical** (agnostic, flag-gated) |
| duckdb-iceberg binary | stock, signed, auto-installed | locally built, side-loaded |
| `coldfront.iceberg_async_parquet` | `off` (default) | `on` |
| `duckdb.allow_unsigned_extensions` | off | on |
| build / maintenance | none (the default) | iceberg-builder stage, version pinning, per-arch |
| concurrent same-table writes | **no 409** (uploads serialized) | **no 409** (uploads overlap) |
| contended upload throughput | baseline | ≈ 2.6× |

Same code in both columns — the only knobs are the binary and the flag. Run
**UNPATCHED** by default; switch to **PATCHED** when contended parquet-upload
throughput on the cold-write paths matters (see `PATCHED.md`).
