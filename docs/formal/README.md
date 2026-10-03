# Formal Model - ColdFront Decoupled-Mode Bakery (TLA+/PlusCal)

This directory contains a formal model of the multi-writer Iceberg commit
serialization protocol that lives in
[extension/coldfront/coldfront--1.0.sql](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--1.0.sql)
and
[extension/coldfront/src/coldfront.c](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/src/coldfront.c).
The CI journey (`ci/journey.sh` - `story_mesh` / `story_decoupled_concurrency`
/ `story_mesh_substrate`, driven by `ci/matrix.sh`) tests the protocol against
a fixed mesh shape - three docker containers, single iceberg table, well-paced
workload. The model exhaustively explores **every interleaving** of N writers
within bounded depth, including failure injections that the CI cannot easily
reproduce.

## Files

This section catalogs the model files and the role each one plays. The model
gives each node its own local view of the claims and propagates inserts through
an explicit applier. The following table describes its files and their roles:

| File | Role |
|---|---|
| `Bakery.tla` | This file is the PlusCal source. It models the real Spock world: each node has its OWN local `claims[nd]` view, and INSERTs propagate via an explicit `Applier`. The model does not assume `synchronous_commit = remote_apply`. Coordination is Lamport's 1978 distributed mutual exclusion algorithm with Ricart-Agrawala's (1981; henceforth abbreviated R-A) deferred-reply optimization: peers ack each claim immediately unless they have a pending claim with smaller ticket, in which case they defer the ack until they release their own claim. The file also models the `coldfront.iceberg_async_parquet` flag (constants `AsyncParquet`/`RestampPatch`): the `Stage` label stages parquet OUTSIDE the claim (async ordering); `Prepare` captures the `parent_snapshot_id` UNDER the claim (stock at stage time, patched async re-stamped at the commit POST); the conditional commit at `Decide` asserts against it. Defer/drain atomicity is modeled too (constant `SafeAcks`): the apply-time defer DECISION and its WRITE (`ApplyDecide`/`ApplyEmit`), and the release drain's FORWARD and DELETE (`DrainForward`/`DrainDelete`), are SEPARATE steps, faithful to the non-atomic SQL. `SafeAcks=FALSE` lets them race (a deferral written behind a just-released claim is deleted unforwarded / orphaned - a dropped ack); `SafeAcks=TRUE` is the safe implementation: an atomic re-check of R-A's own defer rule against the claim, i.e. `SELECT … FOR UPDATE` on the claim row in `coldfront._on_claim_apply`. The orphan reaper is modeled as well (constant `Reaper`): a same-node claim whose writer has crashed holds no advisory lock, so `BeginClaim` deletes it in the step that inserts its own claim; the `Applier` does the same on its defer branch under `HoldsTableLock(nd)` (a live writer holds `coldfront_iceberg:<table>` from `WaitAcks` through `DrainDelete`, because the release runs in the COMMIT callback before PostgreSQL drops the xact lock); and a `Poker` process models the waiter's periodic no-op UPDATE of its own claim row, which re-runs the peer's defer branch and is what unwedges a waiter whose peer's holder died after deferring to it. Constant `NodeRetries` restricts the `Crasher` to writers whose node still has an unstarted writer (the node is touched again); FALSE allows the crash after which only the poke reaches the node. The `Crasher` cannot split `Release`/`DrainForward`/`DrainDelete`, which are one loopback transaction in the real code. |
| `Bakery.cfg` | This TLC config checks 3 writers with no crashes against all four safety invariants, in stock ordering (`AsyncParquet=FALSE`, the default, with parquet staged inside the claim). The config passes: the bakery makes `NoLakekeeperConflict` and `TicketOrderPreserved` hold even with realistic asymmetric apply. |
| `Bakery_async.cfg` | This config checks the patched async ordering (`AsyncParquet=TRUE, RestampPatch=TRUE`) that the DuckDB 1.5.x (duckdb15) image runs: parquet is staged outside the claim, and the bakery-aware patch re-stamps `parent_snapshot_id` at the commit POST under the claim. All four safety invariants HOLD; the test is non-vacuous, because it shares the stock config's under-claim window from `Prepare` to `Decide`, which R-A keeps empty. |
| `Bakery_race.cfg` | This config checks the pre-patch async race (`AsyncParquet=TRUE, RestampPatch=FALSE`): async ordering WITHOUT the bakery-aware patch, where the stale tentative parent from the pre-claim stage is used at the POST. `NoLakekeeperConflict` is EXPECTED to be violated, which is the formal proof that the patch is mandatory for the async ordering. |
| `Bakery_crash.cfg` | This config checks 3 writers with a budget of 1 crash, in stock ordering (crash safety is ordering-independent). The safety invariants still hold, and survivors proceed, because the dead-peer escape treats a crashed node as already acked. This config checks safety only; stranding under a crash appears only with same-node writers (`Bakery_wedge.cfg`). |
| `Bakery_live.cfg` | This config checks the defer/drain race (`SafeAcks=FALSE`), the non-atomic implementation. `EventualProgress` is EXPECTED to be VIOLATED: a deferred ack written behind a just-released claim is dropped, stranding the min-ticket holder at `WaitAcks` forever, which is the N-writer wedge this race produces. The four safety invariants still HOLD (a dropped ack is a liveness failure, not a wrong commit). The config declares no `SYMMETRY`, because symmetry reduction is unsound with liveness checking. |
| `Bakery_fixed.cfg` | This config checks the fix (`SafeAcks=TRUE`), the atomic defer/drain (`FOR UPDATE` on the claim row). `EventualProgress` HOLDS *and* all four safety invariants hold, which is the formal proof that the fix restores liveness without weakening safety. |
| `Bakery_samenode_race.cfg` | This config checks multiple cold writers per node with no same-node lock (`NodeParts={{a1,a2},{b1}}`, `SameNodeLock=FALSE`). Two same-node claims `a1<a2` below a peer's `b1`: the node defers `b1` behind its smallest same-node claim `a1` and, on `a1`'s release, forwards the ack for `b1` without re-deferring behind `a2` (still held, still `< b1`), so `a2` and `b1` both clear the bakery. `NoLakekeeperConflict` is EXPECTED to be violated, which reproduces the multi-writer-per-node race in the model. |
| `Bakery_samenode.cfg` | This config checks the fix (`SameNodeLock=TRUE`): `coldfront._claim_iceberg_lock`'s node-local advisory xact lock, so at most one same-node writer is in the bakery at a time. `a1` and `a2` never coexist; the topology collapses to one active claim per node and all four safety invariants HOLD, which is the formal proof that the node-local lock is mandatory for multi-writer-per-node cold writes. |
| `Bakery_wedge.cfg` | This config checks the orphan-claim wedge with the reaper OFF (`Reaper=FALSE`, `NodeParts={{a1,a2},{b1}}`, 1 crash). A same-node writer crashes holding its claim; its row stays in `coldfront.claims` with no owner. `SurvivorProgress` is EXPECTED to be violated: the surviving writer never decides. Safety still holds. This is the first config to check liveness under crash at all; `Bakery_crash.cfg` checks only safety. |
| `Bakery_reaper.cfg` | This config checks the reaper ON (`Reaper=TRUE`, `NodeRetries=TRUE`) in the same topology. Three paths reap ownerless same-node claims: the claim path under the table lock, the apply path on its defer branch when the lock is free, and the waiter's poke. `SurvivorProgress` HOLDS *and* all four safety invariants hold: the reap never breaks mutual exclusion. |
| `Bakery_reaper_quiet.cfg` | This config checks the poke's case (`Reaper=TRUE`, `NodeRetries=FALSE`): the crash strands a claim on a node no local writer or new peer claim ever reaches again, while a peer that already deferred behind it waits. Only the waiter's poke reaches that node. `SurvivorProgress` HOLDS and safety holds. |
| `Bakery_adopt_race.cfg` | This config checks table registration OUTSIDE the bakery (`AdoptClaims=FALSE`, one writer per node on two nodes). `_adopt_preflight` reads only the calling node's `coldfront.tiered_views`, so while the peer's row is in flight both preflights pass and both nodes INSERT. `NoDoubleRegistration` is EXPECTED to be violated. On a mesh the rows then replicate into each other and the second violates `UNIQUE (iceberg_table)` inside the apply worker, where no status field reports it. |
| `Bakery_adopt.cfg` | This config checks registration UNDER the claim (`AdoptClaims=TRUE`) in the same topology. The second node cannot reach its preflight until the first releases, and the release runs in the COMMIT callback, after the registry row is committed and ahead of the drained ack that frees the waiter. `NoDoubleRegistration` HOLDS *and* the four safety invariants hold: adding a claimant costs nothing the bakery already guarantees. |

