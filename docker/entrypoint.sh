#!/bin/bash
# docker/entrypoint.sh — one entrypoint for every ColdFront matrix cell.
#
# On first boot: initdb, create the coldfront role+db, write pg_hba (trust for
# the test network), and generate postgresql.conf from the environment. Then
# exec postgres. Config is driven by env so the compose only sets variables:
#
#   PG_MAJOR              PG major (baked into the image; also used for paths)
#   MESH                  "on" → load snowflake,spock + mesh GUCs; else vanilla
#   COLDFRONT_WAREHOUSE   coldfront.warehouse                  (default: wh)
#   COLDFRONT_LAKEKEEPER  coldfront.lakekeeper_endpoint        (default: http://lakekeeper:8181/catalog)
#   COLDFRONT_SNOWFLAKE_NODE   mesh only: snowflake.node       (default: 1)
#
# Vanilla = single node, local advisory-lock bakery (snowflake/spock absent).
# Mesh = N-node Spock; the bakery uses the Ricart–Agrawala protocol.
set -euo pipefail

PG_MAJOR="${PG_MAJOR:?PG_MAJOR not set}"
PGBIN="/usr/pgsql-${PG_MAJOR}/bin"
PGDATA="${PGDATA:-/var/lib/pgsql/${PG_MAJOR}/data}"
MESH="${MESH:-off}"
WAREHOUSE="${COLDFRONT_WAREHOUSE:-wh}"
LAKEKEEPER="${COLDFRONT_LAKEKEEPER:-http://lakekeeper:8181/catalog}"
SNOWFLAKE_NODE="${COLDFRONT_SNOWFLAKE_NODE:-1}"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
    mkdir -p "$PGDATA"
    "$PGBIN/initdb" -D "$PGDATA" -U coldfront --auth=trust --locale=C --encoding=UTF8

    if [ "$MESH" = "on" ]; then
        PRELOAD="snowflake,spock,pg_duckdb,coldfront"
    else
        PRELOAD="pg_duckdb,coldfront"
    fi

    cat >> "$PGDATA/postgresql.conf" <<EOF

# ── ColdFront ($([ "$MESH" = on ] && echo mesh || echo vanilla), pg${PG_MAJOR}) ──
listen_addresses = '*'
shared_preload_libraries = '${PRELOAD}'
# ColdFront ships its OWN patched duckdb-iceberg (bakery-aware commit refresh;
# see PATCHED.md), placed into the extension cache below. autoinstall stays ON so
# postgres_scanner + any non-bundled deps auto-install; it does NOT clobber the
# pre-placed iceberg/avro (DuckDB skips install for extensions already present).
# allow_unsigned ON so the locally-built (unsigned) extension loads; autoload ON
# so ATTACH (TYPE ICEBERG, ...) lazily LOADs it; iceberg_async_parquet ON so the
# mesh bakery uploads parquet in the background and serializes only the commit
# POST (safe because the patch refreshes parent_snapshot_id at commit). Vanilla
# ignores the flag (advisory lock, claim-first).
duckdb.autoinstall_known_extensions = true
duckdb.autoload_known_extensions    = true
duckdb.allow_unsigned_extensions    = true
coldfront.iceberg_async_parquet     = on
coldfront.warehouse = '${WAREHOUSE}'
coldfront.lakekeeper_endpoint = '${LAKEKEEPER}'
# Loopback DSN coldfront.ensure_pg_attached() uses to ATTACH this PG into
# DuckDB as 'pglocal'. application_name=coldfront_pglocal + event_triggers=off
# stop the login trigger recursing into an iceberg attach in that session.
coldfront.local_pg_dsn = 'host=/var/run/postgresql dbname=coldfront user=coldfront application_name=coldfront_pglocal options=-cevent_triggers=off'
EOF

    if [ "$MESH" = "on" ]; then
        cat >> "$PGDATA/postgresql.conf" <<EOF
wal_level = logical
max_worker_processes = 64
max_replication_slots = 64
max_wal_senders = 64
track_commit_timestamp = on
synchronous_commit = local
wal_receiver_status_interval = 1s
spock.conflict_resolution = last_update_wins
spock.enable_ddl_replication = on
spock.allow_ddl_from_functions = on
spock.include_ddl_repset = on
spock.exception_behaviour = transdiscard
spock.save_resolutions = on
snowflake.node = ${SNOWFLAKE_NODE}
# dblink DSN for the R-A bakery's autonomous claim/release (unix socket, no
# iceberg attach ever needed → suppress the login trigger).
coldfront.dblink_self = 'host=/var/run/postgresql dbname=coldfront user=coldfront application_name=coldfront_dblink options=-cevent_triggers=off'
EOF
    fi

    cat >> "$PGDATA/pg_hba.conf" <<EOF
host    all             all             0.0.0.0/0               trust
host    replication     all             0.0.0.0/0               trust
EOF

    # Place the patched duckdb-iceberg + avro into DuckDB's per-data-dir
    # extension cache so pg_duckdb loads them (autoinstall is off, allow_unsigned
    # is on). The version/platform subpath is pinned in lockstep with the
    # iceberg-builder's OVERRIDE_GIT_DESCRIBE. See PATCHED.md.
    if [ -f /opt/coldfront/iceberg/iceberg.duckdb_extension ]; then
        EXTDIR="$PGDATA/pg_duckdb/extensions/${COLDFRONT_DUCKDB_VERSION:-v1.4.3}/${COLDFRONT_DUCKDB_PLATFORM:-linux_amd64}"
        mkdir -p "$EXTDIR"
        cp /opt/coldfront/iceberg/iceberg.duckdb_extension "$EXTDIR/iceberg.duckdb_extension"
        cp /opt/coldfront/iceberg/avro.duckdb_extension    "$EXTDIR/avro.duckdb_extension"
    fi

    "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=''" -w start
    "$PGBIN/psql" -U coldfront -d postgres -c "CREATE DATABASE coldfront OWNER coldfront"
    "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop
fi

exec "$PGBIN/postgres" -D "$PGDATA" "$@"
