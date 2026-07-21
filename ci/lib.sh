#!/bin/bash
# ci/lib.sh — shared helpers for the ColdFront E2E matrix.
#
# Sourced by journey.sh, matrix.sh, topo/*.sh, probe-standby.sh. There is ONE
# set of assert + psql helpers (DRY), matching the style of the original
# run-ci-local.sh so output and semantics are unchanged.
#
# psql is addressed by container name; the journey is topology-agnostic and
# never hardcodes a node — callers pass the container. CF_PSQL overrides the
# psql binary path for images where it isn't on PATH.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

step() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }
pass() { echo -e "${GREEN}  PASS: $1${NC}"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; FAIL=$((FAIL + 1)); }
# note: a logged, uncounted line — for coverage that is intentionally skipped in
# a given cell (so it's visible, never silent, but isn't a pass or a failure).
note() { echo -e "${YELLOW}  NOTE: $1${NC}"; }

assert_eq()       { if [ "$2" = "$3" ];        then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi; }
assert_gt()       { if [ "$3" -gt "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 — expected > $2, got '$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) pass "$1";; *) fail "$1 — '$3' does not contain '$2'";; esac; }
# Assert a command/SQL produced a specific error fragment (for blocked-op / read-only stories).
assert_err()      { case "$3" in *"$2"*) pass "$1";; *) fail "$1 — error did not contain '$2'; got: $3";; esac; }

# psql binary inside the container. pgEdge + pgduckdb images have it on PATH;
# override via CF_PSQL for an image that doesn't (e.g. /usr/pgsql-17/bin/psql).
CF_PSQL="${CF_PSQL:-psql}"
CF_DBUSER="${CF_DBUSER:-coldfront}"
CF_DBNAME="${CF_DBNAME:-coldfront}"

# q <container> <sql>  — one -tA -c query; trimmed scalar/rows on stdout.
q()  { local c="$1"; shift; docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "$c" "$CF_PSQL" -tA -c "$*"; }
# qf <container>  — heredoc on stdin (-tA), for batched KEY:value blocks and multi-statement scripts.
qf() { local c="$1"; shift; docker exec -i -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "$c" "$CF_PSQL" -tA; }
# q_may <container> <sql>  — run, capture stdout+stderr, never fail the script (for negative/error stories).
q_may() { local c="$1"; shift; docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "$c" "$CF_PSQL" -tA -c "$*" 2>&1 || true; }

# extract KEY "$BLOCK"  — pull the value from a "KEY:value" line in a captured block.
extract() { echo "$2" | grep "^$1:" | head -1 | cut -d: -f2-; }

# summary  — print pass/fail tally; returns nonzero if any FAIL (drives matrix exit code).
summary() {
    echo -e "\n  Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
    [ "$FAIL" -eq 0 ]
}

# standby_up <primary-container> <standby-name>  — base-backup a read-only
# physical standby of <primary-container> onto a fresh container of the SAME
# image + network, via the entrypoint's COLDFRONT_STANDBY_OF branch, and wait
# until it accepts connections. Returns nonzero (and dumps the standby log) if it
# never comes up. Shared by ci/probe-standby.sh and the topology scripts (DRY).
standby_up() {
    local primary="$1" sb="$2" db_ip net img
    db_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$primary")
    net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$primary")
    img=$(docker inspect -f '{{.Config.Image}}' "$primary")
    docker rm -f "$sb" >/dev/null 2>&1 || true
    docker run -d --name "$sb" --network "$net" \
        -e PG_MAJOR="${PG_MAJOR:-18}" -e COLDFRONT_STANDBY_OF="$db_ip" "$img" >/dev/null || return 1
    for _ in $(seq 1 45); do
        docker exec "$sb" pg_isready -U "$CF_DBUSER" -d "$CF_DBNAME" >/dev/null 2>&1 && return 0
        sleep 2
    done
    docker logs "$sb" 2>&1 | tail -20
    return 1
}

# The single read-only-replica container name — shared by the probe and both topo
# scripts (they never run concurrently, so one name is safe and avoids divergence).
CF_STANDBY="${CF_STANDBY:-coldfront-standby}"

# topo_standby <primary-container>  — when the topology was invoked with --standby
# (STANDBY=1), base-backup a read-only physical replica of <primary-container> as
# $CF_STANDBY and set STANDBY_ARG to the journey's --standby flag; otherwise
# STANDBY_ARG stays empty. Exits the topology on bring-up failure. The ONE home
# for topo standby bring-up — neither topo script duplicates it.
STANDBY_ARG=()
topo_standby() {
    [ "${STANDBY:-0}" = 1 ] || return 0
    step "base-backup a read-only standby of $1"
    standby_up "$1" "$CF_STANDBY" || { echo "standby $CF_STANDBY did not come up"; exit 1; }
    # shellcheck disable=SC2034  # consumed as "${STANDBY_ARG[@]}" by topo/{vanilla,mesh}.sh, which source this file
    STANDBY_ARG=(--standby "$CF_STANDBY")
}

# topo_teardown  — the EXIT trap shared by topo/*.sh and the probe: unless --keep
# (KEEP=1), remove the standby (if any) and tear the compose stack down. Reads the
# caller's $KEEP and $COMPOSE.
topo_teardown() {
    [ "${KEEP:-0}" = 1 ] && return 0
    docker rm -f "$CF_STANDBY" >/dev/null 2>&1 || true
    $COMPOSE down -v >/dev/null 2>&1 || true
}

# create_warehouse_and_seed <lk_ip> <wh_body>  — POST the (backend-specific) Lakekeeper
# warehouse with retry, then seed the 'default' Iceberg namespace. The seed is REQUIRED:
# DuckDB 1.5.x defers an Iceberg CREATE SCHEMA to transaction COMMIT while CREATE TABLE
# POSTs eagerly, so coldfront.create_iceberg_table (decoupled, one txn) 404s on a cold
# warehouse unless the namespace is pre-committed here as its own REST call. Exits the
# caller on warehouse-create failure. The ONE home for this — topo/vanilla.sh,
# topo/mesh.sh and ops.sh all call it (callers build the backend-specific <wh_body>).
create_warehouse_and_seed() {
    local lk_ip="$1" wh_body="$2" wh="" wid
    for _ in $(seq 1 15); do
        wh=$(curl -s "http://$lk_ip:8181/management/v1/warehouse" -X POST -H "Content-Type: application/json" -d "$wh_body" 2>&1)
        echo "$wh" | grep -q "warehouse-id" && break
        echo "$wh" | grep -qi "already exists" && { wh="warehouse-id (exists)"; break; }
        sleep 2
    done
    echo "$wh" | grep -q "warehouse-id" || { echo "warehouse creation failed after retries: $wh"; exit 1; }
    wid=$(echo "$wh" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    [ -z "$wid" ] && wid=$(curl -s "http://$lk_ip:8181/management/v1/warehouse" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    if [ -n "$wid" ]; then
        curl -s -X POST "http://$lk_ip:8181/catalog/v1/$wid/namespaces" \
            -H "Content-Type: application/json" -d '{"namespace":["public"]}' >/dev/null 2>&1 || true
    fi
}