## Properties

This section lists the safety and liveness properties the model checks, grouped
by category.

### Safety

These properties must hold; TLC checks them as `INVARIANTS`:

- `NoLakekeeperConflict` states that no writer's `decision` ends in `lk_409`.
  Equivalently, while a writer holds the bakery's minimum ticket, no other
  writer can issue a conditional commit POST to Lakekeeper against the same
  iceberg table. This is the headline correctness claim: without the bakery it
  fails, and the losing commit gets HTTP 409 and aborts its transaction.
- `RollbackNoIceberg` states that if a writer's `decision = "rolled_back"`,
  there is no iceberg snapshot owned by that writer in the committed history.
  The property models PG `ROLLBACK` undoing pg_duckdb's pending iceberg
  MetaTransaction.
- `UniqueTickets` states that snowflake.nextval() does not return duplicates.
  The property is a sanity check on the model abstraction.
- `TicketOrderPreserved` states that committed snapshots are appended in the
  order their owners' tickets were granted. The bakery's min-ticket gate
  ensures this structurally; the model encodes it as an invariant for
  documentation.
- `NoDoubleRegistration` states that at most one node registers a given Iceberg
  table. `Bakery_adopt.cfg` and `Bakery_adopt_race.cfg` check it.

### Liveness

TLC checks these properties as `PROPERTIES`:

