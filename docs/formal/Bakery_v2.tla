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
(*   1. Writer inserts claim into its NODE's claims view.  Replicates via  *)
(*      Apply (async).                                                     *)
(*   2. Each peer node, on applying the claim, DECIDES then WRITES (two    *)
(*      steps, faithful to the non-atomic SQL -- see SafeAcks):            *)
(*       - own pending claim with SMALLER ticket -> DEFER the ack          *)
(*         (queue in `deferred`); otherwise ack immediately.               *)
(*   3. Writer waits until every alive peer node has acked.                *)
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
(* SAME-NODE SERIALIZATION -- modelled directly by NodeParts + SameNodeLock.*)
(* NodeParts partitions writers into nodes (many writers MAY share one), so *)
(* claims are keyed by NODE and a writer clears the bakery only when BOTH   *)
(* smallest active claim on its own node (clause a) AND acked by every peer *)
(* node (clause b, Ricart-Agrawala). SameNodeLock models                   *)
(* coldfront._claim_iceberg_lock: TRUE holds a node-local advisory xact     *)
(* lock so at most one same-node writer is in the bakery at a time. With it *)
(* FALSE, two same-node claims a1<a2 below a peer's b1 coexist and the      *)
(* ack-forward on a1's Release clears b1 while a2 still holds -- a and b     *)
(* both commit, racing the CAS. Bakery_v2_samenode_race.cfg proves that     *)
(* violates NoLakekeeperConflict; Bakery_v2_samenode.cfg proves the lock    *)
(* restores safety by collapsing it to the one-claim-per-node topology.     *)
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
          NodeParts,      \* partition of Writers into nodes -- each element is the
                          \* set of writers on one node (a PG instance runs many
                          \* concurrent cold sessions). All-singletons (one writer
                          \* per node) reduces to v1's topology.
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
          SafeAcks,       \* TRUE = the SAFE implementation of R-A's defer/ack: the
                          \* defer is written atomically with a re-check of R-A's own
                          \* rule (the smaller-ticket claim must STILL be held), so a
                          \* deferral is never written behind a released claim, and the
                          \* drain can't drop it. FALSE = the non-atomic implementation
                          \* (decide, then separately write) that drops acks — the bug.
                          \* The PROTOCOL (R-A) is identical either way; only the
                          \* implementation's atomicity differs.
          SameNodeLock    \* coldfront._claim_iceberg_lock's node-local advisory xact
                          \* lock: TRUE = at most ONE cold writer per node is in the
                          \* bakery at a time (the deployment fix). FALSE = same-node
                          \* writers race; with two same-node claims a1<a2 both below a
                          \* peer's b1, node A defers b1 behind its SMALLEST same-node
                          \* claim (a1) and, on a1's Release, forwards A's ack for b1
                          \* WITHOUT re-deferring behind a2 (still held, still < b1) —
                          \* so a2 and b1 both clear the bakery and race the CAS.

ASSUME /\ Writers # {}
       /\ Writers = UNION NodeParts
       /\ \A S, T \in NodeParts : S = T \/ S \cap T = {}
       /\ MaxTickets    \in Nat /\ MaxTickets    >= Cardinality(Writers)
       /\ MaxIcebergLen \in Nat /\ MaxIcebergLen >= 1
       /\ MaxCrashes    \in Nat /\ MaxCrashes    <= Cardinality(Writers)
       /\ AsyncParquet  \in BOOLEAN
       /\ RestampPatch  \in BOOLEAN
       /\ SafeAcks      \in BOOLEAN
       /\ SameNodeLock  \in BOOLEAN

NoTicket == 0
NoSnap   == 0
Nodes    == NodeParts
Nd(w)    == CHOOSE nd \in NodeParts : w \in nd
MinT(S)  == CHOOSE m \in S : \A x \in S : m <= x

(*--algorithm Bakery_v2
variables
  next_ticket = 1,

  \* Per-NODE LOCAL view of coldfront.claims.  Writers on the same node
  \* share one view (one PG instance, one claims table); asymmetric apply
  \* across nodes is the realistic spock behaviour, and R-A's deferred-ack
  \* mechanism compensates by gating min-equivalent on per-peer-node acks.
  claims = [nd \in Nodes |-> {}],

  \* Acks received per ticket.  A pair <<t, nd>> in `acks` means peer NODE
  \* nd has acked the claim with ticket t.  Models coldfront.claim_acks
  \* (on the originator side, fully populated via spock replication of
  \* peer-emitted ack rows).
  acks = {},

  \* Deferred acks: a triple <<nd, t, behind>> means node nd queued an
  \* ack-for-ticket-t that it fires when the same-node claim `behind` is
  \* released.  Models coldfront.deferred_acks: the code keys the deferral
  \* to the SMALLEST same-node pending claim, so a `behind` that releases
  \* while a larger same-node claim below t still holds forwards too early.
  deferred = {},

  iceberg = << [w |-> 0, t |-> 0, parent |-> 0, kind |-> "prime"] >>,

  decision    = [w \in Writers |-> "none"],
  crashed     = [w \in Writers |-> FALSE],
  crash_budget = MaxCrashes;

define
  Live(w)        == ~ crashed[w]
  IcebergHead    == Len(iceberg)

  \* A node is alive if any of its writers is alive (a node is one PG
  \* instance; its concurrent cold sessions crash with it).  A node `nd` is
  \* the set of its writers.
  NodeLive(nd)   == \E w \in nd : ~ crashed[w]

  \* Clause (b) of R-A: every alive peer NODE (excluding my own) has acked
  \* ticket t.  The `~ NodeLive(nd)` shortcut is the failure-detector
  \* clause: a crashed node's missing ack does not block progress.  In the
  \* real system this combines claim_acks with a heartbeat-staleness check
  \* (pg_stat_replication.reply_time) so dead nodes are treated as
  \* already-acked -- closing the classic R-A weakness where a crashed
  \* peer's deferred ack would strand survivors forever.
  AllPeerNodesAcked(self, t) ==
    \A nd \in Nodes :
      nd = Nd(self) \/ ~ NodeLive(nd) \/ <<t, nd>> \in acks

  \* Clause (a): no OTHER active claim on my own node has a smaller ticket
  \* -- same-node writers commit smallest-ticket-first.  Vacuous when one
  \* writer per node (there is no other same-node claim).
  SmallestOnMyNode(self, t) ==
    ~ \E x \in claims[Nd(self)] : x.n = Nd(self) /\ x.w # self /\ x.t < t

  \* Peer-node deferrals queued BEHIND my claim (ticket t) that my Release
  \* forwards into acks.
  MyForwardable(self, t) ==
    { d \in deferred : d[1] = Nd(self) /\ d[3] = t }

  \* Safety properties (all HOLD in v2).
  NoLakekeeperConflict ==
    \A w \in Writers : decision[w] # "lk_409"

  RollbackNoIceberg ==
    \A w \in Writers :
      decision[w] = "rolled_back" =>
        ~ \E i \in 1..Len(iceberg) : iceberg[i].w = w

  UniqueTickets ==
    \A p, q \in Nodes :
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
    \* Insert claim into my NODE's local view.  Async replication via Applier.
    \* No sync rep — R-A's ack barrier replaces it.  The SameNodeLock guard is
    \* coldfront._claim_iceberg_lock's node-local advisory xact lock: block
    \* while another writer on my node is mid-claim, so at most one same-node
    \* claim is in the bakery at a time (node-local, so instant/synchronous).
    await Live(self) /\ \E p \in Writers : p # self /\ Live(p);
    await next_ticket <= MaxTickets;
    await (~ SameNodeLock)
          \/ ~ \E x \in claims[Nd(self)] : x.n = Nd(self) /\ x.w # self;
    my_ticket := next_ticket;
    next_ticket := next_ticket + 1;
    claims[Nd(self)] := claims[Nd(self)] \cup
                        {[w |-> self, t |-> my_ticket, n |-> Nd(self)]};

  WaitAcks:
    \* Clear the bakery when I am BOTH the smallest active claim on my own node
    \* (clause a) AND acked by every alive peer node (clause b).  Peer nodes ack
    \* either immediately (no smaller-ticket pending claim there) or via the
    \* deferred-drain fired by the smaller-ticket holder at its Release.
    await Live(self)
          /\ SmallestOnMyNode(self, my_ticket)
          /\ AllPeerNodesAcked(self, my_ticket);

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
    \* The C XactCallback's claim DELETE: remove my claim from every node view.
    await Live(self);
    claims := [nd \in Nodes |->
                claims[nd] \ {[w |-> self, t |-> my_ticket, n |-> Nd(self)]}];

  DrainForward:
    \* _on_claim_release step 1 (forward): INSERT claim_acks SELECT … FROM
    \* deferred_acks WHERE pending = my ticket — forward the peer-node acks
    \* queued behind MY claim.  A deferral the Applier writes AFTER this read
    \* but BEFORE DrainDelete is NOT seen here.  With SameNodeLock FALSE this
    \* is the same-node race: if a same-node claim below the deferred ticket
    \* still holds, forwarding here clears that peer node too early.
    await Live(self);
    acks := acks \cup { <<d[2], Nd(self)>> : d \in MyForwardable(self, my_ticket) };

  DrainDelete:
    \* _on_claim_release step 2 (the SEPARATE DELETE): delete the deferrals I
    \* forwarded — including any inserted in the DrainForward→here window, which
    \* were never forwarded.  Non-atomic forward-then-delete = the dropped ack.
    await Live(self);
    deferred := { x \in deferred : ~ (x[1] = Nd(self) /\ x[3] = my_ticket) };
end process;

(*-----------------------------------------------------------------------*)
(* Applier — propagates INSERTs between local views (asymmetric apply).  *)
(* At apply time, the R-A defer-or-ack decision is made.                 *)
(*-----------------------------------------------------------------------*)
fair process Applier = "applier"
variables ap_dst = NoTicket, ap_ct = NoTicket, ap_defer = FALSE,
          ap_behind = NoTicket;
begin
  ApplyLoop:
    while TRUE do
      \* ApplyDecide — apply one claim from a src NODE into a dst NODE's local
      \* view and DECIDE, under the read snapshot, whether to defer or ack.
      \* Mirrors _on_claim_apply reading coldfront.claims (the shared advisory
      \* lock is dropped after this SELECT) and CHOOSING defer-vs-ack — but NOT
      \* yet writing it.  ap_behind is the smallest same-node pending claim the
      \* deferral keys to (ORDER BY ticket LIMIT 1 in the SQL).
      with src \in Nodes, dst \in Nodes do
        await dst # src /\ NodeLive(dst);
        with c \in { x \in claims[src] : x \notin claims[dst] /\ x.n = src } do
          claims[dst] := claims[dst] \cup { c };
          ap_dst   := dst;
          ap_ct    := c.t;
          ap_defer := \E own \in claims[dst] : own.n = dst /\ own.t < c.t;
          ap_behind := IF \E own \in claims[dst] : own.n = dst /\ own.t < c.t
                         THEN MinT({ own.t : own \in
                               {y \in claims[dst] : y.n = dst /\ y.t < c.t} })
                         ELSE NoTicket;
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
            THEN \E own \in claims[ap_dst] : own.n = ap_dst /\ own.t < ap_ct
            ELSE ap_defer)
      then
        deferred := deferred \cup { <<ap_dst, ap_ct, ap_behind>> };
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
\* BEGIN TRANSLATION (chksum(pcal) = "31d6d69e" /\ chksum(tla) = "3f1a640d")
VARIABLES pc, next_ticket, claims, acks, deferred, iceberg, decision, crashed, 
          crash_budget

(* define statement *)
Live(w)        == ~ crashed[w]
IcebergHead    == Len(iceberg)




NodeLive(nd)   == \E w \in nd : ~ crashed[w]








AllPeerNodesAcked(self, t) ==
  \A nd \in Nodes :
    nd = Nd(self) \/ ~ NodeLive(nd) \/ <<t, nd>> \in acks




SmallestOnMyNode(self, t) ==
  ~ \E x \in claims[Nd(self)] : x.n = Nd(self) /\ x.w # self /\ x.t < t



MyForwardable(self, t) ==
  { d \in deferred : d[1] = Nd(self) /\ d[3] = t }


NoLakekeeperConflict ==
  \A w \in Writers : decision[w] # "lk_409"

RollbackNoIceberg ==
  \A w \in Writers :
    decision[w] = "rolled_back" =>
      ~ \E i \in 1..Len(iceberg) : iceberg[i].w = w

UniqueTickets ==
  \A p, q \in Nodes :
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

VARIABLES my_ticket, parent_seen, parent_staged, ap_dst, ap_ct, ap_defer, 
          ap_behind

vars == << pc, next_ticket, claims, acks, deferred, iceberg, decision, 
           crashed, crash_budget, my_ticket, parent_seen, parent_staged, 
           ap_dst, ap_ct, ap_defer, ap_behind >>

ProcSet == (Writers) \cup {"applier"} \cup {"crasher"}

Init == (* Global variables *)
        /\ next_ticket = 1
        /\ claims = [nd \in Nodes |-> {}]
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
        /\ ap_behind = NoTicket
        /\ pc = [self \in ProcSet |-> CASE self \in Writers -> "Start"
                                        [] self = "applier" -> "ApplyLoop"
                                        [] self = "crasher" -> "CrashLoop"]

Start(self) == /\ pc[self] = "Start"
               /\ Live(self)
               /\ pc' = [pc EXCEPT ![self] = "Stage"]
               /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                               decision, crashed, crash_budget, my_ticket, 
                               parent_seen, parent_staged, ap_dst, ap_ct, 
                               ap_defer, ap_behind >>

Stage(self) == /\ pc[self] = "Stage"
               /\ Live(self)
               /\ IF AsyncParquet
                     THEN /\ parent_staged' = [parent_staged EXCEPT ![self] = IcebergHead]
                     ELSE /\ TRUE
                          /\ UNCHANGED parent_staged
               /\ pc' = [pc EXCEPT ![self] = "BeginClaim"]
               /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                               decision, crashed, crash_budget, my_ticket, 
                               parent_seen, ap_dst, ap_ct, ap_defer, ap_behind >>

BeginClaim(self) == /\ pc[self] = "BeginClaim"
                    /\ Live(self) /\ \E p \in Writers : p # self /\ Live(p)
                    /\ next_ticket <= MaxTickets
                    /\ (~ SameNodeLock)
                       \/ ~ \E x \in claims[Nd(self)] : x.n = Nd(self) /\ x.w # self
                    /\ my_ticket' = [my_ticket EXCEPT ![self] = next_ticket]
                    /\ next_ticket' = next_ticket + 1
                    /\ claims' = [claims EXCEPT ![Nd(self)] = claims[Nd(self)] \cup
                                                              {[w |-> self, t |-> my_ticket'[self], n |-> Nd(self)]}]
                    /\ pc' = [pc EXCEPT ![self] = "WaitAcks"]
                    /\ UNCHANGED << acks, deferred, iceberg, decision, crashed, 
                                    crash_budget, parent_seen, parent_staged, 
                                    ap_dst, ap_ct, ap_defer, ap_behind >>

WaitAcks(self) == /\ pc[self] = "WaitAcks"
                  /\ Live(self)
                     /\ SmallestOnMyNode(self, my_ticket[self])
                     /\ AllPeerNodesAcked(self, my_ticket[self])
                  /\ pc' = [pc EXCEPT ![self] = "Prepare"]
                  /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                                  decision, crashed, crash_budget, my_ticket, 
                                  parent_seen, parent_staged, ap_dst, ap_ct, 
                                  ap_defer, ap_behind >>

Prepare(self) == /\ pc[self] = "Prepare"
                 /\ Live(self)
                 /\ IF ~ AsyncParquet \/ RestampPatch
                       THEN /\ parent_seen' = [parent_seen EXCEPT ![self] = IcebergHead]
                       ELSE /\ parent_seen' = [parent_seen EXCEPT ![self] = parent_staged[self]]
                 /\ pc' = [pc EXCEPT ![self] = "Decide"]
                 /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                                 decision, crashed, crash_budget, my_ticket, 
                                 parent_staged, ap_dst, ap_ct, ap_defer, 
                                 ap_behind >>

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
                                parent_staged, ap_dst, ap_ct, ap_defer, 
                                ap_behind >>

Release(self) == /\ pc[self] = "Release"
                 /\ Live(self)
                 /\ claims' = [nd \in Nodes |->
                                claims[nd] \ {[w |-> self, t |-> my_ticket[self], n |-> Nd(self)]}]
                 /\ pc' = [pc EXCEPT ![self] = "DrainForward"]
                 /\ UNCHANGED << next_ticket, acks, deferred, iceberg, 
                                 decision, crashed, crash_budget, my_ticket, 
                                 parent_seen, parent_staged, ap_dst, ap_ct, 
                                 ap_defer, ap_behind >>

DrainForward(self) == /\ pc[self] = "DrainForward"
                      /\ Live(self)
                      /\ acks' = (acks \cup { <<d[2], Nd(self)>> : d \in MyForwardable(self, my_ticket[self]) })
                      /\ pc' = [pc EXCEPT ![self] = "DrainDelete"]
                      /\ UNCHANGED << next_ticket, claims, deferred, iceberg, 
                                      decision, crashed, crash_budget, 
                                      my_ticket, parent_seen, parent_staged, 
                                      ap_dst, ap_ct, ap_defer, ap_behind >>

DrainDelete(self) == /\ pc[self] = "DrainDelete"
                     /\ Live(self)
                     /\ deferred' = { x \in deferred : ~ (x[1] = Nd(self) /\ x[3] = my_ticket[self]) }
                     /\ pc' = [pc EXCEPT ![self] = "Done"]
                     /\ UNCHANGED << next_ticket, claims, acks, iceberg, 
                                     decision, crashed, crash_budget, 
                                     my_ticket, parent_seen, parent_staged, 
                                     ap_dst, ap_ct, ap_defer, ap_behind >>

Writer(self) == Start(self) \/ Stage(self) \/ BeginClaim(self)
                   \/ WaitAcks(self) \/ Prepare(self) \/ Decide(self)
                   \/ Release(self) \/ DrainForward(self)
                   \/ DrainDelete(self)

ApplyLoop == /\ pc["applier"] = "ApplyLoop"
             /\ \E src \in Nodes:
                  \E dst \in Nodes:
                    /\ dst # src /\ NodeLive(dst)
                    /\ \E c \in { x \in claims[src] : x \notin claims[dst] /\ x.n = src }:
                         /\ claims' = [claims EXCEPT ![dst] = claims[dst] \cup { c }]
                         /\ ap_dst' = dst
                         /\ ap_ct' = c.t
                         /\ ap_defer' = (\E own \in claims'[dst] : own.n = dst /\ own.t < c.t)
                         /\ ap_behind' = (IF \E own \in claims'[dst] : own.n = dst /\ own.t < c.t
                                            THEN MinT({ own.t : own \in
                                                  {y \in claims'[dst] : y.n = dst /\ y.t < c.t} })
                                            ELSE NoTicket)
             /\ pc' = [pc EXCEPT !["applier"] = "ApplyEmit"]
             /\ UNCHANGED << next_ticket, acks, deferred, iceberg, decision, 
                             crashed, crash_budget, my_ticket, parent_seen, 
                             parent_staged >>

ApplyEmit == /\ pc["applier"] = "ApplyEmit"
             /\ IF (IF SafeAcks
                      THEN \E own \in claims[ap_dst] : own.n = ap_dst /\ own.t < ap_ct
                      ELSE ap_defer)
                   THEN /\ deferred' = (deferred \cup { <<ap_dst, ap_ct, ap_behind>> })
                        /\ acks' = acks
                   ELSE /\ acks' = (acks \cup { <<ap_ct, ap_dst>> })
                        /\ UNCHANGED deferred
             /\ pc' = [pc EXCEPT !["applier"] = "ApplyLoop"]
             /\ UNCHANGED << next_ticket, claims, iceberg, decision, crashed, 
                             crash_budget, my_ticket, parent_seen, 
                             parent_staged, ap_dst, ap_ct, ap_defer, ap_behind >>

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
                             ap_dst, ap_ct, ap_defer, ap_behind >>

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
