#!/bin/bash
# ci/probe-snowflake.sh — reproducible cross-check of ColdFront's snowflake
# id↔epoch math against the LIVE pgEdge snowflake extension.
#
# internal/partition/idmap.go decodes a snowflake's time as
# (id >> 22) + 1672531200000 ms (SNOWFLAKE_MSEC_SHIFT=22, epoch 2023-01-01). That
# relationship was previously checked only against a hardcoded literal in
# TestSnowflake_AgainstLiveSample. This probe makes it reproducible: it stands up
# a snowflake-capable node, generates real snowflakes via snowflake.nextval(), and
# asserts snowflake.get_epoch(id) * 1000 == (id >> 22) + 1672531200000 for each.
# get_epoch returns SECONDS, so *1000 yields the same milliseconds idmap.go uses.
#
# Usage: ci/probe-snowflake.sh [--pg 16|17|18] [--keep]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/lib.sh"
cd "$ROOT"

PG="${PG_MAJOR:-18}"; KEEP=0
while [ $# -gt 0 ]; do case "$1" in
  --pg) PG="$2"; shift 2;;
  --keep) KEEP=1; shift;;
  *) echo "probe-snowflake.sh: unknown arg $1"; exit 2;;
esac; done
export PG_MAJOR="$PG"
SF=coldfront-snowflake-probe
IMG="coldfront-db-probe:pg${PG}"

teardown() { [ "$KEEP" = 1 ] && return 0; docker rm -f "$SF" >/dev/null 2>&1 || true; }
trap teardown EXIT

# A single MESH=on node: the entrypoint preloads the snowflake extension and sets
# snowflake.node, so snowflake.nextval()/get_epoch() work without a Spock mesh.
step "probe-snowflake: build + start a snowflake-capable node (pg${PG}, MESH=on)"
docker rm -f "$SF" >/dev/null 2>&1 || true
docker build -f docker/Dockerfile.duckdb15 --build-arg PG_MAJOR="$PG" -t "$IMG" . >/dev/null 2>&1 \
    || { fail "build $IMG"; exit 1; }
docker run -d --name "$SF" -e PG_MAJOR="$PG" -e MESH=on "$IMG" >/dev/null 2>&1 || { fail "run $SF"; exit 1; }
# The image declares no HEALTHCHECK (health is compose-defined), so a bare
# `docker run` never reports a health status. Wait on real connectivity to the
# coldfront DB via the same docker-exec psql transport the rest of the probe uses
# — this also confirms the entrypoint finished creating the role+database.
for i in $(seq 1 60); do q "$SF" "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
q "$SF" "SELECT 1" >/dev/null 2>&1 || { fail "snowflake node never accepted connections"; docker logs --tail 30 "$SF" 2>&1 | sed 's/^/    /'; exit 1; }
q "$SF" "CREATE EXTENSION IF NOT EXISTS snowflake;" >/dev/null 2>&1

step "probe-snowflake: get_epoch(id)*1000 == (id>>22)+1672531200000 for live snowflakes"
# Generate a batch of real snowflakes and count any that violate idmap.go's formula.
mism=$(q "$SF" "SELECT count(*) FROM (SELECT snowflake.nextval() AS id FROM generate_series(1,16)) s
                 WHERE (snowflake.get_epoch(id) * 1000)::bigint <> (id >> 22) + 1672531200000;")
assert_eq "every live snowflake satisfies get_epoch*1000 == (id>>22)+1672531200000 (idmap.go constants)" "0" "$mism"

# Surface one concrete triple for the log (id | get_epoch*1000 | (id>>22)+offset).
sample=$(q "$SF" "SELECT id || ' | ' || (snowflake.get_epoch(id) * 1000)::bigint || ' | ' || ((id >> 22) + 1672531200000)
                  FROM (SELECT snowflake.nextval() AS id) s;")
note "live sample  id | get_epoch*1000 | (id>>22)+epoch  =  $sample"

summary
