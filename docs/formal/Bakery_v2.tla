------------------------------ MODULE Bakery_v2 -----------------------------
(***************************************************************************)
(* v2 of the decoupled-mode bakery model.  Where v1 abstracted              *)
(* `coldfront.claims` as a globally-consistent set, v2 models the           *)
(* real-world asymmetry of Spock replication (each writer has its own       *)
(* local view; INSERTs propagate via an explicit Apply step) AND adds the   *)
(* Ricart-Agrawala (1981) optimisation of Lamport's 1978 distributed       *)
(* mutual exclusion algorithm to compensate for that asymmetry.            *)
(*                                                                         *)
(* Protocol (Ricart-Agrawala):                                             *)
(*   1. Writer inserts claim into its own claims[w].  Replicates via Apply *)
(*      (async).                                                            *)
(*   2. Each peer, on applying my claim, DECIDES then WRITES (two steps,   *)
(*      faithful to the non-atomic SQL -- see SafeAcks):                   *)
(*       - own pending claim with SMALLER ticket -> DEFER the ack          *)
(*         (queue in `deferred`); otherwise ack immediately.               *)
(*   3. Writer waits until every alive peer has acked.                     *)
(*   4. Writer proceeds to Decide (the CAS, under the held claim).         *)
(*   5. On release: FORWARD the deferred acks (deferred -> acks) then      *)
(*      DELETE them -- also two steps.                                     *)
(*                                                                         *)
(* SafeAcks -- implementation atomicity, NOT a protocol change:            *)
(*   The apply-time defer DECISION/WRITE and the release FORWARD/DELETE    *)
(*   are non-atomic in the SQL.  SafeAcks=FALSE models that faithfully:    *)
(*   a deferral written behind a just-released claim is deleted            *)
(*   unforwarded/orphaned -- the dropped ack strands the min-ticket        *)
(*   holder at WaitAcks forever (the N-writer wedge).  SafeAcks=TRUE       *)
(*   re-evaluates R-A's defer rule ATOMICALLY against the claim:           *)
(*   SELECT ... FOR UPDATE on the claim row in coldfront._on_claim_apply,  *)
(*   so it never defers behind a released claim.  R-A is unchanged; only   *)
(*   the implementation's atomicity differs.                              *)
(*                                                                         *)
(* Properties:                                                             *)
(*   SAFETY (hold under both SafeAcks values):                            *)
(*   - NoLakekeeperConflict  (R-A: only one writer has all acks at a time *)
(*                            per iceberg table -- no concurrent CAS races)*)
(*   - TicketOrderPreserved, RollbackNoIceberg, UniqueTickets             *)
(*   LIVENESS:                                                            *)
(*   - EventualProgress (every writer eventually decides): HOLDS under    *)
(*     SafeAcks=TRUE (Bakery_v2_fixed.cfg); VIOLATED under SafeAcks=FALSE *)
(*     (Bakery_v2_live.cfg) -- the dropped-ack wedge.                     *)
(***************************************************************************)
(* Execution privilege (protocol-neutral).  In the implementation the       *)
(* coordination functions _claim_iceberg_lock and _release_iceberg_lock are  *)
(* SECURITY DEFINER (search_path pinned; both are fully schema-qualified), so *)
(* a non-superuser writer drives the protocol with the SAME privilege as a   *)
(* superuser: the pg_stat_replication alive-check sees every walsender (a     *)
(* non-superuser INVOKER would see none -> wrongly rule all peers dead ->     *)
(* skip acks -> the very race NoLakekeeperConflict forbids), and the dblink   *)
(* claim-INSERT + coldfront.claims / spock.local_node reads succeed.  The     *)
(* C-level _enqueue_release only appends a ticket to an in-memory queue (no   *)
(* privileged op), and the release itself runs in the C XactCallback's own    *)
(* libpq loopback as the coldfront owner -- both already privileged, neither  *)
(* needs SD.  _exec_iceberg_with_claim stays SECURITY INVOKER (it runs the    *)
(* caller's cold DML, which must execute with the caller's privileges -- SD   *)
(* there would let a non-superuser run arbitrary DuckDB as superuser).        *)
(* SECURITY DEFINER changes only the PG execution privilege, NOT the          *)
(* claim/ack/lock/ticket protocol modelled here; it makes the non-superuser   *)
(* path CONFORM to the model's standing assumption of correct liveness +      *)
(* claim propagation.  The model is thus unchanged; the TLC re-check (all     *)
(* configs) proves the invariants still hold.                                *)
(***************************************************************************)
(* Compaction commits (cmd/compactor).  A Go maintenance job rewrites many   *)
(* small Iceberg data files into fewer large ones via apache/iceberg-go's     *)
(* RewriteDataFiles.  At the PROTOCOL level it is indistinguishable from a     *)
(* cold writer modelled here: it acquires a claim (_claim_iceberg_lock on the  *)
(* node it connects to), captures the parent snapshot UNDER the held claim,    *)
(* issues ONE Lakekeeper CAS POST -- a REPLACE (drop old data files, add new), *)
(* which has the SAME parent-CAS conflict shape as the APPEND modelled at      *)
(* Decide -- then releases.  It adds NO new protocol primitive; it is the      *)
(* stock-ordering writer, i.e. AsyncParquet = FALSE.                           *)
(*                                                                            *)
(* The compactor's maintenance ops are the SAME claimant, needing no new       *)
(* model: ExpireSnapshots is another CAS commit (drop old snapshots; same      *)
(* parent-CAS conflict shape) under the held claim; DeleteOrphanFiles holds    *)
(* the claim but makes NO Lakekeeper commit (deletes only unreferenced files), *)
(* so it cannot conflict at all.  Both reuse _claim_iceberg_external; protocol  *)
(* unchanged, so every config result is unchanged.                             *)
(*                                                                            *)
(* Binding constraint proved here: iceberg-go has NO bakery-aware re-stamp     *)
(* patch (that patch exists only in the duckdb-iceberg commit path), so the    *)
(* compactor MUST hold the claim across read -> rewrite -> commit and stamp    *)
(* the CAS parent UNDER the claim.  Bakery_v2.cfg (AsyncParquet = FALSE) is    *)
(* its safety proof; Bakery_v2_race.cfg proves the patchless-async shortcut    *)
(* 409s, so the compactor is forbidden the async path.                         *)
(*                                                                            *)
(* Commit-then-release fidelity: the compactor commits via iceberg-go, THEN    *)
(* releases the claim at the bracketing PG-txn commit -- the same             *)
(* commit-then-release shape the model already abstracts as the atomic Decide  *)
(* step for cold writes (pg_duckdb commits iceberg, then coldfront's           *)
(* XactCallback DELETEs the claim).  The model is thus unchanged; the TLC      *)
(* re-check (all configs) proves the invariants still hold.                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Writers,
          MaxTickets,
          MaxIcebergLen,
          MaxCrashes,
          AsyncParquet,   \* coldfront.iceberg_async_parquet: TRUE stages the parquet
                          \* OUTSIDE the claim (patched-iceberg upload overlap); FALSE
                          \* stages it inside the claim (stock iceberg, the default).
          RestampPatch,   \* the bakery-aware-commit-refresh patch re-stamps
                          \* parent_snapshot_id at the commit POST, UNDER the claim.
                          \* TRUE = patched deployment. AsyncParquet=TRUE with
                          \* RestampPatch=FALSE reproduces the pre-patch 409 race that
                          \* makes the patch mandatory for the async ordering.
          SafeAcks        \* TRUE = the SAFE implementation of R-A's defer/ack: the
                          \* defer is written atomically with a re-check of R-A's own
                          \* rule (the smaller-ticket claim must STILL be held), so a
                          \* deferral is never written behind a released claim, and the
                          \* drain can't drop it. FALSE = the non-atomic implementation
                          \* (decide, then separately write) that drops acks — the bug.
                          \* The PROTOCOL (R-A) is identical either way; only the
                          \* implementation's atomicity differs.

ASSUME /\ Writers # {}
       /\ MaxTickets    \in Nat /\ MaxTickets    >= Cardinality(Writers)
       /\ MaxIcebergLen \in Nat /\ MaxIcebergLen >= 1
       /\ MaxCrashes    \in Nat /\ MaxCrashes    <= Cardinality(Writers)
       /\ AsyncParquet  \in BOOLEAN
       /\ RestampPatch  \in BOOLEAN
       /\ SafeAcks      \in BOOLEAN

NoTicket == 0
NoSnap   == 0

(*--algorithm Bakery_v2
variables
  next_ticket = 1,

  \* Per-writer LOCAL view of coldfront.claims.  Asymmetric apply is
  \* the realistic spock behaviour; R-A's deferred-ack mechanism
  \* compensates by gating min-equivalent on per-peer acks.
  claims = [w \in Writers |-> {}],

  \* Acks received per ticket.  A pair <<t, p>> in `acks` means peer p
  \* has acked the claim with ticket t.  Models coldfront.claim_acks
  \* (on the originator side, fully populated via spock replication of
  \* peer-emitted ack rows).
  acks = {},

  \* Deferred acks: pair <<p, t>> means peer p has queued an ack-for-
  \* ticket-t that it'll fire when p releases its own pending claim.
  \* Models coldfront.deferred_acks on each peer.
  deferred = {},

  iceberg = << [w |-> 0, t |-> 0, parent |-> 0, kind |-> "prime"] >>,

  decision    = [w \in Writers |-> "none"],
  crashed     = [w \in Writers |-> FALSE],
  crash_budget = MaxCrashes;

define
  Live(w)        == ~ crashed[w]
  IcebergHead    == Len(iceberg)

  \* All alive peers (excluding self) have acked ticket t.  The
  \* `~ Live(p)` shortcut is the failure-detector clause: a crashed
  \* peer's missing ack does not block progress.  In the real system
  \* this is implemented by combining the claim_acks table with a
  \* heartbeat-staleness check (pg_stat_replication.reply_time) so
  \* dead peers are treated as already-acked.  This closes the
  \* classic R-A weakness where a crashed peer's deferred ack would
  \* strand survivors forever.
  AlivePeersHaveAcked(self, t) ==
    \A p \in Writers :
      p = self \/ ~ Live(p) \/ <<t, p>> \in acks

  \* Tickets this writer has queued deferred acks for.
  MyDeferredTickets(self) ==
    { t : <<p, t>> \in {x \in deferred : x[1] = self} }

  \* Safety properties (all HOLD in v2).
  NoLakekeeperConflict ==
    \A w \in Writers : decision[w] # "lk_409"

  RollbackNoIceberg ==
    \A w \in Writers :
      decision[w] = "rolled_back" =>
        ~ \E i \in 1..Len(iceberg) : iceberg[i].w = w

  UniqueTickets ==
    \A p, q \in Writers :
      \A x \in claims[p], y \in claims[q] :
        x.t = y.t => x.w = y.w

  TicketOrderPreserved ==
    \A i, j \in 1..Len(iceberg) :
      ( i < j
        /\ iceberg[i].kind = "commit"
        /\ iceberg[j].kind = "commit" )
        => iceberg[i].t < iceberg[j].t

  \* LIVENESS — every writer eventually reaches a terminal decision.  A writer
  \* whose ack is dropped by the non-atomic defer/drain race is stranded at
  \* WaitAcks forever: AlivePeersHaveAcked can NEVER become true because the
  \* dropped ack can never be produced (its deferral was deleted unforwarded /
  \* orphaned).  The OLD atomic Applier+drain could not expose this; the faithful
  \* split below can.  Expected to be VIOLATED in Bakery_v2_live.cfg (the bug),
  \* and to HOLD again once the fix re-atomises defer vs drain.
  EventualProgress ==
    \A w \in Writers : <>(decision[w] \in {"committed", "rolled_back", "lk_409"})
end define;

fair process Writer \in Writers
variables
  my_ticket = NoTicket,
  parent_seen = NoSnap,
  parent_staged = NoSnap;   \* tentative parent captured at the pre-claim parquet
                            \* stage in the async (patched) path. Discarded by the
                            \* under-claim re-stamp when RestampPatch; used as-is
                            \* (and races) when the patch is absent.
begin
  Start:
    await Live(self);

  Stage:
    \* Async (patched) ordering stages the parquet OUTSIDE the claim — writers
    \* overlap freely on S3 — and captures a TENTATIVE parent at stage time.
    \* The commit POST re-stamps it under the claim (Decide). The stock ordering
    \* stages inside the claim, so it has no pre-claim stage (parent taken at
    \* Prepare, already under the claim).
    await Live(self);
    if AsyncParquet then
      parent_staged := IcebergHead;
    end if;

  BeginClaim:
    \* Insert claim into my local view.  Async replication via Applier.
    \* No sync rep — R-A's ack barrier replaces it.
    await Live(self) /\ \E p \in Writers : p # self /\ Live(p);
    await next_ticket <= MaxTickets;
    my_ticket := next_ticket;
    next_ticket := next_ticket + 1;
    claims[self] := claims[self] \cup
                    {[w |-> self, t |-> my_ticket, n |-> self]};

  WaitAcks:
    \* Wait for every alive peer to ack.  Peers ack either immediately
    \* (no smaller-ticket pending claim there) or via the deferred-drain
    \* fired by the smaller-ticket holder at its Release.  Either way,
    \* "all acks in" == "I'm at the head of the line."  No min-spin.
    await Live(self) /\ AlivePeersHaveAcked(self, my_ticket);

  Prepare:
    \* Capture the parent_snapshot_id the Lakekeeper CAS asserts against:
    \*   - stock (AsyncParquet FALSE): stamped at stage time, which is UNDER the
    \*     claim (we are past WaitAcks).
    \*   - patched async (RestampPatch TRUE): the commit POST RE-STAMPS to the
    \*     current head, also UNDER the claim. Catalog-identical to stock, so it
    \*     reduces to the same "parent = head, taken under the claim".
    \* Both are modelled at this first under-claim point. The Prepare->Decide gap
    \* is the window a BROKEN bakery would let a peer's commit slip into (it would
    \* surface as a CAS mismatch at Decide); R-A keeps that window empty — which is
    \* what the stock/async configs actually verify, NOT vacuously.
    \*   - async WITHOUT the patch (RestampPatch FALSE): the stale tentative parent
    \*     from the pre-claim Stage is used instead — the pre-patch race.
    await Live(self);
    if ~ AsyncParquet \/ RestampPatch then
      parent_seen := IcebergHead;
    else
      parent_seen := parent_staged;
    end if;

  Decide:
    \* The CAS, UNDER the still-held claim (released only at Release below).
    await Live(self);
    either
      \* COMMIT.  Under R-A, when all my acks are in, no other writer with a
      \* smaller ticket is past their WaitAcks — so under the claim the iceberg
      \* head is stable from the (re-)stamp to the CAS.  CAS always succeeds.
      if IcebergHead = parent_seen then
        iceberg := Append(iceberg,
                          [w |-> self, t |-> my_ticket,
                           parent |-> parent_seen, kind |-> "commit"]);
        decision[self] := "committed";
      else
        decision[self] := "lk_409";
      end if;
    or
      decision[self] := "rolled_back";
    end either;

  Release:
    \* The C XactCallback's claim DELETE: remove my claim from every local view.
    await Live(self);
    claims := [p \in Writers |->
                claims[p] \ {[w |-> self, t |-> my_ticket, n |-> self]}];

  DrainForward:
    \* _on_claim_release step 1 (forward): INSERT claim_acks SELECT … FROM
    \* deferred_acks WHERE pending = my ticket.  A deferral the Applier writes
    \* AFTER this read but BEFORE DrainDelete is NOT seen here.
    await Live(self);
    acks := acks \cup { <<t, self>> : t \in MyDeferredTickets(self) };

  DrainDelete:
    \* _on_claim_release step 2 (the SEPARATE DELETE): delete my deferrals —
    \* including any inserted in the DrainForward→here window, which were never
    \* forwarded.  Non-atomic forward-then-delete = the silently dropped ack.
    await Live(self);
    deferred := { x \in deferred : x[1] # self };
end process;

(*-----------------------------------------------------------------------*)
(* Applier — propagates INSERTs between local views (asymmetric apply).  *)
(* At apply time, the R-A defer-or-ack decision is made.                 *)
(*-----------------------------------------------------------------------*)
fair process Applier = "applier"
variables ap_dst = NoTicket, ap_ct = NoTicket, ap_defer = FALSE;
begin
  ApplyLoop:
    while TRUE do
      \* ApplyDecide — apply one claim into dst's local view and DECIDE, under the
      \* read snapshot, whether to defer or ack.  Mirrors _on_claim_apply reading
      \* coldfront.claims (the shared advisory lock is dropped after this SELECT)
      \* and CHOOSING defer-vs-ack — but NOT yet writing it.
      with src \in Writers, dst \in Writers do
        await dst # src /\ Live(dst);
        with c \in { x \in claims[src] : x \notin claims[dst] /\ x.w = src } do
          claims[dst] := claims[dst] \cup { c };
          ap_dst   := dst;
          ap_ct    := c.t;
          ap_defer := \E own \in claims[dst] : own.w = dst /\ own.t < c.t;
        end with;
      end with;

    ApplyEmit:
      \* The defer/ack write.
      \*   ~SafeAcks: write the STALE ApplyDecide verdict.  The holder may have
      \*     released since, so the deferral is written behind a gone claim and is
      \*     deleted-unforwarded / orphaned — the dropped-ack bug.  Models today's
      \*     non-atomic "decide (lock dropped) then separately INSERT".
      \*   SafeAcks: re-evaluate R-A's defer rule ATOMICALLY against the CURRENT
      \*     claim and write in the same step.  In SQL this is a single
      \*     `SELECT smaller_pending … FOR UPDATE` on the holder's CLAIM ROW (the
      \*     same row the release's DELETE locks) plus the conditional defer/ack:
      \*     holder's claim still held -> defer; gone -> ack.  R-A's rule unchanged,
      \*     made atomic, so a deferral is never written behind a released claim.
      if (IF SafeAcks
            THEN \E own \in claims[ap_dst] : own.w = ap_dst /\ own.t < ap_ct
            ELSE ap_defer)
      then
        deferred := deferred \cup { <<ap_dst, ap_ct>> };
      else
        acks := acks \cup { <<ap_ct, ap_dst>> };
      end if;
    end while;
end process;

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
        crash_budget := 0;
      end either;
    end while;
end process;

end algorithm; *)
\* BEGIN TRANSLATION (chksum(pcal) = "14190c1" /\ chksum(tla) = "a5729adc")
VARIABLES pc, next_ticket, claims, acks, deferred, iceberg, decision, crashed, 
          crash_budget

(* define statement *)
Live(w)        == ~ crashed[w]
IcebergHead    == Len(iceberg)









AlivePeersHaveAcked(self, t) ==
  \A p \in Writers :
    p = self \/ ~ Live(p) \/ <<t, p>> \in acks


MyDeferredTickets(self) ==
  { t : <<p, t>> \in {x \in deferred : x[1] = self} }


NoLakekeeperConflict ==
  \A w \in Writers : decision[w] # "lk_409"

RollbackNoIceberg ==
  \A w \in Writers :
    decision[w] = "rolled_back" =>
      ~ \E i \in 1..Len(iceberg) : iceberg[i].w = w

UniqueTickets ==
  \A p, q \in Writers :
    \A x \in claims[p], y \in claims[q] :
      x.t = y.t => x.w = y.w

TicketOrderPreserved ==
  \A i, j \in 1..Len(iceberg) :
    ( i < j
      /\ iceberg[i].kind = "commit"
      /\ iceberg[j].kind = "commit" )
      => iceberg[i].t < iceberg[j].t








EventualProgress ==
  \A w \in Writers : <>(decision[w] \in {"committed", "rolled_back", "lk_409"})

VARIABLES my_ticket, parent_seen, parent_staged, ap_dst, ap_ct, ap_defer

vars == << pc, next_ticket, claims, acks, deferred, iceberg, decision, 
           crashed, crash_budget, my_ticket, parent_seen, parent_staged, 
           ap_dst, ap_ct, ap_defer >>

ProcSet == (Writers) \cup {"applier"} \cup {"crasher"}

Init == (* Global variables *)
        /\ next_ticket = 1
        /\ claims = [w \in Writers |-> {}]
        /\ acks = {}
        /\ deferred = {}
        /\ iceberg = << [w |-> 0, t |-> 0, parent |-> 0, kind |-> "prime"] >>
        /\ decision = [w \in Writers |-> "none"]
        /\ crashed = [w \in Writers |-> FALSE]
        /\ crash_budget = MaxCrashes
        (* Process Writer *)
        /\ my_ticket = [self \in Writers |-> NoTicket]
        /\ parent_seen = [self \in Writers |-> NoSnap]
        /\ parent_staged = [self \in Writers |-> NoSnap]
        (* Process Applier *)
        /\ ap_dst = NoTicket
        /\ ap_ct = NoTicket
        /\ ap_defer = FALSE
        /\ pc = [self \in ProcSet |-> CASE self \in Writers -> "Start"
                                        [] self = "applier" -> "ApplyLoop"
                                        [] self = "crasher" -> "CrashLoop"]

Start(self) == /\ pc[self] = "Start"
               /\ Live(self)
               /\ pc' = [pc EXCEPT ![self] = "Stage"]
               /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                               decision, crashed, crash_budget, my_ticket, 
                               parent_seen, parent_staged, ap_dst, ap_ct, 
                               ap_defer >>

Stage(self) == /\ pc[self] = "Stage"
               /\ Live(self)
               /\ IF AsyncParquet
                     THEN /\ parent_staged' = [parent_staged EXCEPT ![self] = IcebergHead]
                     ELSE /\ TRUE
                          /\ UNCHANGED parent_staged
               /\ pc' = [pc EXCEPT ![self] = "BeginClaim"]
               /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                               decision, crashed, crash_budget, my_ticket, 
                               parent_seen, ap_dst, ap_ct, ap_defer >>

BeginClaim(self) == /\ pc[self] = "BeginClaim"
                    /\ Live(self) /\ \E p \in Writers : p # self /\ Live(p)
                    /\ next_ticket <= MaxTickets
                    /\ my_ticket' = [my_ticket EXCEPT ![self] = next_ticket]
                    /\ next_ticket' = next_ticket + 1
                    /\ claims' = [claims EXCEPT ![self] = claims[self] \cup
                                                          {[w |-> self, t |-> my_ticket'[self], n |-> self]}]
                    /\ pc' = [pc EXCEPT ![self] = "WaitAcks"]
                    /\ UNCHANGED << acks, deferred, iceberg, decision, crashed, 
                                    crash_budget, parent_seen, parent_staged, 
                                    ap_dst, ap_ct, ap_defer >>

WaitAcks(self) == /\ pc[self] = "WaitAcks"
                  /\ Live(self) /\ AlivePeersHaveAcked(self, my_ticket[self])
                  /\ pc' = [pc EXCEPT ![self] = "Prepare"]
                  /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                                  decision, crashed, crash_budget, my_ticket, 
                                  parent_seen, parent_staged, ap_dst, ap_ct, 
                                  ap_defer >>

Prepare(self) == /\ pc[self] = "Prepare"
                 /\ Live(self)
                 /\ IF ~ AsyncParquet \/ RestampPatch
                       THEN /\ parent_seen' = [parent_seen EXCEPT ![self] = IcebergHead]
                       ELSE /\ parent_seen' = [parent_seen EXCEPT ![self] = parent_staged[self]]
                 /\ pc' = [pc EXCEPT ![self] = "Decide"]
                 /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                                 decision, crashed, crash_budget, my_ticket, 
                                 parent_staged, ap_dst, ap_ct, ap_defer >>

Decide(self) == /\ pc[self] = "Decide"
                /\ Live(self)
                /\ \/ /\ IF IcebergHead = parent_seen[self]
                            THEN /\ iceberg' = Append(iceberg,
                                                      [w |-> self, t |-> my_ticket[self],
                                                       parent |-> parent_seen[self], kind |-> "commit"])
                                 /\ decision' = [decision EXCEPT ![self] = "committed"]
                            ELSE /\ decision' = [decision EXCEPT ![self] = "lk_409"]
                                 /\ UNCHANGED iceberg
                   \/ /\ decision' = [decision EXCEPT ![self] = "rolled_back"]
                      /\ UNCHANGED iceberg
                /\ pc' = [pc EXCEPT ![self] = "Release"]
                /\ UNCHANGED << next_ticket, claims, acks, deferred, crashed, 
                                crash_budget, my_ticket, parent_seen, 
                                parent_staged, ap_dst, ap_ct, ap_defer >>

Release(self) == /\ pc[self] = "Release"
                 /\ Live(self)
                 /\ claims' = [p \in Writers |->
                                claims[p] \ {[w |-> self, t |-> my_ticket[self], n |-> self]}]
                 /\ pc' = [pc EXCEPT ![self] = "DrainForward"]
                 /\ UNCHANGED << next_ticket, acks, deferred, iceberg, 
                                 decision, crashed, crash_budget, my_ticket, 
                                 parent_seen, parent_staged, ap_dst, ap_ct, 
                                 ap_defer >>

DrainForward(self) == /\ pc[self] = "DrainForward"
                      /\ Live(self)
                      /\ acks' = (acks \cup { <<t, self>> : t \in MyDeferredTickets(self) })
                      /\ pc' = [pc EXCEPT ![self] = "DrainDelete"]
                      /\ UNCHANGED << next_ticket, claims, deferred, iceberg, 
                                      decision, crashed, crash_budget, 
                                      my_ticket, parent_seen, parent_staged, 
                                      ap_dst, ap_ct, ap_defer >>

DrainDelete(self) == /\ pc[self] = "DrainDelete"
                     /\ Live(self)
                     /\ deferred' = { x \in deferred : x[1] # self }
                     /\ pc' = [pc EXCEPT ![self] = "Done"]
                     /\ UNCHANGED << next_ticket, claims, acks, iceberg, 
                                     decision, crashed, crash_budget, 
                                     my_ticket, parent_seen, parent_staged, 
                                     ap_dst, ap_ct, ap_defer >>

Writer(self) == Start(self) \/ Stage(self) \/ BeginClaim(self)
                   \/ WaitAcks(self) \/ Prepare(self) \/ Decide(self)
                   \/ Release(self) \/ DrainForward(self)
                   \/ DrainDelete(self)

ApplyLoop == /\ pc["applier"] = "ApplyLoop"
             /\ \E src \in Writers:
                  \E dst \in Writers:
                    /\ dst # src /\ Live(dst)
                    /\ \E c \in { x \in claims[src] : x \notin claims[dst] /\ x.w = src }:
                         /\ claims' = [claims EXCEPT ![dst] = claims[dst] \cup { c }]
                         /\ ap_dst' = dst
                         /\ ap_ct' = c.t
                         /\ ap_defer' = (\E own \in claims'[dst] : own.w = dst /\ own.t < c.t)
             /\ pc' = [pc EXCEPT !["applier"] = "ApplyEmit"]
             /\ UNCHANGED << next_ticket, acks, deferred, iceberg, decision, 
                             crashed, crash_budget, my_ticket, parent_seen, 
                             parent_staged >>

ApplyEmit == /\ pc["applier"] = "ApplyEmit"
             /\ IF (IF SafeAcks
                      THEN \E own \in claims[ap_dst] : own.w = ap_dst /\ own.t < ap_ct
                      ELSE ap_defer)
                   THEN /\ deferred' = (deferred \cup { <<ap_dst, ap_ct>> })
                        /\ acks' = acks
                   ELSE /\ acks' = (acks \cup { <<ap_ct, ap_dst>> })
                        /\ UNCHANGED deferred
             /\ pc' = [pc EXCEPT !["applier"] = "ApplyLoop"]
             /\ UNCHANGED << next_ticket, claims, iceberg, decision, crashed, 
                             crash_budget, my_ticket, parent_seen, 
                             parent_staged, ap_dst, ap_ct, ap_defer >>

Applier == ApplyLoop \/ ApplyEmit

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
             /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                             decision, my_ticket, parent_seen, parent_staged, 
                             ap_dst, ap_ct, ap_defer >>

Crasher == CrashLoop

Next == Applier \/ Crasher
           \/ (\E self \in Writers: Writer(self))

Spec == /\ Init /\ [][Next]_vars
        /\ \A self \in Writers : WF_vars(Writer(self))
        /\ WF_vars(Applier)
        /\ WF_vars(Crasher)

\* END TRANSLATION

WriterSymmetry == Permutations(Writers)

=============================================================================
