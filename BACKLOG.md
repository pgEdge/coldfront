# ColdFront — Beta Backlog

Remaining work to close out the beta milestone, plus tracked items that are not
blocking it. Snapshot after the standby-reads milestone (`main` @ `e0c3d63`):
the **PG 18 deployment matrix is complete and green** — {vanilla, mesh} ×
{tiered, decoupled} × {primary, standby}, gated by
[`ci/probe-standby.sh`](ci/probe-standby.sh) and exercised by
[`ci/journey.sh`](ci/journey.sh) across [`ci/matrix.sh`](ci/matrix.sh) cells;
pg_regress unit layer 21/21.

Design reference: [ARCHITECTURE.md](ARCHITECTURE.md). Failover is out of scope
(Patroni-delegated) — see [ci/runbooks/failover-patroni.md](ci/runbooks/failover-patroni.md).

## Status at a glance

**Done**
- Canonical user-journey spec (`ci/journey.sh`), matrix runner (`ci/matrix.sh`),
  topologies (`ci/topo/{vanilla,mesh}.sh`), shared helpers (`ci/lib.sh`).
- One parameterized image (`docker/Dockerfile`, `ARG PG_MAJOR`); vanilla and mesh
  built from it.
- All 8 **PG 18** cells green: {vanilla, mesh} × {tiered, decoupled} ×
  {primary, standby}.
- **PG 16, 17, and 18 all supported.** The cold-tier S3 credential is a DuckDB
  PERSISTENT SECRET (set once via `coldfront.set_storage_secret(...)`, loaded at
  instance init) and the `ice` catalog is attached lazily by the C extension hook
  on the first query touching a tiered view — a design that is uniform across PG
  16/17/18 with no version gating.
- Physical standby reads: probe gate, base-backup bring-up (`COLDFRONT_STANDBY_OF`),
  `story_standby_reads`, cold-write fencing on a replica (`pg_is_in_recovery()`
  guard in `_exec_iceberg_with_claim`), `failover-patroni.md` runbook.

**Open** (this document)
1. Operational hardening (`ci/ops/`): privilege model, Lakekeeper-down, S3-down, dump/restore.
2. Standby production-hardening (replication slot, replication role).
3. Tracked upstream gaps (pg_duckdb / duckdb-iceberg).
4. Partition manager — follow-ups (`feat/partition-manager` branch).

---

## PG 16/17/18 matrix cells — *done / supported*

**Status. PG 16, 17, and 18 are all supported and RUN.** `ci/matrix.sh --full`
drives all three majors ({vanilla, mesh} × {tiered, decoupled} × {primary,
standby}); pg_regress runs once per major. The image builds on each (the base
tags exist, pg_duckdb v1.1.1 and the PGXS extension compile), and cold reads
**and** writes work uniformly.

**Why it is uniform across majors.** The cold-tier S3 credential is materialized
as a DuckDB **PERSISTENT SECRET** — set once with
`SELECT coldfront.set_storage_secret('<key>','<secret>','<endpoint>')`, which
also stores the secret in the extension-member `coldfront.storage_secret` table
(excluded from `pg_dump` by default, added to the Spock repset so it replicates
by value to every mesh node). Because DuckDB loads the persistent secret at
instance init, the secret is already committed and visible by the time any
query runs. The `ice` Iceberg catalog is then attached **lazily** by the C
extension hook on the first query that touches a tiered view (read or write).
Nothing in this path depends on a PG 17+ feature, so the same path serves
PG 16, 17, and 18.

---

## 1. Operational hardening (`ci/ops/`) — *beta scope*

A new `ci/ops/` suite, run once per representative cell (not every cell).

- **Non-superuser privilege model.** Define the minimum grants each role needs —
  the application role issuing DML through views, the archiver's role, and (mesh)
  the bakery's dblink role — and run the journey as a **restricted** role. Today
  everything runs as the `coldfront` superuser. Deliverable: a documented grant
  set + an ops cell that runs the journey under it.