- `EventualProgress` states that every writer that begins a claim eventually
  reaches a terminal `decision` (`committed`, `rolled_back`, or `lk_409`). The
  property holds when no crashes occur, and vacuously fails for writers that
  themselves crash mid-bakery (they can never decide). `EventualProgress` is
  also the defer/drain race check: `Bakery_fixed.cfg` (`SafeAcks=TRUE`) HOLDS
  it; `Bakery_live.cfg` (`SafeAcks=FALSE`) VIOLATES it - the dropped-ack wedge
  that strands the min-ticket holder at `WaitAcks` forever.
- `SurvivorProgress` states that every writer eventually decides *or crashes*.
  `EventualProgress` is unusable with `MaxCrashes > 0`, since a crashed writer
  never decides; this is the form a crash config can check. `Bakery_wedge.cfg`
  (`Reaper=FALSE`) VIOLATES `SurvivorProgress`, the surviving same-node writer
  waiting forever on a claim nobody owns; `Bakery_reaper.cfg` (`Reaper=TRUE`,
  `NodeRetries=TRUE`) and `Bakery_reaper_quiet.cfg` (`NodeRetries=FALSE`, only
  the poke reaches the crashed node) both HOLD it.

## Running TLC

The prerequisites are Java 11+ and the TLA+ tools 1.8.0 jar at
`/tmp/tla2tools.jar` (download from
<https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar>).
Translate the PlusCal source and run each config as follows:

```sh
TLA=/tmp/tla2tools.jar
cd docs/formal

# Translate the PlusCal source (idempotent).
java -cp $TLA pcal.trans Bakery.tla

# a. This run checks stock ordering (AsyncParquet=FALSE) with 3 writers and no
#       crashes.  All hold.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery.cfg Bakery.tla

# b. This run checks the patched async ordering (the duckdb15 image's path).
#       All hold.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_async.cfg Bakery.tla

# c. This run checks the pre-patch async race.  EXPECTED FAILURE:
#       NoLakekeeperConflict is violated, which is the formal proof that the
#       bakery-aware patch is mandatory for the async path.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_race.cfg Bakery.tla

# d. This run has a budget of 1 crash.  Safety still holds; survivors proceed,
#       because a crashed node counts as already acked.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_crash.cfg Bakery.tla

# e. This run checks the defer/drain race (SafeAcks=FALSE).  EXPECTED FAILURE:
#       EventualProgress is violated, which reproduces the dropped-ack wedge in
#       the model.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_live.cfg Bakery.tla

# f. This run checks the fix (SafeAcks=TRUE, FOR UPDATE on the claim row).
#       All hold: EventualProgress AND the four safety invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_fixed.cfg Bakery.tla

# g. This run checks multiple cold writers per node with NO same-node lock
#      (SameNodeLock=FALSE).  It is EXPECTED to violate NoLakekeeperConflict,
#      which reproduces the multi-writer-per-node race.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_samenode_race.cfg Bakery.tla

# h. This run checks the same topology WITH the node-local advisory lock
#      (SameNodeLock=TRUE).  All four safety invariants HOLD - the lock
#      restores safety.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_samenode.cfg Bakery.tla

# i. This run checks the orphan-claim wedge with the reaper OFF (Reaper=FALSE,
#      1 crash).  EXPECTED FAILURE: SurvivorProgress is violated, because a
#      crashed same-node claim holder strands the survivor.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_wedge.cfg Bakery.tla

# j. The reaper ON (Reaper=TRUE, NodeRetries=TRUE): the crashed node is touched
#      again.  All hold: SurvivorProgress AND the four safety invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_reaper.cfg Bakery.tla

# k. The poke's case (Reaper=TRUE, NodeRetries=FALSE): no local writer or new
#      peer claim ever reaches the crashed node; only the waiter's poke does.
#      All hold: SurvivorProgress AND the four safety invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_reaper_quiet.cfg Bakery.tla

# l. Table registration OUTSIDE the bakery (AdoptClaims=FALSE): two nodes adopt
#      one Iceberg table, and both preflights pass inside the replication
#      window.
#      EXPECTED: NoDoubleRegistration is VIOLATED.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_adopt_race.cfg Bakery.tla

# m. This run checks registration UNDER the claim (AdoptClaims=TRUE) in the
#      same topology.  All hold: NoDoubleRegistration AND the four safety
#      invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_adopt.cfg Bakery.tla
```

