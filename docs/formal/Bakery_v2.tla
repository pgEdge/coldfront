------------------------------ MODULE Bakery_v2 -----------------------------
(***************************************************************************)
(* v2 of the decoupled-mode bakery model.  Where v1 abstracted              *)
(* `coldfront.claims` as a globally-consistent set, v2 models the           *)
(* real-world asymmetry of Spock replication (each writer has its own       *)
(* local view; INSERTs propagate via an explicit Apply step) AND adds the   *)
(* Ricart-Agrawala (1981) optimisation of Lamport's 1978 distributed       *)
(* mutual exclusion algorithm to compensate for that asymmetry.            *)
(*                                                                         *)
(* Protocol:                                                                *)
(*   1. Writer inserts claim into its own claims[w].  Replicates via Apply *)
(*      (async).                                                            *)
(*   2. Each peer, on applying my claim, decides:                           *)
(*       - If peer has an own pending claim with SMALLER ticket, peer      *)
(*         DEFERS the ack (queues it for later).                            *)
(*       - Otherwise (no pending, or peer's pending has LARGER ticket),    *)
(*         peer acks immediately.                                          *)
(*   3. Writer waits until every alive peer has acked.                     *)
(*   4. Writer proceeds to Decide.  No min-spin.                            *)
(*   5. On release (at Decide), writer drains its deferred-ack queue:      *)
(*      every queued ack now fires.                                        *)
(*                                                                         *)
(* Properties (all should HOLD):                                            *)
(*   - NoLakekeeperConflict  (R-A guarantees only one writer has all acks  *)
(*                            at a time per iceberg table — no concurrent  *)
(*                            CAS races)                                    *)
(*   - TicketOrderPreserved  (R-A delivers FIFO order by snowflake ticket) *)
(*   - RollbackNoIceberg                                                    *)
(*   - UniqueTickets                                                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Writers,
          MaxTickets,
          MaxIcebergLen,
          MaxCrashes

ASSUME /\ Writers # {}
       /\ MaxTickets    \in Nat /\ MaxTickets    >= Cardinality(Writers)
       /\ MaxIcebergLen \in Nat /\ MaxIcebergLen >= 1
       /\ MaxCrashes    \in Nat /\ MaxCrashes    <= Cardinality(Writers)

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
end define;

fair process Writer \in Writers
variables
  my_ticket = NoTicket,
  parent_seen = NoSnap;
begin
  Start:
    await Live(self);

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
    await Live(self);
    parent_seen := IcebergHead;

  Decide:
    await Live(self);
    either
      \* COMMIT.  Under R-A, when all my acks are in, no other writer
      \* with a smaller ticket is past their WaitAcks — so the iceberg
      \* head can't have advanced since Prepare.  CAS always succeeds.
      if IcebergHead = parent_seen then
        iceberg := Append(iceberg,
                          [w |-> self, t |-> my_ticket,
                           parent |-> parent_seen, kind |-> "commit"]);
        decision[self] := "committed";
      else
        decision[self] := "lk_409";
      end if;
      \* Release: remove my claim from every local view AND drain my
      \* deferred acks.  R-A's "send queued REPLYs on exit."
      claims := [p \in Writers |->
                  claims[p] \ {[w |-> self, t |-> my_ticket, n |-> self]}];
      acks := acks \cup { <<t, self>> : t \in MyDeferredTickets(self) };
      deferred := { x \in deferred : x[1] # self };
    or
      decision[self] := "rolled_back";
      claims := [p \in Writers |->
                  claims[p] \ {[w |-> self, t |-> my_ticket, n |-> self]}];
      acks := acks \cup { <<t, self>> : t \in MyDeferredTickets(self) };
      deferred := { x \in deferred : x[1] # self };
    end either;
end process;

(*-----------------------------------------------------------------------*)
(* Applier — propagates INSERTs between local views (asymmetric apply).  *)
(* At apply time, the R-A defer-or-ack decision is made.                 *)
(*-----------------------------------------------------------------------*)
fair process Applier = "applier"
begin
  ApplyLoop:
    while TRUE do
      with src \in Writers, dst \in Writers do
        await dst # src /\ Live(dst);
        with c \in { x \in claims[src] : x \notin claims[dst] /\ x.w = src } do
          claims[dst] := claims[dst] \cup { c };
          \* R-A defer rule.
          if \E own \in claims[dst] :
                own.w = dst /\ own.t < c.t
          then
            deferred := deferred \cup { <<dst, c.t>> };
          else
            acks := acks \cup { <<c.t, dst>> };
          end if;
        end with;
      end with;
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
\* BEGIN TRANSLATION (chksum(pcal) = "50a4031a" /\ chksum(tla) = "35334207")
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

VARIABLES my_ticket, parent_seen

vars == << pc, next_ticket, claims, acks, deferred, iceberg, decision, 
           crashed, crash_budget, my_ticket, parent_seen >>

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
        /\ pc = [self \in ProcSet |-> CASE self \in Writers -> "Start"
                                        [] self = "applier" -> "ApplyLoop"
                                        [] self = "crasher" -> "CrashLoop"]

Start(self) == /\ pc[self] = "Start"
               /\ Live(self)
               /\ pc' = [pc EXCEPT ![self] = "BeginClaim"]
               /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                               decision, crashed, crash_budget, my_ticket, 
                               parent_seen >>

BeginClaim(self) == /\ pc[self] = "BeginClaim"
                    /\ Live(self) /\ \E p \in Writers : p # self /\ Live(p)
                    /\ next_ticket <= MaxTickets
                    /\ my_ticket' = [my_ticket EXCEPT ![self] = next_ticket]
                    /\ next_ticket' = next_ticket + 1
                    /\ claims' = [claims EXCEPT ![self] = claims[self] \cup
                                                          {[w |-> self, t |-> my_ticket'[self], n |-> self]}]
                    /\ pc' = [pc EXCEPT ![self] = "WaitAcks"]
                    /\ UNCHANGED << acks, deferred, iceberg, decision, crashed, 
                                    crash_budget, parent_seen >>

WaitAcks(self) == /\ pc[self] = "WaitAcks"
                  /\ Live(self) /\ AlivePeersHaveAcked(self, my_ticket[self])
                  /\ pc' = [pc EXCEPT ![self] = "Prepare"]
                  /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                                  decision, crashed, crash_budget, my_ticket, 
                                  parent_seen >>

Prepare(self) == /\ pc[self] = "Prepare"
                 /\ Live(self)
                 /\ parent_seen' = [parent_seen EXCEPT ![self] = IcebergHead]
                 /\ pc' = [pc EXCEPT ![self] = "Decide"]
                 /\ UNCHANGED << next_ticket, claims, acks, deferred, iceberg, 
                                 decision, crashed, crash_budget, my_ticket >>

Decide(self) == /\ pc[self] = "Decide"
                /\ Live(self)
                /\ \/ /\ IF IcebergHead = parent_seen[self]
                            THEN /\ iceberg' = Append(iceberg,
                                                      [w |-> self, t |-> my_ticket[self],
                                                       parent |-> parent_seen[self], kind |-> "commit"])
                                 /\ decision' = [decision EXCEPT ![self] = "committed"]
                            ELSE /\ decision' = [decision EXCEPT ![self] = "lk_409"]
                                 /\ UNCHANGED iceberg
                      /\ claims' = [p \in Writers |->
                                     claims[p] \ {[w |-> self, t |-> my_ticket[self], n |-> self]}]
                      /\ acks' = (acks \cup { <<t, self>> : t \in MyDeferredTickets(self) })
                      /\ deferred' = { x \in deferred : x[1] # self }
                   \/ /\ decision' = [decision EXCEPT ![self] = "rolled_back"]
                      /\ claims' = [p \in Writers |->
                                     claims[p] \ {[w |-> self, t |-> my_ticket[self], n |-> self]}]
                      /\ acks' = (acks \cup { <<t, self>> : t \in MyDeferredTickets(self) })
                      /\ deferred' = { x \in deferred : x[1] # self }
                      /\ UNCHANGED iceberg
                /\ pc' = [pc EXCEPT ![self] = "Done"]
                /\ UNCHANGED << next_ticket, crashed, crash_budget, my_ticket, 
                                parent_seen >>

Writer(self) == Start(self) \/ BeginClaim(self) \/ WaitAcks(self)
                   \/ Prepare(self) \/ Decide(self)

ApplyLoop == /\ pc["applier"] = "ApplyLoop"
             /\ \E src \in Writers:
                  \E dst \in Writers:
                    /\ dst # src /\ Live(dst)
                    /\ \E c \in { x \in claims[src] : x \notin claims[dst] /\ x.w = src }:
                         /\ claims' = [claims EXCEPT ![dst] = claims[dst] \cup { c }]
                         /\ IF \E own \in claims'[dst] :
                                  own.w = dst /\ own.t < c.t
                               THEN /\ deferred' = (deferred \cup { <<dst, c.t>> })
                                    /\ acks' = acks
                               ELSE /\ acks' = (acks \cup { <<c.t, dst>> })
                                    /\ UNCHANGED deferred
             /\ pc' = [pc EXCEPT !["applier"] = "ApplyLoop"]
             /\ UNCHANGED << next_ticket, iceberg, decision, crashed, 
                             crash_budget, my_ticket, parent_seen >>

Applier == ApplyLoop

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
                             decision, my_ticket, parent_seen >>

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
