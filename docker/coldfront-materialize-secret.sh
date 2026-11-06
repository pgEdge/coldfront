#!/bin/bash
# coldfront-materialize-secret.sh: write this node's DuckDB storage secret from
# the coldfront.storage_secret row when the secret file is absent.
#
# DuckDB keeps a static credential's persistent secret in
# $HOME/.duckdb/stored_secrets, outside PGDATA, so a recreated container, a new
# standby or a restored node has none. The script waits until the server
# accepts connections, polling once a second because a server still in recovery
# logs each refused attempt, and runs on a standby too (a SELECT and a DuckDB
# file write). It stops at once when pg_isready cannot run at all (status above
# 2). An existing file is left alone: DuckDB 1.5.4 replaces one by deleting it
# first, and a session that starts its DuckDB instance in between would load no
# secret.
#
# It connects through the libpq environment (PGHOST, PGUSER, PGDATABASE) and
# ignores its arguments, so it also serves as a Patroni callback, which passes
# three. It always exits 0: the image's entrypoint starts it in the background
# and then execs postgres, so the postmaster becomes its parent, and the
# postmaster treats a child's exit status above 1 as a crashed backend. On
# PostgreSQL 18 a clean exit reads in the server log as an untracked child
# process exiting with code 0.
until pg_isready -q; do
    [ $? -le 2 ] || exit 0
    sleep 1
done
name=$(psql -qXtA -c "SELECT name FROM coldfront.storage_secret WHERE NOT vended" 2>/dev/null)
if [ -n "$name" ] && [ ! -f "$HOME/.duckdb/stored_secrets/$name.duckdb_secret" ] \
    && psql -qX -c "SET client_min_messages = warning" \
        -c "SELECT coldfront.materialize_storage_secret()" >/dev/null; then
    echo "coldfront: wrote the DuckDB storage secret $name"
fi
exit 0