- **Lakekeeper-down.** With the REST catalog unreachable: cold reads/writes fail
  with a clear error, while hot-tier access **and node connectability** survive
  (the lazy attach happens inside the failing query, so a catalog outage degrades
  only cold I/O — it never blocks connecting or reading hot data). Assert no
  crash, no hang.
- **S3-down.** Object store unreachable: same graceful-degradation bar (cold I/O
  fails cleanly; hot tier unaffected).
- **`pg_dump` / restore.** Dump the PG side — wrapper views, `coldfront.tiered_views`,
  `archive_watermark`, and the `coldfront.storage_secret` row — restore into a
  fresh PG, and confirm the restored node re-materializes the DuckDB persistent
  secret, attaches to the **same** Iceberg tables on first touch, and reads cold
  data. (The `storage_secret` table is an extension member, so its data is
  excluded from a default `pg_dump`; the restore test must therefore dump it
  explicitly, or re-run `set_storage_secret` on the target, to prove the wiring
  survives. No Iceberg data is in the dump — only the PG-side wiring.)

---

## 2. Standby production-hardening — *near-term*

The PG 18 standby cells prove the mechanism end-to-end; production deployments
additionally want:

- **Physical replication slot.** `standby_up` (`ci/lib.sh`) / the
  `COLDFRONT_STANDBY_OF` entrypoint branch take a base backup with
  `pg_basebackup -R -X stream` and **no slot** — fine for an immediately-attached
  test replica, but production should create a physical slot so the primary
  retains WAL until the standby has consumed it (avoids recycle-induced resync).
- **Dedicated replication role.** Bring-up streams under `trust` from the test
  `pg_hba.conf`. Production should use a dedicated `REPLICATION`-privileged role
  with credentials, not trust.
- **(Optional) lag / role surfacing.** Expose `pg_is_in_recovery()` and replay
  lag so a read-router can route reads to sufficiently-caught-up replicas.

---

## 3. Tracked upstream gaps — *not blocking; coldfront works around each*