The `-deadlock` flag tells TLC not to flag final stuttering states as errors.
Without crashes the model terminates cleanly when every writer reaches `Done`.
With a crash in a same-node config and the reaper off (`Bakery_wedge.cfg`), a
surviving writer can wait forever on the orphan claim. TLC must report this as
a `SurvivorProgress` violation, not as `Deadlock reached`.

## Expected Outputs

This section records the expected TLC result for each config, so a reviewer can
confirm a run matches the known-good output. The counts come from TLC 1.8.0. A
config that passes explores every state, so its counts are the same with any
`-workers` value. A config that fails stops at the first violation, so its
counts depend on worker scheduling; the counts shown for those were taken with
`-workers 1`, which reproduces them exactly.

### `Bakery.cfg` (Stock Ordering)

The stock-ordering config reports a clean check with the following output:

```text
Model checking completed. No error has been found.
116332 states generated, 38570 distinct states found, 0 states left on queue.
```

All four safety invariants hold for the stock ordering (parquet staged inside
the claim; parent stamped under the claim). The bakery makes
`NoLakekeeperConflict` and `TicketOrderPreserved` hold despite asymmetric Spock
apply.

### `Bakery_async.cfg` (Patched Async Ordering)

The patched-async config reports a clean check with the following output:

```text
Model checking completed. No error has been found.
339258 states generated, 113262 distinct states found, 0 states left on queue.
```

The patched async ordering - parquet staged OUTSIDE the claim, parent
re-stamped at the commit POST UNDER the claim - is safe: all four invariants
hold. The check is non-vacuous: it shares the stock config's under-claim
`Prepare → Decide` window, which R-A keeps empty (a peer with a smaller
ticket defers its ack until it releases, so two writers never both clear
`WaitAcks`). This is the ordering the DuckDB 1.5.x (duckdb15) image runs.

### `Bakery_race.cfg` (Pre-Patch Async - EXPECTED FAILURE)

The pre-patch async config is expected to fail the check, reporting the
following output:

```text
Error: Invariant NoLakekeeperConflict is violated.
…
26659 states generated, 9430 distinct states found, 2073 states left on queue.
```

The failure is expected. With the async ordering but WITHOUT the bakery-aware
patch (`RestampPatch=FALSE`), a writer asserts the conditional commit against
the stale tentative parent it captured at the pre-claim stage; a peer that
committed while it awaited/held the claim has advanced the iceberg head, so the
conditional commit fails because its parent is stale → Lakekeeper 409. This
is the formal proof that the patch is mandatory for the async ordering - the
stock ordering (`Bakery.cfg`) stamps the parent under the claim and needs no
patch. (The asymmetric-apply race that motivates R-A itself - two writers
passing a naive local min-check on stale views - is structurally prevented by
the R-A ack barrier in this model, so it has no standalone config.)

### `Bakery_samenode_race.cfg` (Multi-Writer-Per-Node - EXPECTED FAILURE)

The no-same-node-lock config is expected to fail the check, reporting the
following output:

