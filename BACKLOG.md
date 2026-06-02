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
- Physical standby reads: probe gate, base-backup bring-up (`COLDFRONT_STANDBY_OF`),
  `story_standby_reads`, cold-write fencing on a replica (`pg_is_in_recovery()`
  guard in `_exec_iceberg_with_claim`), `failover-patroni.md` runbook.

**Open** (this document)
1. PG 16 matrix cells — *upstream-blocked* (PG 17 is now supported and RUN).
2. Operational hardening (`ci/ops/`): privilege model, Lakekeeper-down, S3-down, dump/restore.
3. Login-trigger graceful degradation.
4. Standby production-hardening (replication slot, replication role).
5. Tracked upstream gaps (pg_duckdb / duckdb-iceberg).
6. Partition manager — follow-ups (`feat/partition-manager` branch).

---

## 1. PG 16 matrix cells — *upstream-blocked*

**Status.** **PG 17 is supported and RUN** — `ci/matrix.sh --full` drives both 17
and 18 ({vanilla, mesh} × {tiered, decoupled} × {primary, standby}); pg_regress
runs once per major. **PG 16 is blocked by an upstream bug**, not by tooling: the
image builds fine on 16 (the base tag exists, pg_duckdb v1.1.1 and the PGXS
extension both compile), but cold **writes** cannot work — see below.

**⚠ PG 16 blocker — LOGIN event triggers are PG 17+, and they are the only fix
for the duckdb-iceberg secret-visibility bug.** ColdFront's auto-attach
(`coldfront._login_session_init`) is a **LOGIN event trigger**, which **does not
exist before PG 17**. Its real job is not just convenience: per
[ARCHITECTURE.md → Upstream Requests → "duckdb-iceberg: secret visibility under
fresh transactions"](ARCHITECTURE.md#upstream-requests), a fresh DuckDB
transaction (which `IRCTransaction::Commit` opens) cannot see an S3 secret
registered in the *same, still-uncommitted* transaction — so a cold write's
commit fails with `HTTP 403` against any non-AWS endpoint **unless a prior,
committed DuckDB transaction loaded the secret first**. The login trigger's
`ATTACH IF NOT EXISTS` is exactly that prior committed transaction.

**Lazy attach was evaluated and does NOT work** (verified empirically, 2026-06).
Calling `ensure_attached()` from `post_parse_analyze_hook` on the first query
attaches inside the *write's own* transaction → the secret isn't yet committed
when `IRCTransaction::Commit` looks it up → the same `403`. It fixes cold *reads*
(no Iceberg commit) but not cold *writes*. There is no PG 16-compatible hook that
runs in a *prior* transaction at session start (parse-analyze/executor hooks are
all nested in the user's statement; `ClientAuthentication_hook` / `_PG_init`
fire before any transaction exists). Patching pg_duckdb is out of scope (stock
upstream, no fork).

**Resolution.** PG 16 stays `PENDING` until the upstream fix lands (either
`IRCTransaction::Commit` runs commit-time I/O under the caller's `ClientContext`,
or pg_duckdb commits a synthesised secret's transaction before consumers look it
up). Then PG 16 can use the lazy-attach path with no login trigger. Tracked as a
[duckdb-iceberg upstream request](ARCHITECTURE.md#upstream-requests).

---

## 2. Operational hardening (`ci/ops/`) — *beta scope*

A new `ci/ops/` suite, run once per representative cell (not every cell).

- **Non-superuser privilege model.** Define the minimum grants each role needs —
  the application role issuing DML through views, the archiver's role, and (mesh)
  the bakery's dblink role — and run the journey as a **restricted** role. Today
  everything runs as the `coldfront` superuser. Deliverable: a documented grant
  set + an ops cell that runs the journey under it.
- **Lakekeeper-down.** With the REST catalog unreachable: cold reads/writes fail
  with a clear error, while hot-tier access **and node connectability** survive
  (tied to item 3). Assert no crash, no hang.
- **S3-down.** Object store unreachable: same graceful-degradation bar (cold I/O
  fails cleanly; hot tier unaffected).
- **`pg_dump` / restore.** Dump the PG side — wrapper views, `coldfront.tiered_views`,
  `archive_watermark`, `runtime_config`, and the DuckDB S3 secret
  (`pg_foreign_server`) — restore into a fresh PG, and confirm it re-attaches to
  the **same** Iceberg tables and reads cold data. (No Iceberg data is in the
  dump — only the PG-side wiring; the test proves the wiring survives a restore.)

---

## 3. Login-trigger graceful degradation — *robustness gap (beta scope)*

**What.** `coldfront._login_session_init()` calls `ensure_attached()` with no
error handling. After `arm_login_attach()`, if Lakekeeper/S3 is unreachable the
`ATTACH … (TYPE ICEBERG …)` raises → the trigger raises → **login is rejected**.
The node becomes unconnectable, unable even to read hot data. (The current
comment frames the rejection as "the right signal for a broken setup" — too
strict for an HA deployment, and the failure mode an ops Lakekeeper-down test
will surface.)

**Why.** A transient catalog/object-store outage must not lock operators out of
an otherwise healthy node.

**Approach.** Make login-time attach failure **non-fatal**: the session connects,
`ice` is simply not attached, cold queries fail with a clear "catalog not
attached" message, hot queries work. **Constraint:** pg_duckdb hard-rejects
subtransactions, so this **cannot** be a `BEGIN … EXCEPTION WHEN …` block — it
must be a **precondition check** (cheaply probe catalog reachability before the
ATTACH) or a **GUC** (e.g. `coldfront.attach_on_login = 'try' | 'require'`)
selecting fail-soft vs fail-hard. Driven by the `ci/ops/` Lakekeeper-down story
(item 2). Note this also interacts with the PG 16 lazy-attach work (item 1): if
attach moves into the DML hook, the same fail-soft policy applies there.

---

## 4. Standby production-hardening — *near-term*

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

## 5. Tracked upstream gaps — *not blocking; coldfront works around each*

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

## 6. Partition manager — follow-ups — *feat/partition-manager branch*

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
