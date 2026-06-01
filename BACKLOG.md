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
1. PG 16 / 17 matrix cells.
2. Operational hardening (`ci/ops/`): privilege model, Lakekeeper-down, S3-down, dump/restore.
3. Login-trigger graceful degradation.
4. Standby production-hardening (replication slot, replication role).
5. Tracked upstream gaps (pg_duckdb / duckdb-iceberg).
6. Partition manager — follow-ups (`feat/partition-manager` branch).

---

## 1. PG 16 / 17 matrix cells — *beta scope*

**What.** The matrix RUNs only PG 18 today; `coverage_table` in `ci/matrix.sh`
lists every PG 16 and PG 17 cell as `PENDING (needs pg16/17 image build)`. Bring
up and green the full matrix on 16 and 17: {vanilla, mesh} × {tiered, decoupled}
× {primary, standby} = 8 cells per major.

**Why.** Beta targets PG 16, 17, 18 (stock upstream, no fork). The journey and
its assertions are version-independent; only the image's `PG_MAJOR` differs.

**Approach.**
- Image is already parameterized: `docker build --build-arg PG_MAJOR=16 …` (and
  17). `ci/topo/{vanilla,mesh}.sh` already accept `--pg`. Confirm the base
  `ghcr.io/pgedge/pgedge-postgres:<pg>-spock5-minimal` tag exists for 16 and 17,
  that pg_duckdb v1.1.1 compiles against each, and that the coldfront PGXS
  extension builds against each.
- Add `cell_pg{16,17}_*` functions to `ci/matrix.sh` mirroring the PG 18 set,
  driving `topo/*.sh --pg <major>`; run them in `--full`.
- Run pg_regress **once per major** (`--regress` on one cell per version, as PG 18
  does today).
- Flip the `coverage_table` 16/17 rows from PENDING to RUN as each major greens.

**⚠ PG 16 blocker — LOGIN event triggers are PG 17+.** The auto-attach mechanism
(`coldfront._login_session_init`, gated by `arm_login_attach()`) is a **LOGIN
event trigger**, which **does not exist before PG 17** (the function comment says
"Requires PostgreSQL 17+"). On PG 16 the catalog is therefore never auto-attached
per session, so a transparent read through the view fails with
"Catalog 'ice' does not exist" until something attaches it. Options to evaluate:
- **Lazy attach in the DML/planner hook** — have `post_parse_analyze_hook` call
  `ensure_attached()` the first time it sees a query on a registered view. Works
  on all majors and removes the LOGIN-trigger dependency entirely (could then
  supersede the trigger on 17/18 too). Preferred.
- Require operators on PG 16 to `SELECT coldfront.ensure_attached()` per session
  (documented limitation) — weaker, breaks "transparent".

Until resolved, either gate PG 16 support on the lazy-attach work or document the
manual-attach caveat. Other version-sensitive spots to check: partition pruning,
identity/generated-column syntax, and any `pg_catalog` shape the hooks read.

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
Remaining work before/around merging it:

- **Optionally share `RunReconcile`'s premake/find primitives with the
  archiver.** The two products genuinely share only *plumbing* — premake the
  forward window, ensure the current period, find partitions past an age cutoff.
  They do **not** share a *policy*: partition-only eviction is a stateless
  `DROP`, whereas the archiver's tier-to-cold is a stateful boundary advance
  (watermark + atomic cutover) that must not be modelled as "expiration". A
  rewire should share the primitives and keep the boundary-crossing as the
  archiver's own clearly-named operation (an `OnEvict`-style hook with `drop` vs
  `tier` implementations) — *not* fold the whole archiver through an
  `ExpireFunc` named for removal. Lower priority now that the lifecycle split has
  removed the vocabulary conflation; the DRY win is small.
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
