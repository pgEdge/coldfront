# Configuring a Distributed Deployment

For workloads in which multiple nodes write to Iceberg tables, run ColdFront on
PostgreSQL nodes in a Spock mesh that share one Lakekeeper catalog and one
object store. ColdFront's bakery protocol serializes Iceberg commits within
PostgreSQL, so concurrent writers never conflict at the catalog.

## Before You Begin

Before you configure the mesh, make sure that every node meets the following
requirements:

- PostgreSQL and ColdFront are installed and configured as described in
  [Installing ColdFront](installation.md) and
  [Configuring PostgreSQL](configuration.md#configuring-postgresql).
- The Spock and Snowflake extensions are installed. pgEdge Enterprise Postgres
  and the ColdFront Docker image include both; on bare metal, install
  [Spock](https://docs.pgedge.com/spock-v5/v5-0-14/install_spock/) and
  [Snowflake](https://docs.pgedge.com/snowflake/) before you continue.
- The node uses the same Lakekeeper warehouse and object store as every other
  node, so `coldfront.warehouse` and `coldfront.lakekeeper_endpoint` have the
  same values on every node. Lakekeeper is bootstrapped as described in
  [Configuring Lakekeeper](configure_lakekeeper.md), runs on its own
  PostgreSQL server rather than on a mesh node, and the warehouse and its
  namespace exist as described in
  [Configuring your Object Store](object_store.md).

The mesh also depends on the following:

- Each node can reach every other node's PostgreSQL port, and the role in the
  subscription connection strings (`coldfront` in the examples) can connect to
  every peer.
- Each node can reach itself over a Unix socket without a password, for
  `coldfront.loopback_dsn`.
- The database has the same name on every node (`coldfront` in the examples).
- You must ensure that the nodes' clocks are synchronized with NTP, because the
  peer liveness window described in [Timeouts](#timeouts) also covers the clock
  skew between nodes.

## Updating the postgresql.conf File on Each Node

Each node needs the mesh settings below in `postgresql.conf`, alongside the
ColdFront settings from
[Configuring PostgreSQL](configuration.md#configuring-postgresql). When you
add them:

- Replace the single-node `shared_preload_libraries` value.
- Give `snowflake.node` a different value on each node.
- Restart PostgreSQL on each node afterward; `shared_preload_libraries` and
  `wal_level` take effect only at server start.

!!! hint

    On Docker, the ColdFront entrypoint writes these settings for you. Start
    each node container with `MESH=on` and a distinct
    `COLDFRONT_SNOWFLAKE_NODE`; the [Installing ColdFront](installation.md)
    guide lists both environment variables.

Ensure that the following parameters are set on each node of the replication
mesh:

```ini
wal_level = logical
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'

# The bakery rules a peer dead when its walsender's last reply is older than
# coldfront.peer_alive_window_ms (default 10 s), and an idle peer replies only
# to the walsender's keepalive, every wal_sender_timeout/2. The claim refuses
# to run unless wal_sender_timeout is positive and below twice the window.
wal_sender_timeout = 15s

# Spock prereq + DDL replication. The ddl_sql repset (and with it the
# one-node provisioning promise for wrapper views) only works with DDL
# replication on; allow_ddl_from_functions covers DDL issued inside
# coldfront's plpgsql helpers.
track_commit_timestamp = on
spock.enable_ddl_replication = on
spock.allow_ddl_from_functions = on
spock.include_ddl_repset = on

# Only on a server that has this setting (PostgreSQL 16.15, 17.11 and 18.6 in
# pgEdge's builds):
# it lists the libraries allowed as logical decoding output plugins, and its
# default leaves out Spock's, so no subscription can create its slot. A server
# without the setting refuses to start with this line in place.
output_plugin_libraries = 'pgoutput, test_decoding, spock_output'

# Per-node - any distinct integer 1..1023 (must be unique per node; the value
# is otherwise arbitrary - the bakery matches acks by spock node name, not by id).
snowflake.node = 1

# DSN of the node's loopback, which runs the bakery's autonomous claim
# INSERT/DELETE. It must name a unix socket: every onboarded role can read
# this setting, so it must never need a password. The claim session only
# touches the coldfront.claims/claim_acks heap tables, so it never attaches
# the Iceberg catalog (the lazy catalog-attach hook fires only on a tiered
# view). application_name=coldfront_loopback marks the session as bakery
# traffic. Only a superuser can set it.
coldfront.loopback_dsn = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_loopback'

coldfront.warehouse = 'wh'
coldfront.lakekeeper_endpoint = 'http://lakekeeper:8181/catalog'

# Upload the Parquet outside the bakery claim and serialize only the catalog
# commit. Set both, and only where duckdb-iceberg includes ColdFront's patch (the
# ColdFront image does). With either off, the upload is serialized too.
coldfront.iceberg_async_parquet = on
coldfront.iceberg_bakery_patch = on
```

## Forming the Mesh

Form the mesh in four stages. Finish each stage on every node before you start
the next one, because each stage depends on the previous stage having run
everywhere:

1. On every node, create the extensions in dependency order. ColdFront's
    bakery needs `snowflake`, because its claim tickets come from
    `snowflake.nextval`:

    ```sql
    CREATE EXTENSION IF NOT EXISTS snowflake;
    CREATE EXTENSION IF NOT EXISTS spock;
    CREATE EXTENSION IF NOT EXISTS pg_duckdb;
    CREATE EXTENSION IF NOT EXISTS coldfront;
    ```

2. On every node, create the node's Spock node. The node names are yours to
    choose; for example, on `n1`:

    ```sql
    SELECT spock.node_create('n1', 'host=<this_node_priv_ip> user=coldfront dbname=coldfront port=5432');
    ```

    A subscription can be created only after its provider is a Spock node, so
    create every node before any subscription.

3. On every node, create one subscription to each other node, so that each
    node has N-1 subscriptions in a full mesh. For example, on `n1` in a
    three-node mesh (`n2` and `n3` are symmetric):

    ```sql
    SELECT spock.sub_create('sub_n1_from_n2', 'host=<n2> user=coldfront dbname=coldfront port=5432',
                            ARRAY['default','default_insert_only','ddl_sql'],
                            false, false, '{}', '0', false);
    SELECT spock.sub_create('sub_n1_from_n3', 'host=<n3> user=coldfront dbname=coldfront port=5432',
                            ARRAY['default','default_insert_only','ddl_sql'],
                            false, false, '{}', '0', false);
    ```

    Each subscription sets the following arguments:

    - `ARRAY['default','default_insert_only','ddl_sql']` subscribes to the
      replication sets that carry ColdFront's tables and the replicated DDL.
    - The first `false` (`synchronize_structure`) and second `false`
      (`synchronize_data`) skip the initial copy, because the `coldfront`
      extension already created the tables on every node.
    - `'{}'` (`forward_origins`), `'0'` (`apply_delay`), and the final `false`
      (`force_text_transfer`) keep Spock's defaults.

4. When every node's subscriptions exist, run `coldfront.ensure_replicated()`
    on every node, before the first cold write, storage secret, or table
    registration. The call adds every ColdFront table that replicates by value
    to this node's replication sets, and publishes the slot name of each of
    this node's subscriptions. Because the subscriptions skip the initial
    copy, a peer that subscribes after a node runs the call never receives
    the slot names that node published, so create every subscription first.
    Run the call again on a node whose subscriptions change:

    ```sql
    SELECT coldfront.ensure_replicated();
    ```

## How the Bakery Handles Peers

The bakery has no peer-ack timeout. The
[Ricart-Agrawala (R-A)](formal/README.md) deferred-reply protocol's only
failure mode is a dead peer (would wait forever), and a liveness check
inside the wait loop closes it:
the bakery treats a peer whose `pg_stat_replication.reply_time` is older than
`coldfront.peer_alive_window_ms` as already acked, whatever the walsender's
state (a peer that has just reconnected is catching up and still alive). The
peer's apply worker sends that reply after it applies, every
`spock.feedback_frequency` messages, and in answer to the walsender's
keepalive; `wal_receiver_status_interval` plays no part, since Spock's apply
worker does not read it. The window and `wal_sender_timeout` go together; set
them as [Timeouts](#timeouts) below describes. An alive peer that has
not acked is either deferring legitimately (R-A's defer rule) or about to
ack, and waiting for it is correct, not a failure.

A claim whose owner is gone (a hard backend crash) is reaped without operator
action: by that node's next cold write, to any table, by a peer's arriving
claim, or by the waiting peer's poke, a no-op `UPDATE` of its own claim row
about once a second for as long as it waits. That poke is the only replication
traffic the bakery generates while a writer waits, and there is none when
nothing waits. See *Orphan reaping* in
[The Bakery Protocol](architecture_decoupled.md#concurrency-horizontal-scaling-the-bakery-protocol).

Sync-rep (`synchronous_standby_names`) is **not required** by the bakery - the
R-A ack barrier (the wait, before a claim commits, for every live peer to
acknowledge it) is what serializes iceberg commits. You can still enable
sync-rep cluster-wide if you want stronger durability for non-bakery writes,
but it plays no part in iceberg-commit serialization.

## Timeouts

The following table lists the two `postgresql.conf` settings that decide
how long a cold write waits for a peer; set them together, on every node:

| Setting | Notes |
|---|---|
| `wal_sender_timeout` | Recommended `15s`, set in `postgresql.conf` on every node (the image sets it if you are running in mesh mode). The node's walsender asks each peer for a reply after half of it (7.5 s) and drops a peer that has not replied for the whole of it. |
| `coldfront.peer_alive_window_ms` | Recommended `10000` (the default), set in `postgresql.conf`, by a superuser only. The bakery treats a peer whose last reply is older than this as dead and stops waiting for its ack. |

The rule: half of `wal_sender_timeout` must stay below the window, with a
round trip to spare; the claim enforces the first part. The reply's time is
the peer's clock, so the window also covers the clock skew between nodes. An
idle peer replies
only when the walsender asks, so the
PostgreSQL default of 60 s against a 10 s window would rule a live idle peer
dead; a claim refuses to run with such settings and names both. With the
recommended values a writer waits at most 10 s for a peer that is really
dead, and the walsender disconnects a peer silent for 15 s, which then
reconnects on its own.

On a slow or lossy WAN raise both together and keep the rule, for example
`wal_sender_timeout = 30s` with `coldfront.peer_alive_window_ms = 20000`.
Both take effect on a reload (`ALTER SYSTEM SET ...;` then
`SELECT pg_reload_conf();`), no restart: walsenders re-read the timeout, and
each claim reads the window once.

## What `coldfront.ensure_replicated()` Does

The call is the one ColdFront-specific step of the mesh setup. It adds nine
tables to the node's replication sets (`claim_acks` to `default_insert_only`,
the rest to `default`), each keyed by name, so a row is identical on every node
and replicates by value, and it replaces this node's rows of
`coldfront.peer_slots` with one per row of `spock.subscription`:

| Table | What replicates, and why a peer needs it |
|---|---|
| `coldfront.claims`, `coldfront.claim_acks` | The bakery's tickets and acknowledgements. A peer acknowledges an originator's claim by inserting into `claim_acks` on its own node, and the ack reaches the originator only if the table is in the peer's set. `claim_acks` goes in the insert-only set, because each node deletes only the ack copies it holds. |
| `coldfront.peer_slots` | For each provider, the slot name of the node's subscription that carries the provider's claims (its sets include `default`), keyed by subscriber and provider node name. Spock sets that name as the `application_name` of the walsender that serves the subscription, so a provider's bakery finds the walsender of each peer by the name the peer published, and a subscription can have any name. |
| `coldfront.tiered_views` | The registry. A peer's hook recognizes a view by its row; without it the peer's writes through the view fail in PostgreSQL ("cannot insert into view") and its reads cannot attach the cold tier. |
| `coldfront.archive_watermark` | The hot/cold cutoff that routes each tiered write. |
| `coldfront.storage_secret` | The cold-store credential, so one `set_storage_secret` call reaches every node. |
| `coldfront.partition_config` | The per-table lifecycle. The archiver and the partitioner add this table themselves as well, because the partitioner runs without the extension. |
| `coldfront.vector_config`, `coldfront.vector_centroids` | The cluster routing state, so every node resolves a vector to the same cluster. |

Two tables stay local by design and are not added: `coldfront.deferred_acks`
(each node's queue of the acks it owes) and `coldfront._dummy_dml_target`.

The call runs on every node because a replication set is a property of the
provider: each node sends the rows of the tables in its own set, and a node
that skipped the step keeps its acks, registry rows and secret to itself. It
cannot run at `CREATE EXTENSION` time, because `spock.repset_add_table` needs
the local Spock node, and nothing runs it later on a node's behalf:
provisioning a table, setting the secret and writing cold rows all assume it
has run. It is idempotent, so running it again is harmless.

This page describes forming a new mesh. Adding a node to a running mesh also
requires the new node to receive the ColdFront rows that already exist on its
peers, such as the table registry and the storage secret; the subscriptions
on this page skip the initial copy, so following these stages alone does not
provide those rows, and this page does not cover that procedure.

A skipped step shows up away from the node that skipped it. If a peer never
ran it, it has published no slot, and every cold write on the other nodes
refuses to run and names that peer. The same refusal follows when the slot a
peer published does not exist on the node, which is what a node restored from
a dump taken before the peer recreated its subscription holds; the peer's
`ensure_replicated()` replaces the row. If the node that registers a table
never ran it, the view reaches each peer as replicated DDL but the registry
row does not, so the peer's writes through the view fail with "cannot insert
into view". A secret set on such a node stays on that node.

Verify the step on every node. The query lists the eight tables of the
`default` set; `claim_acks` is in `default_insert_only`:

```sql
SELECT c.relname
  FROM spock.replication_set rs
  JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
  JOIN pg_class c ON c.oid = rst.set_reloid
 WHERE rs.set_name = 'default' AND c.relnamespace = 'coldfront'::regnamespace
 ORDER BY 1;
```

Then verify the mesh before benchmarking - insert a sentinel claim on each node
and read it back from every other node. All N×(N-1) directions must show the
row before traffic starts. `ci/journey.sh` `story_mesh_substrate` is a
copyable reference: it checks the membership above on every node and then the
sentinels.
