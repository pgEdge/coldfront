#!/usr/bin/env bash
set -uo pipefail   # not -e: demo bodies must continue past an assertion

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=runner.sh
source "$SCRIPT_DIR/runner.sh"

COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"
PG_PORT="${COLDFRONT_PG_PORT:-5432}"
LK_PORT="${COLDFRONT_LK_PORT:-8181}"
# shellcheck disable=SC2034  # consumed by Phase B+ tasks
S3_PORT="${COLDFRONT_S3_PORT:-8333}"
LK_URL="http://localhost:${LK_PORT}"
# shellcheck disable=SC2034  # consumed by Phase B+ tasks
NONINTERACTIVE="${WALKTHROUGH_NONINTERACTIVE:-0}"

cleanup() { stop_spinner; }
trap cleanup EXIT

pg()       { PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -tAX -c "$1"; }
psql_file(){ PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -v ON_ERROR_STOP=1; }

phase_a_bringup() {
    header "Getting the environment ready"
    explain "This is just infrastructure — the ColdFront parts come next and we'll"
    explain "walk through those together. The stack includes a local S3-compatible"
    explain "store (SeaweedFS) standing in for a real cloud bucket (AWS S3 / Azure /"
    explain "GCS); in production you'd point ColdFront at your own bucket instead."
    echo ""

    start_spinner "[1/4] Starting containers (Postgres, Lakekeeper, local S3)"
    $COMPOSE up -d --build >/dev/null 2>&1
    stop_spinner; info "[1/4] Containers started"

    start_spinner "[2/4] Waiting for Postgres to accept connections"
    local ok=0
    for _ in $(seq 1 40); do
        if pg "SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
        sleep 3
    done
    stop_spinner
    [ "$ok" = 1 ] || { error "Postgres did not become ready"; $COMPOSE logs db | tail -20; exit 1; }
    info "[2/4] Postgres is ready"

    start_spinner "[3/4] Waiting for the Lakekeeper catalog"
    ok=0
    for _ in $(seq 1 40); do
        if curl -sf "$LK_URL/health" >/dev/null 2>&1 || curl -sf "$LK_URL/management/v1/info" >/dev/null 2>&1; then ok=1; break; fi
        sleep 3
    done
    stop_spinner
    [ "$ok" = 1 ] || { error "Lakekeeper did not become ready"; $COMPOSE logs lakekeeper | tail -20; exit 1; }
    info "[3/4] Lakekeeper is ready"

    start_spinner "[4/4] Creating the warehouse + namespace"
    curl -sf -X POST "$LK_URL/management/v1/bootstrap" \
        -H 'Content-Type: application/json' -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
    curl -sf -X POST "$LK_URL/management/v1/warehouse" \
        -H 'Content-Type: application/json' -d '{
          "warehouse-name":"wh",
          "storage-profile":{"type":"s3","bucket":"iceberg","region":"us-east-1",
            "endpoint":"http://seaweedfs:8333","path-style-access":true,
            "flavor":"s3-compat","sts-enabled":false,"remote-signing-enabled":false},
          "storage-credential":{"type":"s3","credential-type":"access-key",
            "aws-access-key-id":"admin","aws-secret-access-key":"adminsecret"}
        }' >/dev/null 2>&1 || true
    local wid
    wid=$(curl -s "$LK_URL/management/v1/warehouse" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    curl -sf -X POST "$LK_URL/catalog/v1/$wid/namespaces" \
        -H 'Content-Type: application/json' -d '{"namespace":["default"]}' >/dev/null 2>&1 || true
    stop_spinner; info "[4/4] Warehouse 'wh' + namespace 'default' ready"
    echo ""
}

bash "$SCRIPT_DIR/setup.sh" && phase_a_bringup