```text
Error: Invariant NoLakekeeperConflict is violated.
…
134609 states generated, 43418 distinct states found, 4695 states left on queue.
```

The failure is expected. With two cold writers `a1 < a2` on one node and `b1`
on a peer (`NodeParts={{a1,a2},{b1}}`, `SameNodeLock=FALSE`), the node defers
`b1` behind its smallest same-node claim `a1`; when `a1` releases, it forwards
the ack for `b1` without re-deferring behind `a2` (still held, still `< b1`).
So `a2` (already acked by the peer, since `a2 < b1`) and `b1` (now acked) both
clear the bakery and race their conditional commits → Lakekeeper 409. This
reproduces the multi-writer-per-node race in the model, isolated from the async
race (`AsyncParquet=FALSE`) and the ack-atomicity race (`SafeAcks=TRUE`).

### `Bakery_samenode.cfg` (Node-Local Lock)

The same-node-lock config reports a clean check with the following output:

```text
Model checking completed. No error has been found.
174206 states generated, 59106 distinct states found, 0 states left on queue.
```

`SameNodeLock=TRUE` models `coldfront._claim_iceberg_lock`'s node-local
advisory xact lock: at most one same-node writer is in the bakery at a time.
`a1` and `a2` never coexist, so the ack-forward never clears `b1` while `a2`
still holds; the topology collapses to one active claim per node and all four
safety invariants hold. This is the formal proof that the node-local lock is
mandatory for multi-writer-per-node cold writes.

## Model Fidelity

The model is a *protocol-level* abstraction. The following are represented
faithfully because they affect protocol correctness:

- The `coldfront.iceberg_async_parquet` flag's two mesh orderings in
  [_exec_iceberg_with_claim](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--1.0.sql):
  stock (claim → stage+commit under the claim) and patched async (stage
  parquet outside the claim → claim → re-stamp `parent_snapshot_id` at the
  commit POST under the claim). The safety-critical invariant - the parent
  snapshot the conditional commit checks is taken UNDER the held claim - is
  captured at `Prepare` for both; the `AsyncParquet`/`RestampPatch` constants
  select the ordering and whether the bakery-aware patch is present. In the
  code, `coldfront._iceberg_async_active()` selects the async ordering only
  when the build marker `coldfront.iceberg_bakery_patch` is also on. With the
  flag alone, the writer keeps the stock ordering and logs the downgrade once
  per session, so the `Bakery_race.cfg` combination runs only where the marker
  is set on a stock binary.
- The bakery's min-ticket spin in
  [_claim_iceberg_lock](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--1.0.sql).
- The deferred release, in which pg_duckdb commits the Iceberg transaction at
  `XACT_EVENT_PRE_COMMIT` and coldfront's XactCallback `DELETE`s the claim at
  `XACT_EVENT_COMMIT`, so the commit always precedes the release whatever order
  the two callbacks were registered in. The model represents this as the
  iceberg append at `Decide` followed by the claim `DELETE` at `Release`.
- pg_duckdb's iceberg `ROLLBACK` on PG ABORT (no append on the rollback
  branch), which the `RollbackNoIceberg` property requires.

### Compactor Commits (`cmd/compactor`)

The Go compactor (`cmd/compactor`, apache/iceberg-go) is a bakery claimant
**indistinguishable from a cold writer at the protocol level**: it acquires a
claim via `_claim_iceberg_lock` on the node it connects to, captures the parent
snapshot under the held claim, issues one conditional commit POST to
Lakekeeper - a *replace* (`RewriteDataFiles`: drop small data files, add the
rewritten one), which has the same parent-snapshot conflict shape as the append
modeled at `Decide` - then releases. The compactor adds no new protocol
primitive, so it is covered by the existing proof as the **stock-ordering
writer** (`AsyncParquet = FALSE`, `Bakery.cfg`). The compactor's two
maintenance operations are the **same claimant**, so they need no new model:
**`ExpireSnapshots`** issues another conditional commit (drop old snapshots -
identical conflict shape) under the held claim, covered exactly like
`RewriteDataFiles`; **`DeleteOrphanFiles`** holds the claim but makes **no
Lakekeeper commit** (it only deletes unreferenced files), so it cannot cause a
catalog conflict at all - strictly weaker than a committing claimant, hence
trivially within `NoLakekeeperConflict`. All three reuse the existing
`coldfront._claim_iceberg_external` and are covered by the existing model and
configs; no dedicated config is needed. (Lakekeeper itself does no Iceberg
snapshot/orphan maintenance - it is a catalog - so this is the go-native path.)

