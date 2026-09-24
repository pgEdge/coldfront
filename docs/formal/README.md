# Formal model - coldfront decoupled-mode bakery (TLA+/PlusCal)

This directory contains a formal model of the multi-writer Iceberg
commit serialization protocol that lives in
[extension/coldfront/coldfront--1.0.sql](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--1.0.sql)
and
[extension/coldfront/src/coldfront.c](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/src/coldfront.c).
The CI journey (`ci/journey.sh` - `story_mesh` /
`story_decoupled_concurrency` / `story_mesh_substrate`, driven by
`ci/matrix.sh`) tests the protocol against a fixed mesh shape - three
docker containers, single iceberg table, well-paced workload. The model
exhaustively explores **every interleaving** of N writers within
bounded depth, including failure injections that the CI can't easily
reproduce.

## Files

This section catalogs the model files and the role each one plays.
The model gives each node its own local view of the claims and
propagates inserts through an explicit applier. The following table
describes its files and their roles:

| File | Role |
|---|---|
| `Bakery.tla` | PlusCal source.  Models the real spock world: each node has its OWN local `claims[nd]` view, INSERTs propagate via an explicit `Applier`.  No `synchronous_commit = remote_apply`.  Coordination is Lamport's 1978 distributed mutual exclusion algorithm with Ricart-Agrawala's (1981) deferred-reply optimisation: peers ack each claim immediately unless they have a pending claim with smaller ticket, in which case they defer the ack until they release their own claim.  Also models the `coldfront.iceberg_async_parquet` flag (constants `AsyncParquet`/`RestampPatch`): the `Stage` label stages parquet OUTSIDE the claim (async ordering); `Prepare` captures the `parent_snapshot_id` UNDER the claim (stock at stage time, patched async re-stamped at the commit POST); the `Decide` CAS asserts against it.  **Defer/drain atomicity** is modelled too (constant `SafeAcks`): the apply-time defer DECISION and its WRITE (`ApplyDecide`/`ApplyEmit`), and the release drain's FORWARD and DELETE (`DrainForward`/`DrainDelete`), are SEPARATE steps — faithful to the non-atomic SQL.  `SafeAcks=FALSE` lets them race (a deferral written behind a just-released claim is deleted unforwarded / orphaned — a dropped ack); `SafeAcks=TRUE` is the safe implementation: an atomic re-check of R-A's own defer rule against the claim, i.e. `SELECT … FOR UPDATE` on the claim row in `coldfront._on_claim_apply`.  **The orphan reaper** (constant `Reaper`): a same-node claim whose writer has crashed holds no advisory lock, so `BeginClaim` deletes it in the step that inserts its own claim; the `Applier` does the same on its defer branch under `HoldsTableLock(nd)` (a live writer holds `coldfront_iceberg:<table>` from `WaitAcks` through `DrainDelete`, because the release runs in the COMMIT callback before PostgreSQL drops the xact lock); and a `Poker` process models the waiter's periodic no-op UPDATE of its own claim row, which re-runs the peer's defer branch and is what unwedges a waiter whose peer's holder died after deferring to it. Constant `NodeRetries` restricts the `Crasher` to writers whose node still has an unstarted writer (the node is touched again); FALSE allows the crash after which only the poke reaches the node. The `Crasher` cannot split `Release`/`DrainForward`/`DrainDelete`, which are one loopback transaction in the real code. |
| `Bakery.cfg` | TLC config: 3 writers, no crashes, all four safety invariants. **Stock ordering** (`AsyncParquet=FALSE` - the default; parquet staged inside the claim).  Passes - R-A makes `NoLakekeeperConflict` and `TicketOrderPreserved` hold even with realistic asymmetric apply. |
| `Bakery_async.cfg` | **Patched async ordering** (`AsyncParquet=TRUE, RestampPatch=TRUE`) - what the DuckDB 1.5.x (duckdb15) image runs: parquet staged outside the claim, `parent_snapshot_id` re-stamped at the commit POST under the claim by the bakery-aware patch.  All four safety invariants HOLD; the test is non-vacuous (shares the stock config's under-claim `Prepare→Decide` window, which R-A keeps empty). |
| `Bakery_race.cfg` | **Pre-patch async race** (`AsyncParquet=TRUE, RestampPatch=FALSE`) - async ordering WITHOUT the bakery-aware patch: the stale tentative parent from the pre-claim stage is used at the POST. **`NoLakekeeperConflict` is EXPECTED to be violated** - the formal proof that the patch is mandatory for the async ordering. |
| `Bakery_crash.cfg` | 3 writers, 1 crash budget (stock ordering - crash-safety is ordering-independent).  Safety invariants still hold (a crashed peer's missing ack just leaves surviving writers blocked at `WaitAcks` - no incorrect commits). |
| `Bakery_live.cfg` | **The defer/drain race** (`SafeAcks=FALSE`) - the non-atomic implementation. **`EventualProgress` is EXPECTED to be VIOLATED**: a deferred ack written behind a just-released claim is dropped, stranding the min-ticket holder at `WaitAcks` forever - the N-writer wedge this race produces. The four safety invariants still HOLD (a dropped ack is a liveness failure, not a wrong commit). No `SYMMETRY` (unsound with liveness checking). |
| `Bakery_fixed.cfg` | **The fix** (`SafeAcks=TRUE`) - the atomic defer/drain (`FOR UPDATE` on the claim row). `EventualProgress` HOLDS *and* all four safety invariants hold: the formal proof the fix restores liveness without weakening safety. |
| `Bakery_samenode_race.cfg` | **Multiple cold writers per node, no same-node lock** (`NodeParts={{a1,a2},{b1}}`, `SameNodeLock=FALSE`). Two same-node claims `a1<a2` below a peer's `b1`: the node defers `b1` behind its smallest same-node claim `a1` and, on `a1`'s release, forwards the ack for `b1` without re-deferring behind `a2` (still held, still `< b1`), so `a2` and `b1` both clear the bakery. **`NoLakekeeperConflict` is EXPECTED to be violated** - the multi-writer-per-node race, reproduced in the model. |
| `Bakery_samenode.cfg` | **The fix** (`SameNodeLock=TRUE`) - `coldfront._claim_iceberg_lock`'s node-local advisory xact lock, so at most one same-node writer is in the bakery at a time. `a1` and `a2` never coexist; the topology collapses to one active claim per node and all four safety invariants HOLD: the formal proof the node-local lock is mandatory for multi-writer-per-node cold writes. |
| `Bakery_wedge.cfg` | **The orphan-claim wedge, reaper OFF** (`Reaper=FALSE`, `NodeParts={{a1,a2},{b1}}`, 1 crash). A same-node writer crashes holding its claim; its row stays in `coldfront.claims` with no owner. **`SurvivorProgress` is EXPECTED to be violated**: the surviving writer never decides. Safety still holds. The first config to check liveness under crash at all; `Bakery_crash.cfg` checks only safety. |
| `Bakery_reaper.cfg` | **The reaper ON** (`Reaper=TRUE`, `NodeRetries=TRUE`), same topology. Three paths reap ownerless same-node claims: the claim path under the table lock, the apply path on its defer branch when the lock is free, and the waiter's poke. `SurvivorProgress` HOLDS *and* all four safety invariants hold: the reap never breaks mutual exclusion. |
| `Bakery_reaper_quiet.cfg` | **The poke's case** (`Reaper=TRUE`, `NodeRetries=FALSE`): the crash strands a claim on a node no local writer or new peer claim ever reaches again, while a peer that already deferred behind it waits. Only the waiter's poke reaches that node. `SurvivorProgress` HOLDS and safety holds. |
| `Bakery_adopt_race.cfg` | **Table registration OUTSIDE the bakery** (`AdoptClaims=FALSE`, one writer per node on two nodes). `_adopt_preflight` reads only the calling node's `coldfront.tiered_views`, so while the peer's row is in flight both preflights pass and both nodes INSERT. **`NoDoubleRegistration` is EXPECTED to be violated.** On a mesh the rows then replicate into each other and the second violates `UNIQUE (iceberg_table)` inside the apply worker, where no status field reports it. |
| `Bakery_adopt.cfg` | **Registration UNDER the claim** (`AdoptClaims=TRUE`), same topology. The second node cannot reach its preflight until the first releases, and the release runs in the COMMIT callback, after the registry row is committed and ahead of the drained ack that frees the waiter. `NoDoubleRegistration` HOLDS *and* the four safety invariants hold: adding a claimant costs nothing the bakery already guarantees. |

## Properties

This section lists the safety and liveness properties the model
checks, grouped by category.

### Safety

These properties must hold; TLC checks them as `INVARIANTS`:

- `NoLakekeeperConflict` - no writer's `decision` ends in `lk_409`.
  Equivalently: while a writer holds the bakery's minimum ticket,
  no other writer can issue a Lakekeeper CAS POST against the same
  iceberg table. This is the headline correctness claim - pre-bakery
  this could fail and produce silent commit loss.
- `RollbackNoIceberg` - if a writer's `decision = "rolled_back"`,
  there is no iceberg snapshot owned by that writer in the
  committed history. Models PG ROLLBACK undoing pg_duckdb's pending
  iceberg MetaTransaction.
- `UniqueTickets` - snowflake.nextval() doesn't return duplicates.
  Sanity check on the model abstraction.
- `TicketOrderPreserved` - committed snapshots are appended in the
  order their owners' tickets were granted. Ensured structurally by
  the bakery's min-ticket gate; encoded as an invariant for
  documentation.

### Liveness

TLC checks these properties as `PROPERTIES`:

- `EventualProgress` - every writer that begins a claim eventually
  reaches a terminal `decision` (`committed`, `rolled_back`, or
  `lk_409`). Holds when no crashes; vacuously fails for writers that
  themselves crash mid-bakery (they can never decide). It is also the
  defer/drain race check: `Bakery_fixed.cfg`
  (`SafeAcks=TRUE`) HOLDS it; `Bakery_live.cfg` (`SafeAcks=FALSE`)
  VIOLATES it - the dropped-ack wedge that strands the min-ticket
  holder at `WaitAcks` forever.
- `SurvivorProgress` - every writer eventually decides *or crashes*.
  `EventualProgress` is unusable with `MaxCrashes > 0`, since a crashed
  writer never decides; this is the form a crash config can check.
  `Bakery_wedge.cfg` (`Reaper=FALSE`) VIOLATES it, the surviving
  same-node writer waiting forever on a claim nobody owns;
  `Bakery_reaper.cfg` (`Reaper=TRUE`, `NodeRetries=TRUE`) and
  `Bakery_reaper_quiet.cfg` (`NodeRetries=FALSE`, only the poke reaches
  the crashed node) both HOLD it.

## Running TLC

Prereqs: Java 11+, TLA+ tools 1.8.0 jar at `/tmp/tla2tools.jar`
(download from
<https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar>).

```sh
TLA=/tmp/tla2tools.jar
cd docs/formal

# Translate the PlusCal source (idempotent).
java -cp $TLA pcal.trans Bakery.tla

# a. Stock ordering (AsyncParquet=FALSE): 3 writers, no crashes.  All hold.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery.cfg Bakery.tla

# b. Patched async ordering (the duckdb15 image's path).  All hold.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_async.cfg Bakery.tla

# c. Pre-patch async race.  EXPECTED FAILURE: NoLakekeeperConflict violated —
#       the formal proof the bakery-aware patch is mandatory for the async path.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_race.cfg Bakery.tla

# d. 1 crash budget.  Safety still holds (crashed peer's missing ack
#       leaves survivors blocked at WaitAcks — no incorrect commits).
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_crash.cfg Bakery.tla

# e. Defer/drain race (SafeAcks=FALSE).  EXPECTED FAILURE: EventualProgress
#       violated — the dropped-ack wedge reproduced in the model.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_live.cfg Bakery.tla

# f. The fix (SafeAcks=TRUE — FOR UPDATE on the claim row).  All hold:
#       EventualProgress AND the four safety invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_fixed.cfg Bakery.tla

# g. Multiple cold writers per node, NO same-node lock (SameNodeLock=FALSE).
#      EXPECTED to violate NoLakekeeperConflict — the multi-writer-per-node race.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_samenode_race.cfg Bakery.tla

# h. Same topology WITH the node-local advisory lock (SameNodeLock=TRUE).
#      All four safety invariants HOLD — the lock restores safety.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_samenode.cfg Bakery.tla

# i. Orphan-claim wedge, reaper OFF (Reaper=FALSE, 1 crash).  EXPECTED FAILURE:
#      SurvivorProgress violated: a crashed same-node claim holder strands the survivor.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_wedge.cfg Bakery.tla

# j. The reaper ON (Reaper=TRUE, NodeRetries=TRUE): the crashed node is touched
#      again.  All hold: SurvivorProgress AND the four safety invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_reaper.cfg Bakery.tla

# k. The poke's case (Reaper=TRUE, NodeRetries=FALSE): no local writer or new
#      peer claim ever reaches the crashed node; only the waiter's poke does.  All
#      hold: SurvivorProgress AND the four safety invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_reaper_quiet.cfg Bakery.tla

# l. Table registration OUTSIDE the bakery (AdoptClaims=FALSE): two nodes adopt
#      one Iceberg table and both preflights pass inside the replication window.
#      EXPECTED: NoDoubleRegistration VIOLATED.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_adopt_race.cfg Bakery.tla

# m. Registration UNDER the claim (AdoptClaims=TRUE), same topology.  All hold:
#      NoDoubleRegistration AND the four safety invariants.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_adopt.cfg Bakery.tla
```

The `-deadlock` flag tells TLC not to flag final stuttering states as
errors. Without crashes the model terminates cleanly when every
writer reaches `Done`; with a crash a live writer can be stuck in
`WaitAcks` forever waiting for the orphan ticket. We want TLC to
report this as a `EventualProgress` violation, not as `Deadlock
reached`.

## Expected outputs

This section records the expected TLC result for each config, so a
reviewer can confirm a run matches the known-good output.

### `Bakery.cfg` (stock ordering)

The stock-ordering config reports a clean check with the following
output:

```text
Model checking completed. No error has been found.
2442 states generated, 702 distinct states found, 0 states left on queue.
```

All four safety invariants hold for the stock ordering (parquet staged
inside the claim; parent stamped under the claim). R-A makes
`NoLakekeeperConflict` and `TicketOrderPreserved` hold despite
asymmetric Spock apply.

### `Bakery_async.cfg` (patched async ordering)

The patched-async config reports a clean check with the following
output:

```text
Model checking completed. No error has been found.
3361 states generated, 1084 distinct states found, 0 states left on queue.
```

The patched async ordering - parquet staged OUTSIDE the claim, parent
re-stamped at the commit POST UNDER the claim - is safe: all four
invariants hold. The check is non-vacuous: it shares the stock config's
under-claim `Prepare → Decide` window, which R-A keeps empty (a peer
with a smaller ticket defers its ack until it releases, so two writers
never both clear `WaitAcks`). This is the ordering the DuckDB 1.5.x
(duckdb15) image runs.

### `Bakery_race.cfg` (pre-patch async - EXPECTED FAILURE)

The pre-patch async config is expected to fail the check, reporting
the following output:

```text
Error: Invariant NoLakekeeperConflict is violated.
…
2898 states generated, 891 distinct states found, 44 states left on queue.
```

**Failure expected.** With the async ordering but WITHOUT the
bakery-aware patch (`RestampPatch=FALSE`), a writer asserts the CAS
against the stale tentative parent it captured at the pre-claim stage;
a peer that committed while it awaited/held the claim has advanced the
iceberg head, so the CAS mismatches → Lakekeeper 409. This is the
formal proof that the patch is mandatory for the async ordering - the
stock ordering (`Bakery.cfg`) stamps the parent under the claim and
needs no patch. (The asymmetric-apply race that motivates R-A itself -
two writers passing a naive local min-check on stale views - is
structurally prevented by the R-A ack barrier in this model, so it has
no standalone config.)

### `Bakery_samenode_race.cfg` (multi-writer-per-node - EXPECTED FAILURE)

The no-same-node-lock config is expected to fail the check, reporting
the following output:

```text
Error: Invariant NoLakekeeperConflict is violated.
…
62256 states generated, 20448 distinct states found, 2595 states left on queue.
```

**Failure expected.** With two cold writers `a1 < a2` on one node and
`b1` on a peer (`NodeParts={{a1,a2},{b1}}`, `SameNodeLock=FALSE`), the
node defers `b1` behind its smallest same-node claim `a1`; when `a1`
releases, it forwards the ack for `b1` without re-deferring behind `a2`
(still held, still `< b1`). So `a2` (already acked by the peer, since
`a2 < b1`) and `b1` (now acked) both clear the bakery and race the CAS →
Lakekeeper 409. This reproduces the multi-writer-per-node race in the
model, isolated from the async race (`AsyncParquet=FALSE`) and the
ack-atomicity race (`SafeAcks=TRUE`).

### `Bakery_samenode.cfg` (node-local lock)

The same-node-lock config reports a clean check with the following
output:

```text
Model checking completed. No error has been found.
71617 states generated, 24076 distinct states found, 0 states left on queue.
```

`SameNodeLock=TRUE` models `coldfront._claim_iceberg_lock`'s node-local
advisory xact lock: at most one same-node writer is in the bakery at a
time. `a1` and `a2` never coexist, so the ack-forward never clears `b1`
while `a2` still holds; the topology collapses to one active claim per
node and all four safety invariants hold. This is the formal proof that
the node-local lock is mandatory for multi-writer-per-node cold writes.

## Model fidelity

The model is a *protocol-level* abstraction. The following are
represented faithfully because they affect protocol correctness:

- The `coldfront.iceberg_async_parquet` flag's two mesh orderings in
  [_exec_iceberg_with_claim](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--1.0.sql):
  stock (claim → stage+commit under the claim) and patched async
  (stage parquet outside the claim → claim → re-stamp
  `parent_snapshot_id` at the commit POST under the claim). The
  safety-critical invariant - the CAS parent is taken UNDER the held
  claim - is captured at `Prepare` for both; the
  `AsyncParquet`/`RestampPatch` constants select the ordering and
  whether the bakery-aware patch is present.
- The bakery's min-ticket spin in
  [_claim_iceberg_lock](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--1.0.sql).
- The deferred release: pg_duckdb's XactCallback commits iceberg
  first, then coldfront's XactCallback (registered after, runs after
  per PG's documented registration-order chain) DELETEs the claim.
  Modelled as the iceberg append at `Decide` followed by the claim
  DELETE at `Release`.
- pg_duckdb's iceberg ROLLBACK on PG ABORT (no append on the
  rollback branch) - required for the `RollbackNoIceberg` property
  to hold.

### Compactor commits (`cmd/compactor`)

The Go compactor (`cmd/compactor`, apache/iceberg-go) is a bakery
claimant **indistinguishable from a cold writer at the protocol
level**: it acquires a claim via `_claim_iceberg_lock` on the node it
connects to, captures the parent snapshot under the held claim, issues
one Lakekeeper CAS POST - a *replace* (`RewriteDataFiles`: drop small
data files, add the rewritten one), which has the same parent-CAS
conflict shape as the append modelled at `Decide` - then releases. It
adds no new protocol primitive, so it is covered by the existing proof
as the **stock-ordering writer** (`AsyncParquet = FALSE`,
`Bakery.cfg`).

Its two maintenance operations are the **same claimant**, so they need
no new model: **`ExpireSnapshots`** issues another CAS commit (drop old
snapshots - identical conflict shape) under the held claim, covered
exactly like `RewriteDataFiles`; **`DeleteOrphanFiles`** holds the
claim but makes **no Lakekeeper commit** (it only deletes unreferenced
files), so it cannot cause a catalog conflict at all - strictly weaker
than a committing claimant, hence trivially within
`NoLakekeeperConflict`. All three reuse the existing
`coldfront._claim_iceberg_external` and are covered by the existing
model and configs; no dedicated config is needed. (Lakekeeper itself does no
Iceberg snapshot/orphan maintenance - it is a catalog - so this is the
go-native path.)

Binding constraint: iceberg-go carries **no bakery-aware re-stamp
patch** (that patch lives only in the duckdb-iceberg commit path), so
the compactor MUST hold the claim across the whole read → rewrite →
commit and stamp the CAS parent under the claim. `Bakery_race.cfg`
is the proof that the patchless-async shortcut 409s - the compactor is
therefore forbidden the async-parquet path. Commit-then-release matches
the cold-write shape the model already abstracts as the atomic `Decide`
step (commit iceberg, then DELETE the claim), so the existing configs
cover it; no dedicated config is needed.

### DDL mirroring (`ALTER TABLE`)

Tiered-table column DDL (ADD/DROP/ALTER-TYPE/RENAME COLUMN) is mirrored
onto the shared Iceberg tier by `coldfront._mirror_iceberg_alter`,
which routes the Iceberg ALTER through the **unchanged**
`_exec_iceberg_with_claim`. It is therefore the **same stock-ordering
claimant** the cold writer is: one metadata-only CAS commit (the schema
change - identical parent-CAS conflict shape to the append modelled at
`Decide`) under the held claim, then release. It forces the claim-first
ordering (`SET LOCAL coldfront.iceberg_async_parquet = off`): an ALTER
stages no parquet, so there is nothing to overlap, and `AsyncParquet =
FALSE` (`Bakery.cfg`) is the config the model already proves safe.
It adds no new protocol primitive, so it is covered by the existing
model and configs; no dedicated config is needed.

In a mesh the user's ALTER replicates as a top-level statement and
re-runs in each peer's apply worker; the mirror self-skips there
(`session_replication_role = replica`) because the SHARED catalog was
already evolved by the originator. The single-commit shape thus holds -
the catalog is altered exactly once, by one claimant - and peers only
rebuild their per-node view.

### Cross-tier move (partition-column UPDATE)

A partition-column `UPDATE` that crosses the cutoff is rewritten to
`coldfront._cross_tier_move`, which relocates rows between tiers.
Its hot-tier work is plain PostgreSQL (heap INSERT/UPDATE/DELETE - no
Iceberg, no claim). Its cold-tier work is **one** `duckdb.raw_query`
issued through the **unchanged** path: a single DELETE-set plus
INSERT-set in one DuckDB MetaTransaction - one Iceberg snapshot, one
Lakekeeper CAS POST - under **one** `_claim_iceberg_lock` held to
transaction end (released by the C `XactCallback`). It is therefore the
**same stock-ordering single claimant** the cold writer is: one CAS
commit (identical parent-CAS conflict shape to the append modelled at
`Decide`) under the held claim. It forces `iceberg_async_parquet = off`
(`AsyncParquet = FALSE`, `Bakery.cfg`) - the DELETE+INSERT bundle is
not pg_duckdb's single deferred POST that the async re-stamp patch wraps.
Exactly **one** claim per move (a second `_claim_iceberg_lock` on the
same table in one txn would self-deadlock at the min-ticket gate), so the
move never holds two tickets. It adds no new protocol primitive, so it
is covered by the existing model and configs; no dedicated config is
needed.

### Partition detach fan-out

The retention path detaches expired partitions with
`DETACH PARTITION … CONCURRENTLY`, which Spock cannot replicate (it is
non-transactional), so the partition manager re-runs the same concurrent
detach on each peer itself, over its own connection to each Spock node
(gated on Spock being present; a no-op on a vanilla single node). This is
**outside the modelled protocol entirely**: it touches no Iceberg catalog,
takes no claim, and
POSTs nothing to Lakekeeper - it is pure PostgreSQL partition
maintenance on the hot tier. It adds no claimant, no CAS commit, and no
new ordering, so it falls outside `Bakery`'s scope; no dedicated
config is needed.
(The archiver's cold cutover *does* commit to Iceberg under a claim,
but its detach is a plain transactional `DETACH` that Spock replicates
on its own - it is the already-modelled stock-ordering writer, not a
new primitive.)

### Known abstractions (model deviates from reality)

These are the points where the model deliberately deviates from
runtime reality:

- **No `lk_409` residual.** `NoLakekeeperConflict` holds because the
  R-A ack barrier keeps the under-claim window empty.
  No application-level 409-retry exists or is needed: concurrent
  cold writers never receive a Lakekeeper 409.

The following are *abstracted away* because they don't affect
protocol correctness:

- Lakekeeper REST API and Iceberg snapshot serialization. Modelled
  as an atomic CAS on a sequence head.
- pg_duckdb internals (its XactCallback registration ordering is a
  *premise* - coldfront loads after pg_duckdb in
  `shared_preload_libraries`).
- Spock walsender / heartbeat cadence (wal_sender_timeout/2 ≈ 30 s
  default keepalive cadence; reply_time freshness in the reap uses
  a 5 s threshold which works in active clusters but degrades to
  the keepalive cadence floor for idle-then-crashed peers).
- DuckDB's pglocal connection-keepalive behaviour. The bakery does
  not use pglocal; the archiver's Phase 3 does, but Phase 3 is a
  separate code path with its own CI test (the race-window
  regression in `ci/journey.sh` story 9).
- Async-replicated user-data tables (Spock's data path for
  non-bakery commits). Doesn't interact with the bakery state.

If any of these abstractions is questioned in code review, the model
must be re-examined to ensure it still represents the runtime
faithfully - formal models are only as useful as their fidelity.

## Bounds

`MaxTickets = 6, MaxIcebergLen = 5, |Writers| = 3` is the default
bound (`MaxCrashes` is 1 in the crash configs and 0 elsewhere; the
same-node configs use `MaxTickets = 3` with writers `{a1, a2, b1}`).
Every config checks in seconds on a modern laptop. `SYMMETRY`
on `Writers` (up to a ~6× reduction at 3 writers) is per-config: the
liveness configs (`Bakery_live.cfg`, `Bakery_fixed.cfg`) run
without it (symmetry reduction is unsound with liveness checking),
and the same-node configs run without it (`a1`/`a2`/`b1` are not
interchangeable under `NodeParts`); the other configs declare it.

The model is small enough that
larger bounds are interesting only if a regression is suspected.

## When to re-run

Re-run the model whenever the protocol it abstracts is touched. Any change
to:

- The bakery functions in `extension/coldfront/coldfront--1.0.sql`
  (`_claim_iceberg_lock`, `_insert_claim`, `_take_iceberg_claim`,
  `_exec_iceberg_with_claim`, `_enqueue_release`, `_on_claim_apply`,
  `_on_claim_release`, `_ensure_claims_replicated`).
- The `_exec_iceberg_with_claim` ordering or the
  `coldfront.iceberg_async_parquet` flag's meaning (which
  parquet-stage point / where `parent_snapshot_id` is stamped relative
  to the claim) - re-check `Bakery.cfg` (stock) AND
  `Bakery_async.cfg` (patched).
- The C-level XactCallback in `extension/coldfront/src/coldfront.c`
  (`coldfront_xact_callback`, `RegisterXactCallback` ordering).
- The `cmd/compactor` bakery wrapper - the claim/release that brackets
  its iceberg-go `RewriteDataFiles` commit (it must stay stock-ordering:
  claim held across read → rewrite → commit; no async-parquet
  shortcut).

If the protocol-level shape changes (e.g. swapping the bakery for a
different coordination primitive), update the PlusCal source first,
re-translate, re-check. CI integration is a future task; for now,
running the configs by hand is the workflow.

## Future work

The following extensions to the model and its tooling are planned:

- Add an async-replicated `user_table` to formally show the bakery
  is independent of Spock data-path lag.
- Wire into CI on touches to `extension/coldfront/`. The
  `tla2tools.jar` is ~5 MB; either check it in or download in a CI
  step. TLC runs in <2s for the current bounds.
