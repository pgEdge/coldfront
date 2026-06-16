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
# Role that pg_duckdb gates DuckDB execution on (duckdb.postgres_role). Defaulting
# it (and creating the NOLOGIN role) makes non-superuser cold access turnkey: an
# operator just runs SELECT coldfront.grant_app_access('alice'). Set
# COLDFRONT_DUCKDB_ROLE='' to keep pg_duckdb's stock superuser-only behaviour.
DUCKDB_ROLE="${COLDFRONT_DUCKDB_ROLE-coldfront_duckdb}"

if [ ! -f "$PGDATA/PG_VERSION" ] && [ -n "${COLDFRONT_STANDBY_OF:-}" ]; then
    # ── Physical standby: base-backup the primary instead of initdb. ──
    # A base backup carries everything a hot standby needs to serve cross-tier
    # reads: the data, the coldfront GUCs (they live in postgresql.conf, not
    # ALTER SYSTEM, so they ride the backup), the patched duckdb-iceberg cache
    # (it sits inside PGDATA), and the DuckDB S3 secret (a pg_foreign_server row,
    # physically replicated). -R writes standby.signal + primary_conninfo;
    # hot_standby defaults on, so the replica serves read queries.
    mkdir -p "$PGDATA"; chmod 700 "$PGDATA"
    echo "standby: waiting for primary ${COLDFRONT_STANDBY_OF} …"
    until "$PGBIN/pg_isready" -h "$COLDFRONT_STANDBY_OF" -U coldfront -d coldfront >/dev/null 2>&1; do sleep 1; done
    "$PGBIN/pg_basebackup" -h "$COLDFRONT_STANDBY_OF" -U coldfront -D "$PGDATA" -R -X stream -c fast -P
elif [ ! -f "$PGDATA/PG_VERSION" ]; then
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
# see DUCKDB_1.5_PATCHED.md), placed into the extension cache below. autoinstall stays ON so
# postgres_scanner + any non-bundled deps auto-install; it does NOT clobber the
# pre-placed iceberg/avro (DuckDB skips install for extensions already present).
# allow_unsigned ON so the locally-built (unsigned) extension loads; autoload ON
# so ATTACH (TYPE ICEBERG, ...) lazily LOADs it; iceberg_async_parquet ON so the
# mesh bakery uploads parquet in the background and serializes only the commit
# POST (safe because the patch refreshes parent_snapshot_id at commit). Vanilla
# ignores the flag (advisory lock, claim-first).
#
# iceberg_bakery_patch = on ASSERTS that the duckdb-iceberg in THIS image carries
# the bakery-aware-commit-refresh patch (it does — the Dockerfile git-applies it).
# coldfront._iceberg_async_active() gates the async ordering on BOTH GUCs, so async
# only ever runs on a genuinely patched binary. Do NOT set this in an image/host
# whose duckdb-iceberg is stock — coldfront would then fail safe to the stock
# ordering and warn (never silent 409). The two GUCs are deliberately set together.
duckdb.autoinstall_known_extensions = true
duckdb.autoload_known_extensions    = true
duckdb.allow_unsigned_extensions    = true
coldfront.iceberg_async_parquet     = on
coldfront.iceberg_bakery_patch      = on
coldfront.warehouse = '${WAREHOUSE}'
coldfront.lakekeeper_endpoint = '${LAKEKEEPER}'
# Loopback DSN coldfront.ensure_pg_attached() uses to ATTACH this PG into
# DuckDB as 'pglocal'. application_name tags the loopback session in
# pg_stat_activity.
coldfront.local_pg_dsn = 'host=/var/run/postgresql dbname=coldfront user=coldfront application_name=coldfront_pglocal'
EOF

    # pg_duckdb gates DuckDB execution on membership of duckdb.postgres_role
    # (PGC_POSTMASTER). Setting it here (role created below) lets members run
    # DuckDB; superusers always can. Omitted when COLDFRONT_DUCKDB_ROLE='' so
    # pg_duckdb keeps its stock superuser-only default.
    if [ -n "$DUCKDB_ROLE" ]; then
        echo "duckdb.postgres_role = '${DUCKDB_ROLE}'" >> "$PGDATA/postgresql.conf"
    fi

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
# dblink DSN for the R-A bakery's autonomous claim/release (unix socket). The
# bakery touches coldfront.claims only, never a tiered view, so the lazy 'ice'
# attach never fires here.
coldfront.dblink_self = 'host=/var/run/postgresql dbname=coldfront user=coldfront application_name=coldfront_dblink'
EOF
    fi

    cat >> "$PGDATA/pg_hba.conf" <<EOF
host    all             all             0.0.0.0/0               trust
host    replication     all             0.0.0.0/0               trust
EOF

    # Place the patched duckdb-iceberg + avro into DuckDB's per-data-dir
    # extension cache so pg_duckdb loads them (autoinstall is off, allow_unsigned
    # is on). The version/platform subpath is pinned in lockstep with the
    # iceberg-builder's OVERRIDE_GIT_DESCRIBE. See DUCKDB_1.5_PATCHED.md.
    if [ -f /opt/coldfront/iceberg/iceberg.duckdb_extension ]; then
        EXTDIR="$PGDATA/pg_duckdb/extensions/${COLDFRONT_DUCKDB_VERSION:-v1.5.3}/${COLDFRONT_DUCKDB_PLATFORM:-linux_amd64}"
        mkdir -p "$EXTDIR"
        cp /opt/coldfront/iceberg/iceberg.duckdb_extension "$EXTDIR/iceberg.duckdb_extension"
        cp /opt/coldfront/iceberg/avro.duckdb_extension    "$EXTDIR/avro.duckdb_extension"
        # azure ext (Azure ADLS cold tier) ships in the 1.5.x image. The [ -f ]
        # guard is defensive (kept harmless even though it is always present now).
        [ -f /opt/coldfront/iceberg/azure.duckdb_extension ] && \
            cp /opt/coldfront/iceberg/azure.duckdb_extension "$EXTDIR/azure.duckdb_extension"
        # postgres_scanner ('postgres' ext) — shipped in the 1.5.x image so
        # install_extension('postgres') (pglocal write path) resolves it locally
        # instead of downloading from extensions.duckdb.org.
        [ -f /opt/coldfront/iceberg/postgres_scanner.duckdb_extension ] && \
            cp /opt/coldfront/iceberg/postgres_scanner.duckdb_extension "$EXTDIR/postgres_scanner.duckdb_extension"
    fi

    "$PGBIN/pg_ctl" -D "$PGDATA" -o "-c listen_addresses=''" -w start
    "$PGBIN/psql" -U coldfront -d postgres -c "CREATE DATABASE coldfront OWNER coldfront"
    # NOLOGIN group role pg_duckdb gates DuckDB on. Members (granted via
    # coldfront.grant_app_access) run the cold path as non-superusers.
    if [ -n "$DUCKDB_ROLE" ]; then
        "$PGBIN/psql" -U coldfront -d postgres \
            -c "CREATE ROLE \"${DUCKDB_ROLE}\" NOLOGIN" 2>/dev/null || true
    fi
    "$PGBIN/pg_ctl" -D "$PGDATA" -m fast -w stop
fi

exec "$PGBIN/postgres" -D "$PGDATA" "$@"
