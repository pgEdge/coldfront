# Setting Up a Distributed Deployment

For multi-writer iceberg workloads, run ColdFront on N PG nodes in a Spock mesh
against the same Lakekeeper + S3. The bakery serializes commits PG-side so
writers never collide at the catalog.

### Per-Node `postgresql.conf`

The configuration below applies to each node in the mesh:

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

The bakery has no peer-ack timeout. R-A's only failure mode is a dead peer
(would wait forever), and a liveness check inside the wait loop closes it:
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
nothing waits. See [architecture_decoupled.md](architecture_decoupled.md),
*Orphan reaping*.

Sync-rep (`synchronous_standby_names`) is **not required** by the bakery - the
R-A ack barrier is what serializes iceberg commits. You can still enable
sync-rep cluster-wide if you want stronger durability for non-bakery writes,
but it plays no part in iceberg-commit serialization.

Run this one-time mesh setup in this order on every node, because step 3 calls
`spock.repset_add_table`, which requires the local Spock node to already exist:

```sql
-- 1. Extensions, in dependency order. snowflake is a bakery prereq
-- (claim tickets come from snowflake.nextval).
CREATE EXTENSION IF NOT EXISTS snowflake;
CREATE EXTENSION IF NOT EXISTS spock;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- 2. Spock node + full-mesh subscriptions (each node has N-1 subs). Name each
-- subscription sub_<subscriber>_from_<provider> (on n1: sub_n1_from_n2): the
-- bakery's peer-liveness check looks the walsender up by that name, and a peer
-- whose subscription is named any other way counts as dead and is treated as
-- already acked.
SELECT spock.node_create('n<i>', 'host=<this_node_priv_ip> user=coldfront dbname=coldfront port=5432');

-- on n1 (n2 and n3 symmetric):
SELECT spock.sub_create('sub_n1_from_n2', 'host=<n2> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);
SELECT spock.sub_create('sub_n1_from_n3', 'host=<n3> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);

-- 3. **Required** on every node, after its subscriptions exist and before
-- the first cold write, storage secret or table registration: put every
-- ColdFront table that replicates by value in this node's replication sets.
SELECT coldfront.ensure_replicated();
```

The subscriptions set
`synchronize_structure := false, synchronize_data := false` because the tables
already exist on every node from the coldfront extension, so no initial copy is
needed.

### Timeouts

The following table lists the two settings that decide how long a cold write
waits for a peer; set them together, on every node:

| Setting | Recommended | Where | What it does |
|---|---|---|---|
| `wal_sender_timeout` | `15s` | `postgresql.conf` on every node; the image sets it in mesh mode | The node's walsender asks each peer for a reply after half of it (7.5 s) and drops a peer that has not replied for the whole of it. |
| `coldfront.peer_alive_window_ms` | `10000` (the default) | `postgresql.conf`, superuser-only | The bakery treats a peer whose last reply is older than this as dead and stops waiting for its ack. |

The rule: half of `wal_sender_timeout` must stay below the window, with a
round trip to spare; the claim enforces the first part. An idle peer replies
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

### What `coldfront.ensure_replicated()` Does

The call is the one ColdFront-specific step of the mesh setup. It adds eight
tables to the node's replication sets (`claim_acks` to `default_insert_only`,
the rest to `default`), each keyed by name, so a row is identical on every node
and replicates by value:

| Table | What replicates, and why a peer needs it |
|---|---|
| `coldfront.claims`, `coldfront.claim_acks` | The bakery's tickets and acknowledgements. A peer acknowledges an originator's claim by inserting into `claim_acks` on its own node, and the ack reaches the originator only if the table is in the peer's set. `claim_acks` goes in the insert-only set, because each node deletes only the ack copies it holds. |
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
has run. It is idempotent, so running it again is harmless, and a node added to
the mesh later runs the same three steps.

A skipped step shows up late and away from the node that skipped it. If a peer
never ran it, the originator of every cold write waits at the ack barrier for
an ack that never arrives. If the node that registers a table never ran it,
the view reaches each peer as replicated DDL but the registry row does not, so
the peer's writes through the view fail with "cannot insert into view". A
secret set on such a node stays on that node.

Verify the step on every node. The query lists the eight tables:

```sql
SELECT c.relname
  FROM spock.replication_set rs
  JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
  JOIN pg_class c ON c.oid = rst.set_reloid
 WHERE rs.set_name = 'default' AND c.relnamespace = 'coldfront'::regnamespace
 ORDER BY 1;
```

Then verify the mesh before benching - insert a sentinel claim on each node
and read it back from every other node. All N×(N-1) directions must show the
row before traffic starts. `ci/journey.sh` `story_mesh_substrate` is a
copyable reference: it checks the membership above on every node and then the
sentinels.