Binding constraint: iceberg-go has **no bakery-aware re-stamp patch** (that
patch lives only in the duckdb-iceberg commit path), so the compactor MUST hold
the claim across the whole read → rewrite → commit and stamp, under the
claim, the parent snapshot that the conditional commit checks.
`Bakery_race.cfg` is the proof that the patchless-async shortcut fails with
HTTP 409 - the compactor is therefore forbidden the async-parquet path.
Commit-then-release matches the cold-write shape the model already abstracts as
the atomic `Decide` step (commit iceberg, then `DELETE` the claim), so the
existing configs cover it; no dedicated config is needed.

### DDL Mirroring (`ALTER TABLE`)

Tiered-table column DDL (ADD/`DROP`/`ALTER`-TYPE/`RENAME COLUMN`) is mirrored
onto the shared Iceberg tier by `coldfront._mirror_iceberg_alter`, which routes
the Iceberg `ALTER` through the **unchanged** `_exec_iceberg_with_claim`. The
mirror function is therefore the **same stock-ordering claimant** the cold
writer is: one metadata-only conditional commit (the schema change - identical
parent-snapshot conflict shape to the append modeled at `Decide`) under the
held claim, then release. The mirror function forces the claim-first ordering
(`SET LOCAL coldfront.iceberg_async_parquet = off`): an `ALTER` stages no
parquet, so there is nothing to overlap, and `AsyncParquet = FALSE`
(`Bakery.cfg`) is the config the model already proves safe. The mirror adds no
new protocol primitive, so it is covered by the existing model and configs; no
dedicated config is needed.

In a mesh the user's `ALTER` replicates as a top-level statement and re-runs in
each peer's apply worker; the mirror self-skips there
(`session_replication_role = replica`) because the SHARED catalog was already
evolved by the originator. The single-commit shape thus holds - the catalog is
altered exactly once, by one claimant - and peers only rebuild their per-node
view.

### Cross-Tier Move (Partition-Column `UPDATE`)

A partition-column `UPDATE` that crosses the cutoff is rewritten to
`coldfront._cross_tier_move`, which relocates rows between tiers. Its hot-tier
work is plain PostgreSQL (heap `INSERT`/`UPDATE`/`DELETE` - no Iceberg, no
claim). Its cold-tier work is **one** `duckdb.raw_query` issued through the
**unchanged** path: a single `DELETE`-set plus `INSERT`-set in one DuckDB
MetaTransaction - one Iceberg snapshot, one conditional commit POST to
Lakekeeper - under **one** `_claim_iceberg_lock` held to transaction end
(released by the C `XactCallback`). The move is therefore the **same
stock-ordering single claimant** the cold writer is: one conditional commit
(identical parent-snapshot conflict shape to the append modeled at `Decide`)
under the held claim. The move forces `iceberg_async_parquet = off`
(`AsyncParquet = FALSE`, `Bakery.cfg`) - the `DELETE`+`INSERT` bundle is not
pg_duckdb's single deferred POST that the async re-stamp patch wraps. Each move
takes exactly **one** claim (a second claim on the same table would reap the
first, which `_take_iceberg_claim` prevents by reusing the transaction's
claim), so the move never holds two tickets. The move adds no new protocol
primitive, so it is covered by the existing model and configs; no dedicated
config is needed.

### Partition Detach Fan-Out

The retention path detaches expired partitions with
`DETACH PARTITION … CONCURRENTLY`, which Spock cannot replicate (it is
non-transactional), so the partition manager re-runs the same concurrent detach
on each peer itself, over its own connection to each Spock node (gated on Spock
being present; a no-op on a vanilla single node). This is **outside the modeled
protocol entirely**: it touches no Iceberg catalog, takes no claim, and POSTs
nothing to Lakekeeper - it is pure PostgreSQL partition maintenance on the hot
tier. The fan-out adds no claimant, no conditional commit, and no new ordering,
so it falls outside `Bakery`'s scope; no dedicated config is needed. (The
archiver's cold cutover *does* commit to Iceberg under a claim, but its detach
is a plain transactional `DETACH` that Spock replicates on its own - it is the
already-modeled stock-ordering writer, not a new primitive.)

### Known Abstractions (Model Deviates from Reality)

