# Formal model — coldfront decoupled-mode bakery (TLA+/PlusCal)

This directory contains a formal model of the multi-writer Iceberg
commit serialization protocol that lives in
[../../extension/coldfront/coldfront--0.1.sql](../../extension/coldfront/coldfront--0.1.sql)
and [../../extension/coldfront/src/coldfront.c](../../extension/coldfront/src/coldfront.c).
The CI suites (`run-ci-distributed.sh` step 15 + 15b, `run-ci-local.sh`
step 8b) test the protocol against a fixed mesh shape — three docker
containers, single iceberg table, well-paced workload. The model
exhaustively explores **every interleaving** of N writers within
bounded depth, including failure injections that the CI can't easily
reproduce.

## Files

There are **two** PlusCal models in this directory, capturing different
levels of abstraction:

### v1 — atomic-claims abstraction

| File | Role |
|---|---|
| `Bakery.tla` | PlusCal source (between `(*--algorithm Bakery ... *)` markers) plus the auto-generated TLA+ translation below it.  Treats `coldfront.claims` as a globally-consistent set updated atomically by every INSERT. |
| `Bakery.cfg` | TLC config: 3 writers, 1 crash budget, four safety invariants. **Default v1 config**. |
| `Bakery_NoCrash.cfg` | 3 writers, 0 crashes, safety + `EventualProgress` liveness. Happy path. |
| `Bakery_SurvivorLiveness.cfg` | 3 writers, 1 crash, safety + `NonCrashedProgress`. In-bakery reap keeps surviving writers unstuck when a peer crashes mid-bakery. |

### v2 — asymmetric apply + Ricart-Agrawala

| File | Role |
|---|---|
| `Bakery_v2.tla` | PlusCal source.  Models the real spock world: each writer has its OWN local `claims[w]` view, INSERTs propagate via an explicit `Applier`.  No `synchronous_commit = remote_apply`.  Coordination is Lamport's 1978 distributed mutual exclusion algorithm with Ricart-Agrawala's (1981) deferred-reply optimisation: peers ack each claim immediately unless they have a pending claim with smaller ticket, in which case they defer the ack until they release their own claim. |
| `Bakery_v2.cfg` | TLC config: 3 writers, no crashes, all four safety invariants. **Default v2 config**.  Passes — R-A makes `NoLakekeeperConflict` and `TicketOrderPreserved` hold even with realistic asymmetric apply. |
| `Bakery_v2_crash.cfg` | 3 writers, 1 crash budget.  Safety invariants still hold (a crashed peer's missing ack just leaves surviving writers blocked at `WaitAcks` — no incorrect commits). |

## Properties

**Safety** (must hold; checked as TLC `INVARIANTS`):

- `NoLakekeeperConflict` — no writer's `decision` ends in `lk_409`.
  Equivalently: while a writer holds the bakery's minimum ticket,
  no other writer can issue a Lakekeeper CAS POST against the same
  iceberg table. This is the headline correctness claim — pre-bakery
  this could fail and produce silent commit loss.
- `RollbackNoIceberg` — if a writer's `decision = "rolled_back"`,
  there is no iceberg snapshot owned by that writer in the
  committed history. Models PG ROLLBACK undoing pg_duckdb's pending
  iceberg MetaTransaction.
- `UniqueTickets` — snowflake.nextval() doesn't return duplicates.
  Sanity check on the model abstraction.
- `TicketOrderPreserved` — committed snapshots are appended in the
  order their owners' tickets were granted. Ensured structurally by
  the bakery's min-ticket gate; encoded as an invariant for
  documentation.

**Liveness** (TLC `PROPERTIES`):

- `EventualProgress` — every writer that begins a claim eventually
  reaches a terminal `decision` (`committed` or `rolled_back`).
  Holds when no crashes; vacuously fails for writers that themselves
  crash mid-bakery (they can never decide). Use `NonCrashedProgress`
  when checking crash scenarios.
- `NonCrashedProgress` — every *live* writer with a claim eventually
  decides, or dies. The in-bakery reap (a writer at `BakeryWait`
  evicts the claim of a peer it deems dead) ensures surviving
  writers aren't held up by an orphan ticket.

**Protocol additions checked by the model** (added when the orphan
recovery design was nailed down):

- **Implicit witness via sync rep**: `BeginClaim` is gated on `\E p:
  p # self /\ ~ crashed[p]` — there must be at least one other alive
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

# v2.a Default: 3 writers, no crashes.  All safety invariants hold.
java -cp $TLA tlc2.TLC -workers auto -deadlock -config Bakery_v2.cfg Bakery_v2.tla

# v2.b 1 crash budget.  Safety still holds (crashed peer's missing ack
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

### `Bakery.cfg` (default)

```
Model checking completed. No error has been found.
874 states generated, 418 distinct states found, 0 states left on queue.
```

All four safety invariants hold even when one writer crashes
mid-bakery. Surviving writers' decisions are always either
`committed` or `rolled_back`; neither `lk_409` nor a snapshot from
a rolled-back writer ever appears.

### `Bakery_NoCrash.cfg`

```
Model checking completed. No error has been found.
197 states generated, 96 distinct states found, 0 states left on queue.
```

With no crashes, `EventualProgress` holds: every writer's claim
reaches a terminal decision.

### `Bakery_SurvivorLiveness.cfg`

```
Model checking completed. No error has been found.
838 states generated, 0 states left on queue.
```

With the in-bakery reap in place, when a writer crashes mid-bakery
its orphan claim is evicted by the next writer waiting at
`BakeryWait` (as soon as that writer observes the crashed peer is
heartbeat-stale). Surviving writers reach a terminal decision.

### `Bakery_v2.cfg`

```
Model checking completed. No error has been found.
747 states generated, 324 distinct states found, 0 states left on queue.
```

With per-writer local views, asymmetric Spock apply, and application-
level 409-retry, `EventuallyCommittedOrRolledBack` holds: every
`lk_409` is followed by a retry that converges to `committed` or
`rolled_back` within `MaxRetries`.

### `Bakery_v2_race.cfg`

```
Error: Invariant NoLakekeeperConflict is violated.
…
/\ decision = (w1 :> "lk_409" @@ w2 :> "committed")
558 states generated, 240 distinct states found, 0 states left on queue.
```

**Failure expected.** TLC produces a counter-example trace showing
the asymmetric-apply race: two concurrent writers pass min-check
on stale local views, both proceed to Lakekeeper, one POSTs first
and wins, the other gets 409. This is the formal demonstration of
the race we observed empirically in `run-ci-distributed.sh` step 15
— and the reason application-level 409-retry is non-optional.
`NonCrashedProgress` is the right property to check here:
the crashed writer itself can never decide (its plpgsql session is
dead), but every live writer with a claim still progresses.

## Model fidelity

The model is a *protocol-level* abstraction. The following are
represented faithfully because they affect protocol correctness:

- The bakery's min-ticket spin in
  [_claim_iceberg_lock](../../extension/coldfront/coldfront--0.1.sql)
  (lines around 1180).
- The deferred release: pg_duckdb's XactCallback commits iceberg
  first, then coldfront's XactCallback (registered after, runs after
  per PG's documented registration-order chain) DELETEs the claim.
  Modelled by combining the iceberg append + claim DELETE into one
  atomic step at `Decide`.
- pg_duckdb's iceberg ROLLBACK on PG ABORT (no append on the
  rollback branch) — required for the `RollbackNoIceberg` property
  to hold.
