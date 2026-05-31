# Failover & promotion — delegated to Patroni

ColdFront does **not** automate failover, promotion, or (for mesh nodes) Spock
re-integration. That is the job of an operational HA layer — **Patroni** — and it
is deliberately out of scope for the ColdFront test matrix. The matrix verifies
only that a **physical standby serves reads correctly** (`ci/probe-standby.sh` is
the risk gate; the `*·standby` cells exercise it in the journey). What happens
*after* Patroni promotes a replica is a Patroni concern, and no promotion tests
are built.

This runbook records the one requirement ColdFront places on the HA layer, and
two limitations operators must account for.

## The one requirement: coldfront GUCs in `postgresql.conf`, not `ALTER SYSTEM`

Everything a promoted node needs to serve cold reads/writes must survive a base
backup and a promotion:

- **`coldfront.warehouse`, `coldfront.lakekeeper_endpoint`, `coldfront.local_pg_dsn`**
  (and, on mesh nodes, `coldfront.dblink_self`) belong in `postgresql.conf` — the
  ColdFront image entrypoint writes them there. They then ride a `pg_basebackup`
  to every replica and remain in force after promotion. Avoid `ALTER SYSTEM` for
  these: it works (`postgresql.auto.conf` also rides a base backup) but splitting
  config across two files is how nodes drift.
- **The DuckDB S3 secret** is a `pg_foreign_server` row (created by
  `duckdb.create_simple_secret`). It lives in the catalog, so it is **physically
  replicated** to every standby and present immediately on promotion — no
  re-creation step.
- **The coldfront catalog** (`coldfront.tiered_views`, `coldfront.archive_watermark`,
  `coldfront.runtime_config`) is ordinary table data → physically replicated,
  byte-identical (same OIDs) on every replica.

A consequence (documented, not tested): a **vanilla** promotion "just works." The
secret rides physical replication, and vanilla cold writes serialise on a
node-local advisory lock, so a freshly promoted single node needs no coordination
state to begin accepting writes.

## Limitation 1 — Iceberg reads on a replica are snapshot-consistent, not linearizable

A hot standby's `iceberg_scan` reads whatever Iceberg snapshot Lakekeeper points
at when the query starts. While the **primary** archives new data or commits cold
writes, a replica's in-flight read does not observe the concurrent commit — it
sees the snapshot resolved at query start. This is ordinary Iceberg snapshot
isolation, not a ColdFront bug, but operators serving reads from replicas should
know cold-tier reads are **snapshot-consistent, not linearizable** with primary
cold writes.

## Limitation 2 — split-brain cold writes during a network partition

The Ricart–Agrawala bakery that serialises mesh cold writes has a **dead-peer
escape**: if a peer is unreachable, a writer proceeds rather than block forever
(availability over a hard stall). During a genuine **network partition** both
sides can therefore each consider the other dead and **both write the same
Iceberg table** — a split-brain cold write the Iceberg commit layer will not
reconcile.

ColdFront cannot prevent this from inside a partition; the mitigation is
**Patroni fencing** — the losing side must be fenced (demoted/stopped) before the
winning side accepts writes, so only one partition ever holds the writer role.