These are the points where the model deliberately deviates from runtime
reality:

- The model has no `lk_409` residual: `NoLakekeeperConflict` holds because the
  R-A ack barrier keeps the under-claim window empty. No application-level
  409-retry exists or is needed: concurrent cold writers never receive a
  Lakekeeper 409.

The following are *abstracted away* because they do not affect protocol
correctness:

- The Lakekeeper REST API and Iceberg snapshot serialization, which the model
  represents as an atomic conditional update of a sequence head.
- pg_duckdb internals (the transaction-event order is a *premise*: pg_duckdb
  commits at PRE_COMMIT, before coldfront's release at COMMIT).
- The reply cadence behind the wait loop's dead-peer check. `NodeLive` is
  exact in the model; the code rules a peer dead when its walsender's
  `reply_time` is older than `coldfront.peer_alive_window_ms`, and that reply
  is the apply worker's feedback: after applying, every
  `spock.feedback_frequency` messages, and in answer to the walsender's
  keepalive, every `wal_sender_timeout/2` on an idle link. The claim refuses
  to run unless `wal_sender_timeout` is positive and below twice the window,
  which keeps an idle live peer alive in the code's test as it is in the
  model's; a peer silent for longer than the window for any other reason (a
  lock wait inside its apply worker, a partition) is ruled dead, the residual
  the model states as the failure-detector clause.
- DuckDB's pglocal connection-keepalive behavior. The bakery does not use
  pglocal; the archiver's Phase 3 does, but Phase 3 is a separate code path
  with its own CI test (the race-window regression in `ci/journey.sh` story 9).
- Async-replicated user-data tables (Spock's data path for non-bakery commits),
  which do not interact with the bakery state.

If any of these abstractions is questioned in code review, the model must be
re-examined to ensure it still represents the runtime faithfully - formal
models are only as useful as their fidelity.

## Bounds

`MaxTickets = 6, MaxIcebergLen = 5, |Writers| = 3` is the default bound
(`MaxCrashes` is 1 in the crash configs and 0 elsewhere; the same-node configs
use `MaxTickets = 3` with writers `{a1, a2, b1}`, and the adopt configs use
`MaxTickets = 2` and `MaxIcebergLen = 4` with writers `{a1, b1}`). Every config
checks in seconds on a modern laptop. `SYMMETRY` on `Writers` (up to a ~6×
reduction at 3 writers) is per-config: the liveness configs (`Bakery_live.cfg`,
`Bakery_fixed.cfg`) run without it (symmetry reduction is unsound with liveness
checking), and the same-node configs run without it (`a1`/`a2`/`b1` are not
interchangeable under `NodeParts`), and so do the two adopt configs; the other
configs declare it.

The model is small enough that larger bounds are interesting only if a
regression is suspected.

## When to Re-Run

Re-run the model after any change to the following:

- The bakery functions in `extension/coldfront/coldfront--1.0.sql`
  (`_claim_iceberg_lock`, `_insert_claim`, `_take_iceberg_claim`,
  `_exec_iceberg_with_claim`, `_enqueue_release`, `_on_claim_apply`,
  `_on_claim_release`, `ensure_replicated`).
- The `_exec_iceberg_with_claim` ordering or the
  `coldfront.iceberg_async_parquet` flag's meaning (which parquet-stage point /
  where `parent_snapshot_id` is stamped relative to the claim), which means
  re-checking `Bakery.cfg` (stock) AND `Bakery_async.cfg` (patched).
- The C-level XactCallback in `extension/coldfront/src/coldfront.c`
  (`coldfront_xact_callback`, `RegisterXactCallback` ordering).
- The `cmd/compactor` bakery wrapper, meaning the claim/release that brackets
  its iceberg-go `RewriteDataFiles` commit (the wrapper must stay
  stock-ordering: claim held across read → rewrite → commit; no
  async-parquet shortcut).

If the protocol-level shape changes (e.g. swapping the bakery for a different
coordination primitive), update the PlusCal source first, re-translate,
re-check. CI integration is a future task; for now, running the configs by hand
is the workflow.

## Future Work

The following extensions to the model and its tooling are planned:

- Add an async-replicated `user_table` to formally show the bakery is
  independent of Spock data-path lag.
- Wire into CI on touches to `extension/coldfront/`. The `tla2tools.jar` is ~5
  MB; either check it in or download in a CI step. TLC runs in <2s for the
  current bounds.
