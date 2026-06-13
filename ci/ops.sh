#!/bin/bash
# ci/ops.sh — operational-hardening checks (beta scope). Run ONCE on a
# representative vanilla·tiered·s3 cell (hermetic SeaweedFS), not per matrix cell.
#
# Checks (incremental — graceful degradation + recovery first):
#   1. Lakekeeper-down: the REST catalog is unreachable → cold reads/writes fail
#      with a clean error, but the node stays CONNECTABLE and hot-tier reads work.
#      This holds because the 'ice' catalog is ATTACHed lazily inside the failing
#      query (coldfront.ensure_attached), so a catalog outage degrades only cold
#      I/O — it never blocks connecting or reading hot data.
#   2. S3-down: the object store is unreachable → same graceful-degradation bar.
#
# Both also assert RECOVERY: once the dependency returns, a fresh session
# re-attaches and cold I/O works again.
#
# (Privilege model + pg_dump/restore checks are added in follow-up increments.)
#
# Usage: ci/ops.sh [--pg 16|17|18] [--keep]
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
  *) echo "ops.sh: unknown arg $1"; exit 2;;
esac; done
export PG_MAJOR="$PG"
COMPOSE_FILE="docker-compose.matrix.yml"
COMPOSE="docker compose -f $COMPOSE_FILE"
DB=coldfront-db-1; LK=coldfront-lakekeeper-1; SW=coldfront-seaweedfs-1
trap topo_teardown EXIT

ip() { docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

step "ops: build + up ($COMPOSE_FILE, pg$PG)"
$COMPOSE down -v >/dev/null 2>&1 || true
$COMPOSE up -d --build >/dev/null 2>&1
for i in $(seq 1 30); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] && break; sleep 2; done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] || { echo "db not healthy"; exit 1; }
LK_IP=$(ip "$LK"); SW_IP=$(ip "$SW")

step "ops: bootstrap Lakekeeper + warehouse + namespace (s3)"
curl -sf "http://$LK_IP:8181/management/v1/bootstrap" -X POST -H "Content-Type: application/json" \
     -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
WH_BODY="{\"warehouse-name\":\"wh\",\"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},\"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}}"
create_warehouse_and_seed "$LK_IP" "$WH_BODY"

step "ops: setup (extensions, storage secret) + provision a hot + a cold relation"
qf "$DB" >/dev/null <<EOSQL
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin','adminsecret','${SW_IP}:8333');
-- hot-only table: a plain heap, never touches the 'ice' catalog
CREATE TABLE IF NOT EXISTS hot1 (id bigint);
INSERT INTO hot1 VALUES (1);
-- cold relation: a decoupled iceberg-only view whose reads/writes funnel through
-- the 'ice' catalog (Lakekeeper) + S3
SELECT coldfront.create_iceberg_table('public','cold1','[{"name":"id","type":"bigint"}]'::jsonb);
INSERT INTO cold1 VALUES (1);
EOSQL
assert_eq "baseline: hot read"  "1" "$(q "$DB" "SELECT count(*) FROM hot1;")"
assert_eq "baseline: cold read" "1" "$(q "$DB" "SELECT count(*) FROM cold1;")"

# cold_recovers <label>  — retry the cold read until it returns 1 (a fresh session
# re-attaches once the dependency is back). Bounded so a never-recovering case fails.
cold_recovers() {
    local out i
    for i in $(seq 1 25); do
        out=$(q "$DB" "SELECT count(*) FROM cold1;" 2>/dev/null)
        [ "$out" = "1" ] && break
        sleep 2
    done
    assert_eq "$1" "1" "$out"
}

# ── Check 1: Lakekeeper-down ──────────────────────────────────────────────────
step "ops 1: Lakekeeper-down — cold I/O fails cleanly; node + hot tier survive"
docker stop "$LK" >/dev/null 2>&1
assert_eq "node still accepts connections (LK down)" "1" "$(q "$DB" "SELECT 1;" 2>/dev/null)"
assert_eq "hot read unaffected (LK down)"            "1" "$(q "$DB" "SELECT count(*) FROM hot1;" 2>/dev/null)"
lk_cold=$(q_may "$DB" "SET statement_timeout='25s'; SELECT count(*) FROM cold1;")
assert_contains "cold read fails with a clean error, no hang (LK down)" "ERROR" "$lk_cold"
docker start "$LK" >/dev/null 2>&1
cold_recovers "cold read recovers after Lakekeeper returns"

# ── Check 2: S3-down ──────────────────────────────────────────────────────────
step "ops 2: S3-down — cold I/O fails cleanly; node + hot tier survive"
docker stop "$SW" >/dev/null 2>&1
assert_eq "node still accepts connections (S3 down)" "1" "$(q "$DB" "SELECT 1;" 2>/dev/null)"
assert_eq "hot read unaffected (S3 down)"            "1" "$(q "$DB" "SELECT count(*) FROM hot1;" 2>/dev/null)"
s3_cold=$(q_may "$DB" "SET statement_timeout='25s'; SELECT count(*) FROM cold1;")
assert_contains "cold read fails with a clean error, no hang (S3 down)"  "ERROR" "$s3_cold"
s3_write=$(q_may "$DB" "SET statement_timeout='25s'; INSERT INTO cold1 VALUES (2);")
assert_contains "cold write fails with a clean error, no hang (S3 down)" "ERROR" "$s3_write"
docker start "$SW" >/dev/null 2>&1
cold_recovers "cold read recovers after S3 returns"

summary