See also [ARCHITECTURE.md → Upstream Requests](ARCHITECTURE.md#upstream-requests).

- **Targeted-column Iceberg INSERT** *(found during the standby work).*
  `INSERT INTO <iceberg-table> (col1, col2) VALUES …` raises
  *"Iceberg inserts don't support targeted inserts yet (i.e tbl(col1,col2))."*
  So a decoupled write must supply **all** columns (or omit the column list).
  The journey and the INSTEAD-OF path already do; a user issuing a column-subset
  INSERT against a decoupled view will hit it. **TODO:** document under
  [ARCHITECTURE_DECOUPLED.md → What does not work](ARCHITECTURE_DECOUPLED.md) and
  file upstream against duckdb-iceberg.
- The three existing asks already written up in ARCHITECTURE.md: native
  PG-reader → Iceberg streaming (no libpq round-trip); secret visibility under
  fresh transactions; INSERT into a table that carries a partition spec.

---

## 4. Partition manager — follow-ups — *feat/partition-manager branch*

The standalone partition manager (`cmd/partitioner`, `internal/partition`) is
feature-complete and unit-tested: time/id modes (uuidv7, snowflake), 2-level
LIST→RANGE, behind-detection. The data-lifecycle model is now explicit and
un-conflated — **hot →`hot_period`→ cold →`retention_period`→ gone** (tiered);
**hot →`retention_period`→ gone** (partition-only) — with the archiver tiering
past `hot_period` and dropping cold Iceberg data past `retention_period`.

The tiered archiver now also handles **2-level LIST→RANGE** tables (the
partitioner→tiered upgrade path): `runCycleTwoLevel` premakes per region and
tiers leaves a whole `ts` period at a time across all regions before advancing
the shared watermark (Global boundary, no read gap), with a region-scoped Phase-0
wipe. It already reuses the partition-core premake/find primitives
(`EnsureListChild`/`EnsureFuture`/`EnsureCurrent`/`FindExpired`).

**Config is now an in-DB, Spock-replicated table, not YAML.** Per-table lifecycle
lives in name-keyed `coldfront.partition_config` (`internal/partcfg`), auto-added
to the default repset on a spock node so the mesh self-syncs (vanilla: a no-op
local table). Both binaries read it (YAML `archiver.tables` is a fall-back
deprecation bridge) and expose a management CLI — `register` (with PK + parse +
retention>hot validation), `list`, `set`, `remove`, `import`, `export` — with
verbose per-command help and `--print-sql`/`export` as the config-as-code
clawback. Connection config (DSN, iceberg/S3) stays per-node and never
replicates. Live-verified end-to-end on vanilla by `story_register_cli`.
Remaining work:

- **Mesh `partition_config` replication probe (N×(N-1)).** The repset auto-add
  reuses the proven `_ensure_claims_replicated` mechanism and is confirmed a
  clean no-op on vanilla, but cross-node replication of `partition_config` rows
  is not yet exercised in CI (the quick gate is vanilla). Add a `--full` mesh-cell
  assertion: `register` on one node, confirm the row appears on every peer.
- **Optional: native `interval` columns for `hot_period`/`retention_period`.**
  Currently text (matching `ParseRetention`); moving to `interval` makes the
  cutoff calendar-aware and lets `retention > hot_period` become a table CHECK
  rather than a register-time / run-time Go check (both already enforced, so this
  is polish, not a correctness gap).

Remaining (pre-existing) partition-manager follow-ups:

- ~~Share `RunReconcile`'s premake/find primitives with the archiver.~~
  **RESOLVED — not folding the archiver onto `RunReconcile`.** The worthwhile
  half is already done: the archiver builds directly on the shared
  `internal/partition` primitives (`EnsureFuture`/`EnsureCurrent`/`FindExpired`/
  `EnsureListChild`/`Detach`/`Drop`) and references `RunReconcile` zero times;
  there is no duplicated block left to extract. Folding the *driver* is declined
  on two grounds: (1) the archiver's tier-to-cold is a stateful watermark/cutover
  boundary advance, not the removal `RunReconcile`'s `ExpireFunc` is named for
  (leaky abstraction, tiny DRY win); and (2) for 2-level it is structurally
  impossible — `RunReconcileTwoLevel` iterates region-major / per-partition,
  whereas the shipped Global tiering must go period-major *across* regions
  (export every region's leaf for a ts period before the shared cutoff advances).
  Routing through it would reintroduce the transient vanishing-rows bug that the
  hand-rolled period-grouped `runCycleTwoLevel` eliminates. The orchestration
  legitimately differs by policy over one shared primitive set.
- **Scripted strip to a partition-only build.** The one-way dependency rule
  (iceberg → partition-core, enforced by `cmd/partitioner/arch_test.go`) makes a
  cut possible: a script that deletes the iceberg layer (C extension,
  `internal/view`, `internal/watermark`, the iceberg slice of `cmd/archiver`)
  and leaves a working partition manager. Author + verify the strip.
- **`ci/probe-snowflake.sh` + a partition-only matrix cell.** Make the live
  snowflake `get_epoch` cross-check reproducible (spin a pgEdge container, assert
  `get_epoch*1000 == (id>>22)+1672531200000`), and add an id-mode / 2-level
  partitioner cell to the journey so the new code is exercised in CI, not only
  in unit tests.
- **Mesh N×(N-1) probe for the partitioner.** Before any mesh partitioner run,
  confirm DDL (`CREATE/DETACH/DROP PARTITION`) and the registry replicate in
  every direction, per the standing verify-before-bench rule.

---

## Out of scope for the beta matrix

- **Failover / promotion automation.** Delegated to Patroni. ColdFront's only
  requirement is that its GUCs live in `postgresql.conf` (so they ride a base
  backup), not `ALTER SYSTEM`. The matrix verifies a standby serves reads; what
  happens after Patroni promotes is a Patroni concern. See
  [ci/runbooks/failover-patroni.md](ci/runbooks/failover-patroni.md), including
  the network-partition split-brain-cold-write limitation and the fencing
  mitigation. A real Patroni integration test is possible future work, not a beta
  gate.
