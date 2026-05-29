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
