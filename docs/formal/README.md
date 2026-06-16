# Formal model - coldfront decoupled-mode bakery (TLA+/PlusCal)

This directory contains a formal model of the multi-writer Iceberg
commit serialization protocol that lives in
[extension/coldfront/coldfront--0.1.sql](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--0.1.sql)
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
There are **two** PlusCal models in this directory, capturing different
levels of abstraction:

### v1 - atomic-claims abstraction

The v1 model treats `coldfront.claims` as a globally-consistent set.
The following table describes its files and their roles:

| File | Role |
|---|---|
| `Bakery.tla` | PlusCal source (between `(*--algorithm Bakery ... *)` markers) plus the auto-generated TLA+ translation below it.  Treats `coldfront.claims` as a globally-consistent set updated atomically by every INSERT. |
| `Bakery.cfg` | TLC config: 3 writers, 1 crash budget, four safety invariants. **Default v1 config**. |
| `Bakery_NoCrash.cfg` | 3 writers, 0 crashes, safety + `EventualProgress` liveness. Happy path. |
| `Bakery_SurvivorLiveness.cfg` | 3 writers, 1 crash, safety + `NonCrashedProgress`. In-bakery reap keeps surviving writers unstuck when a peer crashes mid-bakery. |

### v2 - asymmetric apply + Ricart-Agrawala

The v2 model gives each writer its own local view of the claims and
propagates inserts through an explicit applier. The following table
describes its files and their roles:

