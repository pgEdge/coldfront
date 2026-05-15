#!/bin/bash
set -euo pipefail

PGBIN=/usr/pgsql-17/bin

# Per-node snowflake id (required for the bakery protocol — multi-writer
# commit serialisation on iceberg-only mode). Provided by docker-compose
# via the MULTITIER_SNOWFLAKE_NODE env var. Distinct integer per node.
SNOWFLAKE_NODE="${MULTITIER_SNOWFLAKE_NODE:-1}"
# Bakery reap requires snowflake.node = hashtext(spock_node_name) & 1023 on
# every node; otherwise coldfront._claim_iceberg_lock's reap query can't map
# snowflake.get_node(ticket) back to a peer in pg_stat_replication.
# coldfront checks this at first claim and raises if misaligned. CI sets
# MULTITIER_SNOWFLAKE_NODE in docker-compose to the derived value per node.

if [ ! -f "$PGDATA/PG_VERSION" ]; then
    "$PGBIN/initdb" -D "$PGDATA" -U coldfront --auth=trust \
        --locale=C --encoding=UTF8

    cat >> "$PGDATA/postgresql.conf" <<EOF

# coldfront-spock distributed test
listen_addresses = '*'
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'
# pg_duckdb v1.1.1 ships with these OFF by default. Turn them ON so
# ATTACH (TYPE ICEBERG, ...) transparently auto-installs iceberg from
# extensions.duckdb.org (and iceberg's init transitively auto-installs
# avro the same way). No explicit duckdb.install_extension calls in
# coldfront code — pg_duckdb does the whole chain.
duckdb.autoinstall_known_extensions = true
duckdb.autoload_known_extensions   = true
wal_level = logical
# max_worker_processes / max_replication_slots / max_wal_senders sized for
# a 10-node spock mesh: each node needs ~9 apply workers + 1 spock manager
# + autovac workers + pg_duckdb workers (plus headroom). N=3 didn't need
# this much, but the 10-node bench hit "worker registration failed" with
# the previous limit of 12.
max_worker_processes = 64
max_replication_slots = 64
max_wal_senders = 64
track_commit_timestamp = on
synchronous_commit = local
# wal_receiver_status_interval (RECEIVER-side GUC, takes effect on
# every node since every node is a wal receiver in the mesh). Controls
# how often a standby sends a spontaneous status update to its
# upstream; this is what keeps pg_stat_replication.reply_time fresh on
# the sender. PG default is 10 s, which would otherwise hold reply_time
# up to 10 s stale during idle. The R-A bakery's dead-peer escape
# (coldfront.peer_alive_window_ms, default 5 s) consults reply_time to
# decide whether a peer that hasn't acked is "alive but slow" (wait)
# or "gone" (proceed). With 1 s status interval, an idle alive peer's
# reply_time stays ≤ 1 s, well inside the 5 s window — so the escape
# only fires on real outages, never on idle false-positives.
wal_receiver_status_interval = 1s
spock.conflict_resolution = last_update_wins
spock.enable_ddl_replication = on
spock.allow_ddl_from_functions = on
spock.include_ddl_repset = on
spock.exception_behaviour = transdiscard
spock.save_resolutions = on
snowflake.node = ${SNOWFLAKE_NODE}
coldfront.warehouse = 'wh'
coldfront.lakekeeper_endpoint = 'http://lakekeeper:8181/catalog'
# DSN used by coldfront.ensure_pg_attached() to ATTACH this PG instance into
# DuckDB as 'pglocal' so raw_query() can read PG tables for streaming
# INSERT-into-Iceberg paths. Loopback over libpq.
#
# application_name=coldfront_pglocal is a marker the coldfront login
# event trigger checks: when set it skips ensure_attached() in that
# session, breaking the iceberg-attach → DuckDB-postgres-extension-load
# recursion that triggers "libpq is incorrectly linked to backend
# functions" on builds where pg_duckdb's libpq symbol isolation isn't
# tight (notably source-builds of v1.1.1).
coldfront.local_pg_dsn = 'host=127.0.0.1 dbname=coldfront user=coldfront application_name=coldfront_pglocal options=-cevent_triggers=off'
# DSN used by the bakery (coldfront._claim_iceberg_lock /
# _release_iceberg_lock) for autonomous-tx claim INSERT/DELETE via dblink,
# and by the coldfront C XactCallback for libpq-driven release. Pure PG
# DML — no iceberg ATTACH ever needed in those sessions, so we suppress
# the coldfront login event trigger via event_triggers=off (saves the
# ~100ms iceberg ATTACH on first dblink call per session and avoids any
# DuckDB-side recursion). application_name=coldfront_dblink is a marker
# for monitoring / log-correlation.
# Unix socket (host=/tmp) — avoids TCP/IP, lower latency, no port collisions,
# and the dblink session inherits no network state from the apply worker.
# event_triggers=off bypasses the coldfront login event trigger entirely
# in any dblink_self session.
coldfront.dblink_self = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_dblink options=-cevent_triggers=off'
EOF

    cat >> "$PGDATA/pg_hba.conf" <<EOF
host    all             all             0.0.0.0/0               trust
host    replication     all             0.0.0.0/0               trust
EOF

    "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=''" -w start
    "$PGBIN/psql" -U coldfront -d postgres -c "CREATE DATABASE coldfront OWNER coldfront"
    "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop
fi

exec "$PGBIN/postgres" -D "$PGDATA"
