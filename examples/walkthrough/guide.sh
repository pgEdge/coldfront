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

export PGPASSWORD=coldfront

cleanup() { stop_spinner; }
trap cleanup EXIT

pg()       { PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -tAX -c "$1"; }
psql_file(){ PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -v ON_ERROR_STOP=1; }

# run_sql_shown — interactively show+run a SQL command; non-interactively just run it.
run_sql_shown() {
    local sql="$1" why="$2"
    if [ "$NONINTERACTIVE" = 1 ]; then
        pg "$sql" >/dev/null || { error "step failed: $sql"; exit 1; }
    else
        prompt_run "psql -h localhost -p $PG_PORT -U coldfront -d coldfront -c \"$sql\""
    fi
    [ -n "$why" ] && explain "  ${DIM}$why${RESET}"
}

phase_b_setup() {
    header "ColdFront setup"
    explain "These are the ColdFront-specific steps — the 'how to set it up' part."
    echo ""

    run_sql_shown "CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS coldfront;" \
        "pg_duckdb gives Postgres an in-process engine to read Iceberg; coldfront is the routing/rewrite layer."

    run_sql_shown "SELECT coldfront.set_storage_secret('admin','adminsecret','seaweedfs:8333');" \
        "Throwaway creds for the LOCAL SeaweedFS emulator. In production you pass your real bucket's keys + endpoint here — nothing in your application SQL changes."
    echo ""
}

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

demo_tiered()      { info "[tiered demo placeholder]"; }
demo_decoupled()   { info "[decoupled demo placeholder]"; }
demo_partitioner() { info "[partitioner demo placeholder]"; }

reset_demos() {
    pg "DROP TABLE IF EXISTS events CASCADE; DROP TABLE IF EXISTS _events CASCADE;
        DROP VIEW  IF EXISTS events_lake CASCADE;
        DROP TABLE IF EXISTS part_demo CASCADE;
        DELETE FROM coldfront.tiered_views WHERE relname IN ('events','events_lake');
        DELETE FROM coldfront.archive_watermark WHERE table_name='events';" >/dev/null 2>&1 || true
    info "Demo tables dropped."
}

quit_walkthrough() {
    echo ""
    if [ "$NONINTERACTIVE" = 1 ]; then exit 0; fi
    read -rp "Remove the whole stack now (docker compose down -v)? [y/N]: " a </dev/tty
    [[ "$a" =~ ^[Yy]$ ]] && $COMPOSE down -v
    exit 0
}

main_menu() {
    while true; do
        header "ColdFront — what would you like to see?"
        explain "  1) Tiered storage   — relocate cold data to object storage, same table, still writeable"
        explain "  2) Decoupled        — Postgres as a front-end to the lake (data in Iceberg from day one)"
        explain "  3) Partitioner      — automated PG range-partitioning, no cold tier"
        explain "  R) Reset            — drop demo tables / reclaim disk"
        explain "  Q) Quit             — (offers docker compose down -v)"
        echo ""
        read -rp "Choose [1/2/3/R/Q]: " c </dev/tty
        case "$c" in
            1) demo_tiered;;
            2) demo_decoupled;;
            3) demo_partitioner;;
            [Rr]) reset_demos;;
            [Qq]) quit_walkthrough;;
            *) warn "Pick 1, 2, 3, R, or Q.";;
        esac
    done
}

# main
bash "$SCRIPT_DIR/setup.sh"
phase_a_bringup
phase_b_setup
if [ "$NONINTERACTIVE" = 1 ]; then
    case "${WALKTHROUGH_DEMO:-tiered}" in
        tiered) demo_tiered;; decoupled) demo_decoupled;; partitioner) demo_partitioner;;
    esac
    exit 0
fi
main_menu