- NodeStartup self-cleanup of orphan claims (model uses blanket
  delete-by-node; real code uses an epoch-gate against
  `pg_postmaster_start_time()` to coexist with live concurrent
  backends sharing the node identity).
- In-bakery lazy reap with partition-alone guard (real code:
  identifies dead peers by absence of fresh `pg_stat_replication`
  row matching `application_name LIKE '%_sub_' || node_name ||
  '_from_%'`).
- BeginClaim alive-peer witness (real code: stricter — all
  reply-fresh peers must have flushed our LSN, partition-alone bail
  via RAISE).

### Known abstractions (model deviates from reality)

- **`claims` as globally-consistent set.** The model treats every
  INSERT into `claims` as atomically visible to all writers.
  Reality: `synchronous_commit = remote_apply` only proves that
  peers have applied *my* write before my commit returns. It does
  NOT prove that I have applied peers' *concurrent* writes. These
  are independent apply queues. A few-ms window exists in which
  two concurrent writers can both pass their local min-check, both
  POST to Lakekeeper, and one receives 409.
- **No `lk_409` in the model — yes in reality.** The model's
  `NoLakekeeperConflict` invariant holds because of the atomic-
  claims abstraction. In production the residual race is closed by
  application-level 409-retry (the standard Iceberg CAS pattern).
  The bakery's role is to make 409 *rare*, not impossible.

The following are *abstracted away* because they don't affect
protocol correctness:

- Lakekeeper REST API and Iceberg snapshot serialization. Modelled
  as an atomic CAS on a sequence head.
- pg_duckdb internals (its XactCallback registration ordering is a
  *premise* — coldfront loads after pg_duckdb in
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
faithfully — formal models are only as useful as their fidelity.

## Bounds

`MaxTickets = 6, MaxIcebergLen = 5, |Writers| = 3, MaxCrashes = 1` is
the default. State space at this bound: ~400-900 distinct states
across the three configs (all check in well under a second on a
modern laptop). Symmetry on `Writers` reduces by ~6×.

Pushing to 4 writers + MaxTickets = 8 generates a few thousand
distinct states — still trivial. The model is small enough that
larger bounds are interesting only if a regression is suspected.

## When to re-run

Any change to:

- The bakery functions in `extension/coldfront/coldfront--0.1.sql`
  (`_claim_iceberg_lock`, `_release_iceberg_lock`,
  `_exec_iceberg_with_claim`, `_enqueue_release`).
- The C-level XactCallback in `extension/coldfront/src/coldfront.c`
  (`coldfront_xact_callback`, `RegisterXactCallback` ordering).
- The `synchronous_*` GUCs that gate sync-rep on the claim INSERT.

If the protocol-level shape changes (e.g. swapping the bakery for a
different coordination primitive), update the PlusCal source first,
re-translate, re-check. CI integration is a future task; for now,
running the three configs by hand is the workflow.

## Future work

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