| File | Role |
|---|---|
| `Bakery_v2.tla` | PlusCal source.  Models the real spock world: each writer has its OWN local `claims[w]` view, INSERTs propagate via an explicit `Applier`.  No `synchronous_commit = remote_apply`.  Coordination is Lamport's 1978 distributed mutual exclusion algorithm with Ricart-Agrawala's (1981) deferred-reply optimisation: peers ack each claim immediately unless they have a pending claim with smaller ticket, in which case they defer the ack until they release their own claim.  Also models the `coldfront.iceberg_async_parquet` flag (constants `AsyncParquet`/`RestampPatch`): the `Stage` label stages parquet OUTSIDE the claim (async ordering); `Prepare` captures the `parent_snapshot_id` UNDER the claim (stock at stage time, patched async re-stamped at the commit POST); the `Decide` CAS asserts against it. |
| `Bakery_v2.cfg` | TLC config: 3 writers, no crashes, all four safety invariants. **Stock ordering** (`AsyncParquet=FALSE` - the default; parquet staged inside the claim).  Passes - R-A makes `NoLakekeeperConflict` and `TicketOrderPreserved` hold even with realistic asymmetric apply. |
| `Bakery_v2_async.cfg` | **Patched async ordering** (`AsyncParquet=TRUE, RestampPatch=TRUE`) - what the DuckDB 1.5.x (duckdb15) image runs: parquet staged outside the claim, `parent_snapshot_id` re-stamped at the commit POST under the claim by the bakery-aware patch.  All four safety invariants HOLD; the test is non-vacuous (shares the stock config's under-claim `Prepare→Decide` window, which R-A keeps empty). |
| `Bakery_v2_race.cfg` | **Pre-patch async race** (`AsyncParquet=TRUE, RestampPatch=FALSE`) - async ordering WITHOUT the bakery-aware patch: the stale tentative parent from the pre-claim stage is used at the POST. **`NoLakekeeperConflict` is EXPECTED to be violated** - the formal proof that the patch is mandatory for the async ordering. |
| `Bakery_v2_crash.cfg` | 3 writers, 1 crash budget (stock ordering - crash-safety is ordering-independent).  Safety invariants still hold (a crashed peer's missing ack just leaves surviving writers blocked at `WaitAcks` - no incorrect commits). |

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
  reaches a terminal `decision` (`committed` or `rolled_back`).
  Holds when no crashes; vacuously fails for writers that themselves
  crash mid-bakery (they can never decide). Use `NonCrashedProgress`
  when checking crash scenarios.
- `NonCrashedProgress` - every *live* writer with a claim eventually
  decides, or dies. The in-bakery reap (a writer at `BakeryWait`
  evicts the claim of a peer it deems dead) ensures surviving
  writers aren't held up by an orphan ticket.

### Protocol additions checked by the model

The model also checks the additions made when the orphan recovery
design was nailed down:

- **Implicit witness via sync rep**: `BeginClaim` is gated on `\E p:
  p # self /\ ~ crashed[p]` - there must be at least one other alive
  peer for the dblink sync-rep commit to confirm a witness. A node
  in the partitioned-alone minority can't get past `BeginClaim`, so
  it never gets to a state where it could falsely reap others.
- **In-bakery lazy reap**: `BakeryWait` evicts any blocker (`x.t <
  my_ticket`) whose node is currently dead. No separate reaper
  process; no periodic scan; the eviction happens only when a new
  claim actually needs to make progress.
- **NodeStartup self-cleanup**: when a node comes back from a
  restart it deletes its own stale claims first.

## Running TLC

Prereqs: Java 11+, TLA+ tools 1.8.0 jar at `/tmp/tla2tools.jar`
(download from
<https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar>).

```sh
TLA=/tmp/tla2tools.jar
cd docs/formal

# Translate both PlusCal sources (idempotent).
java -cp $TLA pcal.trans Bakery.tla
java -cp $TLA pcal.trans Bakery_v2.tla

# --- v1 (atomic-claims abstraction) ---

# v1.a Default: safety with one crash.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery.cfg Bakery.tla

# v1.b No-crash liveness.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_NoCrash.cfg Bakery.tla

# v1.c Survivor-liveness with crash (passes thanks to in-bakery reap).
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_SurvivorLiveness.cfg Bakery.tla

# --- v2 (asymmetric apply + Ricart-Agrawala) ---

# v2.a Stock ordering (AsyncParquet=FALSE): 3 writers, no crashes.  All hold.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_v2.cfg Bakery_v2.tla

# v2.b Patched async ordering (the duckdb15 image's path).  All hold.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_v2_async.cfg Bakery_v2.tla

# v2.c Pre-patch async race.  EXPECTED FAILURE: NoLakekeeperConflict violated —
#       the formal proof the bakery-aware patch is mandatory for the async path.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_v2_race.cfg Bakery_v2.tla

# v2.d 1 crash budget.  Safety still holds (crashed peer's missing ack
#       leaves survivors blocked at WaitAcks — no incorrect commits).
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_v2_crash.cfg Bakery_v2.tla
```

The `-deadlock` flag tells TLC not to flag final stuttering states as
errors. Without crashes the model terminates cleanly when every
writer reaches `Done`; with a crash a live writer can be stuck in
`BakeryWait` forever waiting for the orphan ticket. We want TLC to
report this as a `EventualProgress` violation, not as `Deadlock
reached`.

## Expected outputs

This section records the expected TLC result for each config, so a
reviewer can confirm a run matches the known-good output.

### `Bakery.cfg` (default)

The default config reports a clean check with the following output:

```text
Model checking completed. No error has been found.
874 states generated, 418 distinct states found, 0 states left on queue.
```

All four safety invariants hold even when one writer crashes
mid-bakery. Surviving writers' decisions are always either
`committed` or `rolled_back`; neither `lk_409` nor a snapshot from
a rolled-back writer ever appears.

### `Bakery_NoCrash.cfg`

The no-crash config reports a clean check with the following output:

```text
Model checking completed. No error has been found.
197 states generated, 96 distinct states found, 0 states left on queue.
```

With no crashes, `EventualProgress` holds: every writer's claim
reaches a terminal decision.

### `Bakery_SurvivorLiveness.cfg`

The survivor-liveness config reports a clean check with the following
output:

```text
Model checking completed. No error has been found.
838 states generated, 0 states left on queue.
```

With the in-bakery reap in place, when a writer crashes mid-bakery
its orphan claim is evicted by the next writer waiting at
`BakeryWait` (as soon as that writer observes the crashed peer is
heartbeat-stale). Surviving writers reach a terminal decision.

### `Bakery_v2.cfg` (stock ordering)

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

### `Bakery_v2_async.cfg` (patched async ordering)

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

### `Bakery_v2_race.cfg` (pre-patch async - EXPECTED FAILURE)

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
stock ordering (`Bakery_v2.cfg`) stamps the parent under the claim and
needs no patch. (The asymmetric-apply race that motivates R-A itself -
two writers passing a naive local min-check on stale views - is
structurally prevented by the R-A ack barrier in this model, so it has
no standalone config.)

## Model fidelity

The model is a *protocol-level* abstraction. The following are
represented faithfully because they affect protocol correctness:

- The `coldfront.iceberg_async_parquet` flag's two mesh orderings in
  [_exec_iceberg_with_claim](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--0.1.sql):
  stock (claim → stage+commit under the claim) and patched async
  (stage parquet outside the claim → claim → re-stamp
  `parent_snapshot_id` at the commit POST under the claim). The
  safety-critical invariant - the CAS parent is taken UNDER the held
  claim - is captured at `Prepare` for both; the
  `AsyncParquet`/`RestampPatch` constants select the ordering and
  whether the bakery-aware patch is present.
- The bakery's min-ticket spin in
  [_claim_iceberg_lock](https://github.com/pgEdge/ColdFront/blob/main/extension/coldfront/coldfront--0.1.sql)
  (lines around 1180).
- The deferred release: pg_duckdb's XactCallback commits iceberg
  first, then coldfront's XactCallback (registered after, runs after
  per PG's documented registration-order chain) DELETEs the claim.
  Modelled by combining the iceberg append + claim DELETE into one
  atomic step at `Decide`.
- pg_duckdb's iceberg ROLLBACK on PG ABORT (no append on the
  rollback branch) - required for the `RollbackNoIceberg` property
  to hold.
- NodeStartup self-cleanup of orphan claims (model uses blanket
  delete-by-node; real code uses an epoch-gate against
  `pg_postmaster_start_time()` to coexist with live concurrent
  backends sharing the node identity).
- In-bakery lazy reap with partition-alone guard (real code:
  identifies dead peers by absence of fresh `pg_stat_replication`
  row matching `application_name LIKE '%_sub_' || node_name ||
  '_from_%'`).
- BeginClaim alive-peer witness (real code: stricter - all
  reply-fresh peers must have flushed our LSN, partition-alone bail
  via RAISE).

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
`Bakery_v2.cfg`).

Its two maintenance operations are the **same claimant**, so they need
no new model: **`ExpireSnapshots`** issues another CAS commit (drop old
snapshots - identical conflict shape) under the held claim, covered
exactly like `RewriteDataFiles`; **`DeleteOrphanFiles`** holds the
claim but makes **no Lakekeeper commit** (it only deletes unreferenced
files), so it cannot cause a catalog conflict at all - strictly weaker
than a committing claimant, hence trivially within
`NoLakekeeperConflict`. All three reuse the existing
`coldfront._claim_iceberg_external`; the protocol is unchanged, so the
model and every config result are unchanged. (Lakekeeper itself does no
Iceberg snapshot/orphan maintenance - it is a catalog - so this is the
go-native path.)

Binding constraint: iceberg-go carries **no bakery-aware re-stamp
patch** (that patch lives only in the duckdb-iceberg commit path), so
the compactor MUST hold the claim across the whole read → rewrite →
commit and stamp the CAS parent under the claim. `Bakery_v2_race.cfg`
is the proof that the patchless-async shortcut 409s - the compactor is
therefore forbidden the async-parquet path. Commit-then-release matches
the cold-write shape the model already abstracts as the atomic `Decide`
step (commit iceberg, then DELETE the claim). The model is unchanged;
re-running every config confirms the invariants still hold.

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
FALSE` (`Bakery_v2.cfg`) is the config the model already proves safe.
No new protocol primitive is added, so the model and every config
result are unchanged.

In a mesh the user's ALTER replicates as a top-level statement and
re-runs in each peer's apply worker; the mirror self-skips there
(`session_replication_role = replica`) because the SHARED catalog was
already evolved by the originator. The single-commit shape thus holds -
the catalog is altered exactly once, by one claimant - and peers only
rebuild their per-node view.

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
new ordering, so `Bakery_v2` and every config result are unaffected.
(The archiver's cold cutover *does* commit to Iceberg under a claim,
but its detach is a plain transactional `DETACH` that Spock replicates
on its own - it is the already-modelled stock-ordering writer, not a
new primitive.)

### Known abstractions (model deviates from reality)

These are the points where the model deliberately deviates from
runtime reality:

- **`claims` as globally-consistent set.** The model treats every
  INSERT into `claims` as atomically visible to all writers.
  Reality: `synchronous_commit = remote_apply` only proves that
  peers have applied *my* write before my commit returns. It does
  NOT prove that I have applied peers' *concurrent* writes. These
  are independent apply queues. A few-ms window exists in which
  two concurrent writers can both pass their local min-check, both
  POST to Lakekeeper, and one receives 409.
- **No `lk_409` in the model - yes in reality.** The model's
  `NoLakekeeperConflict` invariant holds because of the atomic-
  claims abstraction. In production the residual race is closed by
  application-level 409-retry (the standard Iceberg CAS pattern).
  The bakery's role is to make 409 *rare*, not impossible.

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
  separate code path with its own CI test (`run-ci-local.sh` step
  8b's race-window regression).
- Async-replicated user-data tables (Spock's data path for
  non-bakery commits). Doesn't interact with the bakery state.

If any of these abstractions is questioned in code review, the model
must be re-examined to ensure it still represents the runtime
faithfully - formal models are only as useful as their fidelity.

## Bounds

`MaxTickets = 6, MaxIcebergLen = 5, |Writers| = 3, MaxCrashes = 1` is
the default. State space at this bound: ~400-900 distinct states
across the three configs (all check in well under a second on a
modern laptop). Symmetry on `Writers` reduces by ~6×.

Pushing to 4 writers + MaxTickets = 8 generates a few thousand
distinct states - still trivial. The model is small enough that
larger bounds are interesting only if a regression is suspected.

## When to re-run

Re-run the model whenever the protocol it abstracts is touched. Any change
to:

- The bakery functions in `extension/coldfront/coldfront--0.1.sql`
  (`_claim_iceberg_lock`, `_release_iceberg_lock`,
  `_exec_iceberg_with_claim`, `_enqueue_release`, `_on_claim_apply`,
  `_on_claim_release`).
- The `_exec_iceberg_with_claim` ordering or the
  `coldfront.iceberg_async_parquet` flag's meaning (which
  parquet-stage point / where `parent_snapshot_id` is stamped relative
  to the claim) - re-check `Bakery_v2.cfg` (stock) AND
  `Bakery_v2_async.cfg` (patched).
- The C-level XactCallback in `extension/coldfront/src/coldfront.c`
  (`coldfront_xact_callback`, `RegisterXactCallback` ordering).
- The `synchronous_*` GUCs that gate sync-rep on the claim INSERT.
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
- Add a `Restart` action so a crashed writer can come back, run
  `NodeStartup` (clearing its own orphan claims), and reattempt its
  bakery cycle. The current one-shot model already validates the
  safety + survivor-liveness properties; restart adds the
  partition-heal coverage.
- Model the dblink-session `statement_timeout` + post-timeout
  inspection explicitly (currently the `BeginClaim` precondition
  abstracts the outcome of "alive peers confirmed").
- Wire into CI on touches to `extension/coldfront/`. The
  `tla2tools.jar` is ~5 MB; either check it in or download in a CI
  step. TLC runs in <2s for the current bounds.
