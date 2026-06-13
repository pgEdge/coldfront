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
#   3. Privilege model: a NON-superuser app role, onboarded in one call
#      (coldfront.grant_app_access), does transparent cold read+write — with no
#      superuser, no server-file roles — and the boundary holds (it cannot
#      redirect the elevated ATTACH endpoint, cannot self-grant, and an
#      un-onboarded role is cleanly denied). Turnkey because the image defaults
#      duckdb.postgres_role + creates the role (entrypoint).
#
# Checks 1 & 2 also assert RECOVERY: once the dependency returns, a fresh session
# re-attaches and cold I/O works again.
#
# (pg_dump/restore check is added in a follow-up increment.)
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
# We PAUSE (SIGSTOP) SeaweedFS rather than stop it: a transient S3 outage is
# modelled by the endpoint going unreachable, not by killing the store. (An
# abrupt `docker stop` SIGKILLs SeaweedFS, which loses its volume registration —
# a SeaweedFS durability property, not a ColdFront one — so reads would never
# recover. pause/unpause has no such confound and is the faithful outage model.)
# Paused = connections hang → statement_timeout='25s' turns it into a clean ERROR.
step "ops 2: S3-down — cold I/O fails cleanly; node + hot tier survive"
docker pause "$SW" >/dev/null 2>&1
assert_eq "node still accepts connections (S3 down)" "1" "$(q "$DB" "SELECT 1;" 2>/dev/null)"
assert_eq "hot read unaffected (S3 down)"            "1" "$(q "$DB" "SELECT count(*) FROM hot1;" 2>/dev/null)"
s3_cold=$(q_may "$DB" "SET statement_timeout='25s'; SELECT count(*) FROM cold1;")
assert_contains "cold read fails with a clean error, no hang (S3 down)"  "ERROR" "$s3_cold"
s3_write=$(q_may "$DB" "SET statement_timeout='25s'; INSERT INTO cold1 VALUES (2);")
assert_contains "cold write fails with a clean error, no hang (S3 down)" "ERROR" "$s3_write"
docker unpause "$SW" >/dev/null 2>&1
cold_recovers "cold read recovers after S3 returns"

# ── Check 3: enterprise privilege model — non-superuser cold I/O, one-call onboard ──
step "ops 3: privilege model — grant_app_access onboards a NON-superuser; boundary holds"
# qas <role> <sql>  — run <sql> as a NON-superuser via SET ROLE and return only the
# final result line (psql echoes the "SET" command tag, which we drop).
qas() { q "$DB" "SET ROLE $1; $2" 2>/dev/null | tail -1; }
# Turnkey: the image defaults duckdb.postgres_role + creates the NOLOGIN role.
assert_eq  "image defaults duckdb.postgres_role (turnkey)" "coldfront_duckdb" "$(q "$DB" "SHOW duckdb.postgres_role;")"
q "$DB" "CREATE ROLE cfapp NOSUPERUSER LOGIN PASSWORD 'x';"    >/dev/null 2>&1
q "$DB" "CREATE ROLE cfnobody NOSUPERUSER LOGIN PASSWORD 'x';" >/dev/null 2>&1
# ONE call onboards the app role (idempotent; derives schemas/views from the registry).
onboard=$(q_may "$DB" "SELECT coldfront.grant_app_access('cfapp');")
assert_eq "grant_app_access('cfapp') succeeds — one-call onboarding" "" "$(echo "$onboard" | grep -iE 'error' || true)"

# The app role is a plain NON-superuser with NO server-file roles.
assert_eq "app role is NOT a superuser"          "off" "$(qas cfapp "SELECT current_setting('is_superuser');")"
assert_eq "app role lacks pg_read_server_files"  "f"   "$(q "$DB" "SELECT pg_has_role('cfapp','pg_read_server_files','MEMBER');")"
assert_eq "app role lacks pg_write_server_files" "f"   "$(q "$DB" "SELECT pg_has_role('cfapp','pg_write_server_files','MEMBER');")"

# Transparent cold I/O works as the non-superuser: read + single + multi-row INSERT.
assert_gt "app role: transparent cold read" "0" "$(qas cfapp "SELECT count(*) FROM public.cold1;")"
q "$DB" "SET ROLE cfapp; INSERT INTO public.cold1 VALUES (101);"          >/dev/null 2>&1
q "$DB" "SET ROLE cfapp; INSERT INTO public.cold1 VALUES (102),(103);"    >/dev/null 2>&1
assert_eq "app role: transparent cold writes landed (read-your-write)" "3" \
    "$(qas cfapp "SELECT count(*) FROM public.cold1 WHERE id IN (101,102,103);")"

# The boundary holds — three negatives:
deny_set=$(q_may "$DB" "SET ROLE cfapp; SET coldfront.lakekeeper_endpoint='http://attacker.example/evil';")
assert_contains "app role CANNOT redirect the elevated ATTACH endpoint (SUSET GUC)" "permission denied" "$deny_set"
deny_self=$(q_may "$DB" "SET ROLE cfapp; SELECT coldfront.grant_app_access('cfapp');")
assert_contains "app role CANNOT self-grant (grant_app_access not PUBLIC-executable)" "permission denied" "$deny_self"
deny_bare=$(q_may "$DB" "SET ROLE cfnobody; SELECT count(*) FROM public.cold1;")
assert_contains "un-onboarded role is cleanly DENIED cold access" "ERROR" "$deny_bare"

summary
