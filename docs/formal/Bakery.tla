------------------------------- MODULE Bakery -------------------------------
(***************************************************************************)
(* PlusCal model of the coldfront decoupled-mode bakery protocol that      *)
(* serializes Iceberg commits across N PG nodes.                           *)
(*                                                                         *)
(* The protocol code lives in three places:                                *)
(*   * extension/coldfront/coldfront--1.0.sql                              *)
(*       _claim_iceberg_lock, _release_iceberg_lock,                       *)
(*       _exec_iceberg_with_claim, _enqueue_release.                       *)
(*   * extension/coldfront/src/coldfront.c                                 *)
(*       coldfront_xact_callback (libpq drainer), coldfront_enqueue_release*)
(*       (C bridge), wrap_cold_in_exec_with_claim (parse-analyze hook).    *)
(*   * docker/coldfront-spock-entrypoint.sh                                *)
(*       synchronous_standby_names = ANY 2 (star) + sync_commit = local + *)
(*       loopback DSNs with event_triggers=off.                            *)
(*                                                                         *)
(* The model abstracts away PG/DuckDB internals and Lakekeeper REST,       *)
(* keeping only the protocol-level state transitions:                      *)
(*                                                                         *)
(*   1. Claim:    sync-rep'd INSERT into coldfront.claims (atomic in this  *)
(*                model; see KNOWN ABSTRACTIONS below).                    *)
(*   2. Bakery:   spin until OUR snowflake ticket is the global minimum.   *)
(*                Reap blockers whose owner-node is currently dead — but   *)
(*                ONLY if at least one alive peer exists (partition-alone  *)
(*                guard).                                                  *)
(*   3. Prepare:  capture the iceberg snapshot head as our intended parent.*)
(*   4. Decide:   non-deterministically choose COMMIT or ROLLBACK.         *)
(*       4a Commit: Lakekeeper CAS.  In the model the bakery serialises   *)
(*                  writers atomically so the CAS always sees an unchanged *)
(*                  parent — `decision = "lk_409"` is unreachable.  In     *)
(*                  reality the bakery is best-effort serialisation; a    *)
(*                  few-ms window can let two writers race past min and   *)
(*                  both POST.  The losing POST receives 409.  The real-  *)
(*                  system handler is application-level retry on 409 (see *)
(*                  KNOWN ABSTRACTIONS below).                             *)
(*       4b Rollback: no iceberg append; the XactCallback still releases   *)
(*                    the claim (verified by run-ci-distributed step 14's *)
(*                    BEGIN/INSERT/ROLLBACK assertion).                    *)
(*                                                                         *)
(* KNOWN ABSTRACTIONS (model vs. reality):                                 *)
(*                                                                         *)
(*   * `claims` is modelled as a globally-consistent set.  Reality:        *)
(*     synchronous_commit = remote_apply guarantees peers have my INSERT   *)
(*     by the time my commit returns, but does NOT guarantee that I have  *)
(*     applied peers' concurrent INSERTs.  These are two independent     *)
(*     apply queues on different machines.  Outcome: a few-ms window in   *)
(*     which both writers can pass their local min-check, both POST, and  *)
(*     one gets Lakekeeper 409.  Application-level 409-retry is the       *)
(*     standard Iceberg-CAS pattern that closes this residual race.       *)
(*                                                                         *)
(*   * NodeStartup in the model deletes ALL `x.n = self` claims.  Reality *)
(*     uses an epoch-gate (`snowflake.get_epoch(ticket) <                  *)
(*     pg_postmaster_start_time()`) because multiple backends share one   *)
(*     node identity, and we mustn't clobber live concurrent claims on    *)
(*     the same node.                                                     *)
(*                                                                         *)
(*   * BeginClaim's "alive peer exists" precondition is implemented in    *)
(*     real code as a STRICTER witness check: post-INSERT, count peers    *)
(*     with reply-fresh `pg_stat_replication.reply_time` AND ensure all   *)
(*     have flushed our LSN.  If alive_total = 0 (partition-alone) or any *)
(*     alive peer hasn't flushed, the claim is released locally and we    *)
(*     RAISE.                                                              *)
(*                                                                         *)
(* Properties checked:                                                     *)
(*   - NoLakekeeperConflict       (safety, the headline — holds in the    *)
(*                                 atomic-claims abstraction; in reality  *)
(*                                 closed by application-level 409-retry) *)
(*   - RollbackNoIceberg          (safety)                                 *)
(*   - TicketOrderPreserved       (safety)                                 *)
(*   - UniqueTickets              (safety, sanity)                         *)
(*   - NonCrashedProgress         (liveness, conditional on no crash)      *)
(*   - EventualProgress           (liveness, expected to FAIL when crash   *)
(*                                 budget > 0 — formal demonstration of    *)
(*                                 the orphan-claim known limitation).     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Writers,        \* set of writer ids, e.g. {w1, w2, w3}
          MaxTickets,     \* upper bound on snowflake.nextval() so the
                          \* state space stays finite
          MaxIcebergLen,  \* upper bound on # of committed snapshots
          MaxCrashes      \* upper bound on crashed writers (0 = none,
                          \* 1 = one orphan claim demonstrated, etc.)

ASSUME /\ Writers # {}
       /\ MaxTickets    \in Nat /\ MaxTickets    >= Cardinality(Writers)
       /\ MaxIcebergLen \in Nat /\ MaxIcebergLen >= 1
       /\ MaxCrashes    \in Nat /\ MaxCrashes    <= Cardinality(Writers)

NoTicket == 0
NoSnap   == 0

(*--algorithm Bakery
variables
  \* Monotonically-increasing snowflake counter. snowflake.nextval() in
  \* the real system is per-node + counter + timestamp, but globally
  \* unique by construction; we collapse it to a single shared counter.
  next_ticket = 1,

  \* coldfront.claims.  Modelled as a globally-consistent set: every
  \* writer sees every other writer's INSERT atomically.  Reality
  \* relaxes this — synchronous_commit = remote_apply only proves
  \* peers have MY write, not that I have peers' writes (independent
  \* apply queues).  The race window this opens is closed by the
  \* application-level 409-retry, not by the bakery itself.  See KNOWN
  \* ABSTRACTIONS in the module header.
  \*
  \* Each row is [w |-> writer, t |-> ticket, n |-> node].  The `n`
  \* field models snowflake.get_node(ticket): the snowflake encoding
  \* lets any node attribute a claim to its originating node.  In this
  \* model writer ↔ node is 1:1 (Writers and Nodes coincide), so n = w.
  \* The orphan-claim reaper uses the n field to evict claims of nodes
  \* it considers dead.
  claims = {},

  \* The iceberg table's snapshot history.  iceberg[1] is the prime
  \* snapshot created by coldfront.create_iceberg_table (NULL insert +
  \* DELETE) so the table is non-empty before any user write.  Each
  \* later entry is [w |-> writer, t |-> ticket, parent |-> snap_id, kind |-> "commit"].
  \* The `t` field is the writer's snowflake ticket — kept on the
  \* snapshot record so TicketOrderPreserved can verify monotonicity.
  iceberg = << [w |-> 0, t |-> 0, parent |-> 0, kind |-> "prime"] >>,

  \* Per-writer terminal status, used by the safety / liveness invariants.
  decision = [w \in Writers |-> "none"],

  \* Crash bookkeeping.  A crashed writer halts in place — its claim row
  \* (if any) is orphaned because the C XactCallback that would have
  \* released it via libpq never fires.  The crash_budget cap keeps the
  \* state space tractable while still exercising the orphan path.
  crashed = [w \in Writers |-> FALSE],
  crash_budget = MaxCrashes;

define
  Live(w)        == ~ crashed[w]
  HasClaim(w)    == \E x \in claims : x.w = w
  ClaimOf(w)     == CHOOSE x \in claims : x.w = w
  IsMinClaim(w)  == HasClaim(w)
                    /\ \A x \in claims : ClaimOf(w).t <= x.t
  IcebergHead    == Len(iceberg)

  \* Safety invariants (checked as type-correctness for every reachable state)
  NoLakekeeperConflict ==
    \A w \in Writers : decision[w] # "lk_409"

  RollbackNoIceberg ==
    \A w \in Writers :
      decision[w] = "rolled_back" =>
        ~ \E i \in 1..Len(iceberg) : iceberg[i].w = w

  UniqueTickets ==
    \A x, y \in claims : x.t = y.t => x.w = y.w

  \* Tickets order their iceberg commits.  If A's snowflake is strictly
  \* less than B's and both committed, A's snapshot lies earlier in the
  \* iceberg history.  Holds because the bakery serializes commits in
  \* min-ticket order: the writer holding the smaller ticket exits the
  \* bakery first, posts to lakekeeper first, and lakekeeper's CAS
  \* sequences subsequent commits behind it.
  TicketOrderPreserved ==
    \A i, j \in 1..Len(iceberg) :
      ( i < j
        /\ iceberg[i].kind = "commit"
        /\ iceberg[j].kind = "commit" )
        => iceberg[i].t < iceberg[j].t
end define;

(*-----------------------------------------------------------------------*)
(* Writer process: one per PG backend running INSERT/UPDATE/DELETE on    *)
(* an iceberg-only wrapper view.  Each iteration of the outer Loop is    *)
(* one user statement that the C parse-analyze hook rewrote to           *)
(* coldfront._exec_iceberg_with_claim(table, sql).                       *)
(*-----------------------------------------------------------------------*)
fair process Writer \in Writers
variables
  my_ticket = NoTicket,
  parent_seen = NoSnap;
begin
  NodeStartup:
    \* Delete orphan claims from this node.  Model: blanket delete of
    \* x.n = self (writer ↔ node is 1:1, so no live concurrent claim
    \* on the same node).  Reality: real code uses an epoch-gate
    \* (snowflake.get_epoch(ticket) < pg_postmaster_start_time()) so
    \* the cleanup only removes pre-restart orphans and never clobbers
    \* a live concurrent backend on the same node.  Runs at every
    \* claim attempt; gated on a local EXISTS to avoid a sync-rep
    \* round-trip on the steady-state no-orphan path.
    await Live(self);
    claims := { x \in claims : x.n # self };

  BeginClaim:
    \* snowflake.nextval() + INSERT INTO coldfront.claims via the
    \* dblink session.  Real-system implementation:
    \*
    \*    SET synchronous_commit = remote_apply;  -- session-level
    \*    SET statement_timeout = '5s';           -- session-level
    \*    WITH ins AS (INSERT ... RETURNING 1)
    \*    SELECT pg_current_wal_lsn() FROM ins;   -- captures my_lsn
    \*
    \* The COMMIT either (a) succeeds within 5 s — sync rep got
    \* ANY 2 confirms; (b) times out — PG's sync-rep cancellation
    \* semantics: SyncRepWaitForLSN issues a WARNING and the local
    \* commit persists (the COMMIT completes asynchronously,
    \* syncrep.c QueryCancelPending branch).
    \*
    \* Post-INSERT witness check (real code, stricter than model):
    \*   alive_total = count of pg_stat_replication rows with
    \*     state='streaming' AND reply_time within 5 s.
    \*   unconfirmed = same set further restricted to replay_lsn <
    \*     my captured LSN.
    \*   alive_total = 0 OR unconfirmed > 0 → release claim, RAISE.
    \* This rules out partition-alone (alive_total = 0) and partial
    \* visibility (some live peer hasn't yet replayed my LSN).
    \*
    \* Model abstraction: only the OUTCOME is modelled — BeginClaim
    \* is enabled iff at least one OTHER alive peer exists.  The
    \* model treats the INSERT as atomic and globally-visible; the
    \* real-world asymmetric apply timing (which can cause two
    \* concurrent writers to both pass min-check) is documented in
    \* KNOWN ABSTRACTIONS at the module header.
    await Live(self) /\ \E p \in Writers : p # self /\ ~ crashed[p];
    my_ticket := next_ticket;
    next_ticket := next_ticket + 1;
    claims := claims \cup {[w |-> self, t |-> my_ticket, n |-> self]};

  BakeryWait:
    \* coldfront._claim_iceberg_lock's poll loop.  Exits when our ticket
    \* is the global minimum.  WHILE waiting, any claim from a node we
    \* believe is dead can be evicted — but ONLY claims with strictly-
    \* smaller tickets (the ones actually blocking us), and ONLY if at
    \* least one peer remains reply-fresh (the partition-alone guard:
    \* otherwise we'd infer death from our own isolation).
    \*
    \* "Believes is dead" is modelled here as `crashed[blocker.n]`.
    \* Real trigger: no fresh row in pg_stat_replication for that peer's
    \* walsender connection.  The match is by LIKE on application_name
    \* against spock.node.node_name (spock formats it as
    \* `spk_<db>_sub_<receiver>_from_<sender>`).  Reply-freshness
    \* threshold = 5 s; the underlying wal_sender_timeout/2 keepalive
    \* cadence bounds the worst-case detection latency.
    while Live(self) /\ ~ IsMinClaim(self) do
      with blocker \in
        { x \in claims :
            x.t < my_ticket /\ crashed[x.n] } do
        claims := claims \ { blocker };
      end with;
    end while;
    await Live(self) /\ IsMinClaim(self);

  Prepare:
    \* The user query has run; pg_duckdb queued the iceberg DML in
    \* its pending MetaTransaction.  Capture the snapshot head as
    \* our intended Lakekeeper-CAS parent.  In the real system this
    \* happens implicitly when DuckDB constructs the new manifest.
    await Live(self);
    parent_seen := IcebergHead;

  Decide:
    \* Outer PG transaction commits or rolls back.  Both paths fire
    \* the C-level XactCallback chain at xact end (pg_duckdb's
    \* first, coldfront's second), so the claim release is
    \* unconditional.  The iceberg side is conditional on COMMIT.
    await Live(self);
    either
      \* COMMIT path: pg_duckdb XactCallback issues iceberg POST
      \* (Lakekeeper CAS), then coldfront XactCallback releases
      \* the claim via libpq.  Modelled as one atomic step because in
      \* the model no other writer can interleave: their bakery is
      \* gated on our claim.
      \*
      \* MODEL vs REALITY: in real code two concurrent writers can
      \* both pass min-check inside a few-ms window (asymmetric apply
      \* timing — see module header).  Both POST; one gets 409.  The
      \* application-level 409-retry around the user's INSERT/UPDATE
      \* re-runs the failed statement after a brief backoff and the
      \* second attempt succeeds because by then the first commit is
      \* fully applied across the cluster.  The bakery does NOT make
      \* lk_409 unreachable in reality; it makes it RARE.
      if IcebergHead = parent_seen then
        iceberg := Append(iceberg,
                          [w |-> self, t |-> my_ticket,
                           parent |-> parent_seen, kind |-> "commit"]);
        decision[self] := "committed";
      else
        decision[self] := "lk_409";
      end if;
      claims := claims \ {[w |-> self, t |-> my_ticket, n |-> self]};
    or
      \* ROLLBACK path: no iceberg append (pg_duckdb's XactCallback
      \* on ABORT discards the pending MetaTransaction).  Claim is
      \* still released by our XactCallback.
      decision[self] := "rolled_back";
      claims := claims \ {[w |-> self, t |-> my_ticket, n |-> self]};
    end either;
end process;

(*-----------------------------------------------------------------------*)
(* Crasher: a separate process that may crash up to MaxCrashes writers,  *)
(* one at a time.  Models a backend dying mid-bakery.  When a writer is  *)
(* crashed mid-claim the row stays in coldfront.claims (orphan): the C   *)
(* XactCallback that would DELETE it never fires.                        *)
(*-----------------------------------------------------------------------*)
fair process Crasher = "crasher"
begin
  CrashLoop:
    while crash_budget > 0 do
      either
        with w \in Writers do
          await ~ crashed[w];
          crashed[w] := TRUE;
          crash_budget := crash_budget - 1;
        end with;
      or
        \* Stop crashing voluntarily.
        crash_budget := 0;
      end either;
    end while;
end process;


end algorithm; *)

\* ---- BEGIN TRANSLATION ----
VARIABLES pc, next_ticket, claims, iceberg, decision, crashed, crash_budget

(* define statement *)
Live(w)        == ~ crashed[w]
HasClaim(w)    == \E x \in claims : x.w = w
ClaimOf(w)     == CHOOSE x \in claims : x.w = w
IsMinClaim(w)  == HasClaim(w)
                  /\ \A x \in claims : ClaimOf(w).t <= x.t
IcebergHead    == Len(iceberg)


NoLakekeeperConflict ==
  \A w \in Writers : decision[w] # "lk_409"

RollbackNoIceberg ==
  \A w \in Writers :
    decision[w] = "rolled_back" =>
      ~ \E i \in 1..Len(iceberg) : iceberg[i].w = w

UniqueTickets ==
  \A x, y \in claims : x.t = y.t => x.w = y.w







TicketOrderPreserved ==
  \A i, j \in 1..Len(iceberg) :
    ( i < j
      /\ iceberg[i].kind = "commit"
      /\ iceberg[j].kind = "commit" )
      => iceberg[i].t < iceberg[j].t

VARIABLES my_ticket, parent_seen

vars == << pc, next_ticket, claims, iceberg, decision, crashed, crash_budget, 
           my_ticket, parent_seen >>

ProcSet == (Writers) \cup {"crasher"}

Init == (* Global variables *)
        /\ next_ticket = 1
        /\ claims = {}
        /\ iceberg = << [w |-> 0, t |-> 0, parent |-> 0, kind |-> "prime"] >>
        /\ decision = [w \in Writers |-> "none"]
        /\ crashed = [w \in Writers |-> FALSE]
        /\ crash_budget = MaxCrashes
        (* Process Writer *)
        /\ my_ticket = [self \in Writers |-> NoTicket]
        /\ parent_seen = [self \in Writers |-> NoSnap]
        /\ pc = [self \in ProcSet |-> CASE self \in Writers -> "NodeStartup"
                                        [] self = "crasher" -> "CrashLoop"]

NodeStartup(self) == /\ pc[self] = "NodeStartup"
                     /\ Live(self)
                     /\ claims' = { x \in claims : x.n # self }
                     /\ pc' = [pc EXCEPT ![self] = "BeginClaim"]
                     /\ UNCHANGED << next_ticket, iceberg, decision, crashed, 
                                     crash_budget, my_ticket, parent_seen >>

BeginClaim(self) == /\ pc[self] = "BeginClaim"
                    /\ Live(self) /\ \E p \in Writers : p # self /\ ~ crashed[p]
                    /\ my_ticket' = [my_ticket EXCEPT ![self] = next_ticket]
                    /\ next_ticket' = next_ticket + 1
                    /\ claims' = (claims \cup {[w |-> self, t |-> my_ticket'[self], n |-> self]})
                    /\ pc' = [pc EXCEPT ![self] = "BakeryWait"]
                    /\ UNCHANGED << iceberg, decision, crashed, crash_budget, 
                                    parent_seen >>

BakeryWait(self) == /\ pc[self] = "BakeryWait"
                    /\ IF Live(self) /\ ~ IsMinClaim(self)
                          THEN /\ \E blocker \in { x \in claims :
                                                     x.t < my_ticket[self] /\ crashed[x.n] }:
                                    claims' = claims \ { blocker }
                               /\ pc' = [pc EXCEPT ![self] = "BakeryWait"]
                          ELSE /\ Live(self) /\ IsMinClaim(self)
                               /\ pc' = [pc EXCEPT ![self] = "Prepare"]
                               /\ UNCHANGED claims
                    /\ UNCHANGED << next_ticket, iceberg, decision, crashed, 
                                    crash_budget, my_ticket, parent_seen >>

Prepare(self) == /\ pc[self] = "Prepare"
                 /\ Live(self)
                 /\ parent_seen' = [parent_seen EXCEPT ![self] = IcebergHead]
                 /\ pc' = [pc EXCEPT ![self] = "Decide"]
                 /\ UNCHANGED << next_ticket, claims, iceberg, decision, 
                                 crashed, crash_budget, my_ticket >>

Decide(self) == /\ pc[self] = "Decide"
                /\ Live(self)
                /\ \/ /\ IF IcebergHead = parent_seen[self]
                            THEN /\ iceberg' = Append(iceberg,
                                                      [w |-> self, t |-> my_ticket[self],
                                                       parent |-> parent_seen[self], kind |-> "commit"])
                                 /\ decision' = [decision EXCEPT ![self] = "committed"]
                            ELSE /\ decision' = [decision EXCEPT ![self] = "lk_409"]
                                 /\ UNCHANGED iceberg
                      /\ claims' = claims \ {[w |-> self, t |-> my_ticket[self], n |-> self]}
                   \/ /\ decision' = [decision EXCEPT ![self] = "rolled_back"]
                      /\ claims' = claims \ {[w |-> self, t |-> my_ticket[self], n |-> self]}
                      /\ UNCHANGED iceberg
                /\ pc' = [pc EXCEPT ![self] = "Done"]
                /\ UNCHANGED << next_ticket, crashed, crash_budget, my_ticket, 
                                parent_seen >>

Writer(self) == NodeStartup(self) \/ BeginClaim(self) \/ BakeryWait(self)
                   \/ Prepare(self) \/ Decide(self)

CrashLoop == /\ pc["crasher"] = "CrashLoop"
             /\ IF crash_budget > 0
                   THEN /\ \/ /\ \E w \in Writers:
                                   /\ ~ crashed[w]
                                   /\ crashed' = [crashed EXCEPT ![w] = TRUE]
                                   /\ crash_budget' = crash_budget - 1
                           \/ /\ crash_budget' = 0
                              /\ UNCHANGED crashed
                        /\ pc' = [pc EXCEPT !["crasher"] = "CrashLoop"]
                   ELSE /\ pc' = [pc EXCEPT !["crasher"] = "Done"]
                        /\ UNCHANGED << crashed, crash_budget >>
             /\ UNCHANGED << next_ticket, claims, iceberg, decision, my_ticket, 
                             parent_seen >>

Crasher == CrashLoop

(* Allow infinite stuttering to prevent deadlock on termination. *)
Terminating == /\ \A self \in ProcSet: pc[self] = "Done"
               /\ UNCHANGED vars

Next == Crasher
           \/ (\E self \in Writers: Writer(self))
           \/ Terminating

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Writers : WF_vars(Writer(self))
        /\ WF_vars(Crasher)

Termination == <>(\A self \in ProcSet: pc[self] = "Done")

\* ---- END TRANSLATION ----

(***************************************************************************)
(* Liveness properties.  EventualProgress is the unconditional version,    *)
(* expected to FAIL when MaxCrashes > 0 (formal demonstration of the       *)
(* orphan-claim known limitation).  NonCrashedProgress is the conditional  *)
(* version that is expected to hold.                                       *)
(***************************************************************************)

EventualProgress ==
  \A w \in Writers :
    (decision[w] = "none" /\ HasClaim(w))
      ~> (decision[w] \in {"committed", "rolled_back"})

NonCrashedProgress ==
  \A w \in Writers :
    (decision[w] = "none" /\ HasClaim(w) /\ Live(w))
      ~> (decision[w] \in {"committed", "rolled_back"} \/ ~ Live(w))

(***************************************************************************)
(* Symmetry: writers are interchangeable.  Defined here so the TLC config  *)
(* can reference it as `SYMMETRY WriterSymmetry`.                          *)
(***************************************************************************)
WriterSymmetry == Permutations(Writers)

=============================================================================
