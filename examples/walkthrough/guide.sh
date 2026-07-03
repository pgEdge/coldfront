#!/usr/bin/env bash
set -uo pipefail   # not -e: demo bodies must continue past an assertion

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=runner.sh
source "$SCRIPT_DIR/runner.sh"

COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"
MESH_COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.mesh.yml"
OS="$(uname -s)"
PG_PORT="${COLDFRONT_PG_PORT:-5432}"
LK_PORT="${COLDFRONT_LK_PORT:-8181}"
LK_URL="http://localhost:${LK_PORT}"

# Mesh (Demo 4) — a separate 2-node stack, brought up on demand. Ports are picked
# lazily by detect_mesh_ports() from a base that avoids the single-node stack, so
# the two never contend even mid-switch. ACTIVE_STACK tracks which stack is up
# (single | mesh | none) so the menu only pays a switch on an actual transition.
MESH_PG1_PORT="${COLDFRONT_MESH_PG1_PORT:-5442}"
MESH_PG2_PORT="${COLDFRONT_MESH_PG2_PORT:-5443}"
MESH_LK_PORT="${COLDFRONT_MESH_LK_PORT:-8191}"
MESH_S3_PORT="${COLDFRONT_MESH_S3_PORT:-8343}"
MESH_LK_URL="http://localhost:${MESH_LK_PORT}"
ACTIVE_STACK="none"
# shellcheck disable=SC2034  # consumed by Phase B+ tasks
NONINTERACTIVE="${WALKTHROUGH_NONINTERACTIVE:-0}"
# shellcheck disable=SC2034  # set by choose_volume, consumed by Task-9 demos
GEN_ROWS=1000000

export PGPASSWORD=coldfront
# Silence pg_duckdb's "NOTICE: result: Success" chatter on every cross-tier query
# so the walkthrough output stays clean. Applies to all psql invocations below.
export PGOPTIONS='-c client_min_messages=warning'

cleanup() { stop_spinner; }
trap cleanup EXIT

pg()       { PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -tAX -c "$1"; }
psql_file(){ PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -v ON_ERROR_STOP=1; }

# heap_size <relname> — pretty total heap of a relation INCLUDING its partitions.
# pg_total_relation_size() on a partitioned parent counts only the (empty) parent,
# so for `events`/`_events` (range-partitioned) it reports 0; sum the partition
# tree instead. Works for plain tables too (the tree subquery is then empty).
heap_size() {
    pg "SELECT pg_size_pretty(
            pg_total_relation_size('$1') +
            COALESCE((SELECT sum(pg_total_relation_size(relid))
                      FROM pg_partition_tree('$1') WHERE relid <> '$1'::regclass), 0));"
}

# show_query — show the SQL, then run it and print the result as an aligned psql
# table, framed, for the viewer to read. The query MUST be shown before its result
# so the viewer knows what produced it. Use this for anything shown on screen.
# (pg() stays -tAX, only for values captured into shell variables.)
show_query() {
    # Normalize the (often multi-line, indented) SQL literal to one clean line for
    # display, then show it as the command that produced the result below.
    local q
    q=$(printf '%s' "$1" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ *$//')
    echo ""
    echo -e "${ORANGE}\$ psql -c \"${q}\"${RESET}"
    echo -e "${DIM}─── result ─────────────────────────────────────────────────${RESET}"
    PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -c "$1"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

# _iceberg_meta_loc <table_name> — echo the table's metadata.json S3 path from the
# Lakekeeper catalog (warehouse id → GET …/catalog/v1/<wh_id>/namespaces/default/
# tables/<table_name> → metadata-location). Empty string if it can't be resolved.
# Shared by show_parquet_files and show_parquet_contents. Consumes LK_URL.
_iceberg_meta_loc() {
    local table_name="$1" wh_id
    wh_id=$(curl -s "${LK_URL}/management/v1/warehouse" \
        | grep -o '"warehouse-id":"[^"]*"' | head -1 | cut -d'"' -f4)
    curl -s "${LK_URL}/catalog/v1/${wh_id}/namespaces/default/tables/${table_name}" \
        -H 'accept: application/json' \
        | grep -o '"metadata-location":"[^"]*"' | head -1 | cut -d'"' -f4
}

# show_parquet_files <table_name> — list the table's .parquet data files via
# iceberg_metadata(). On a failed resolution prints a warn and returns non-zero
# (non-fatal — callers continue). Consumes _iceberg_meta_loc, show_query, warn.
show_parquet_files() {
    local meta_loc; meta_loc=$(_iceberg_meta_loc "$1")
    if [ -n "$meta_loc" ]; then
        show_query "SELECT file_path FROM iceberg_metadata('${meta_loc}')
                     WHERE file_path LIKE '%.parquet' LIMIT 3;"
    else
        warn "Could not resolve the Iceberg metadata location from the catalog; skipping the Parquet listing."
        return 1
    fi
}

# show_parquet_contents <table_name> — the physical proof: read ONE actual data file
# straight from object storage with read_parquet(), bypassing the Iceberg catalog /
# version layer (so no version-hint error). pg_duckdb needs the r['col'] alias form.
# We read a NON-delete data file: raw reads ignore merge-on-read delete files, so this
# is an existence proof ("these rows live as Parquet in S3"), not a current-value one.
# Non-fatal on any resolution failure. Consumes _iceberg_meta_loc, pg, show_query, warn.
show_parquet_contents() {
    local meta_loc file
    meta_loc=$(_iceberg_meta_loc "$1")
    [ -n "$meta_loc" ] || { warn "Could not resolve the Iceberg metadata; skipping the Parquet read."; return 1; }
    file=$(pg "SELECT file_path FROM iceberg_metadata('${meta_loc}')
               WHERE file_path LIKE '%.parquet' AND file_path NOT LIKE '%-deletes.parquet'
               ORDER BY file_path LIMIT 1;")
    [ -n "$file" ] || { warn "No Parquet data file found; skipping the Parquet read."; return 1; }
    explain "  ${DIM}Reading one real Parquet object straight from the bucket: ${file##*/}${RESET}"
    show_query "SELECT count(*) AS rows_in_this_parquet,
                       min(r['ts']) AS oldest_row,
                       max(r['ts']) AS newest_row
                FROM read_parquet('${file}') r;"
    show_query "SELECT r['id'] AS id, r['ts'] AS ts, r['status'] AS status
                FROM read_parquet('${file}') r ORDER BY r['ts'] LIMIT 3;"
}

# ── Port detection ───────────────────────────────────────────────────────────

port_in_use() {
    if [[ "$OS" == "Darwin" ]]; then
        lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
        ss -tln 2>/dev/null | grep -q ":${1} "
    fi
}

pick_port() {
    local p="$1"
    while port_in_use "$p"; do
        p=$(( p + 1 ))
        if [[ "$p" -gt 65535 ]]; then
            error "Could not find a free port scanning from $1."
            exit 1
        fi
    done
    echo "$p"
}

detect_ports() {
    local pg_default="${COLDFRONT_PG_PORT:-5432}"
    local lk_default="${COLDFRONT_LK_PORT:-8181}"
    local s3_default="${COLDFRONT_S3_PORT:-8333}"

    local pg_picked lk_picked s3_picked
    pg_picked=$(pick_port "$pg_default")
    lk_picked=$(pick_port "$lk_default")
    s3_picked=$(pick_port "$s3_default")

    if [[ "$pg_picked" != "$pg_default" ]]; then
        warn "Postgres port ${pg_default} in use → using ${pg_picked}"
    fi
    if [[ "$lk_picked" != "$lk_default" ]]; then
        warn "Lakekeeper port ${lk_default} in use → using ${lk_picked}"
    fi
    if [[ "$s3_picked" != "$s3_default" ]]; then
        warn "SeaweedFS port ${s3_default} in use → using ${s3_picked}"
    fi

    export COLDFRONT_PG_PORT="$pg_picked"
    export COLDFRONT_LK_PORT="$lk_picked"
    export COLDFRONT_S3_PORT="$s3_picked"

    PG_PORT="$pg_picked"
    LK_PORT="$lk_picked"
    LK_URL="http://localhost:${lk_picked}"
}

# db_unreachable_msg — print the standard "database is unreachable" diagnostic.
# Used whenever a shown step or the liveness probe can't reach Postgres, so a
# dead/unreachable db surfaces as clear guidance instead of a raw psql
# "connection refused" that the user would otherwise Enter straight past.
db_unreachable_msg() {
    error "The database is unreachable — the walkthrough can't continue."
    warn  "  Check that:"
    warn  "    - Docker is running"
    warn  "    - the stack is up and healthy:      docker compose ps"
    warn  "    - you are not out of Docker disk:   docker system prune -af --volumes"
    warn  "  Then re-run the walkthrough."
}

# require_db_reachable — lightweight liveness gate: a short bounded wait for
# Postgres to answer SELECT 1. Returns 0 if it answers within the window, else
# prints the unreachable diagnostic and returns 1 so callers return to the menu
# instead of marching into raw connection-refused errors. ~10s max (5 x 2s).
require_db_reachable() {
    local i
    for i in 1 2 3 4 5; do
        if pg "SELECT 1" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    db_unreachable_msg
    return 1
}

# run_sql_shown — explain what the command does FIRST, then show + run it.
# The "why" MUST print before the command/output so the viewer knows what they're
# about to run before hitting Enter — never after. Returns non-zero if the SQL
# fails (e.g. the db went away mid-demo): callers MUST check and stop rather than
# let the user Enter-through a failed step into raw connection-refused noise.
run_sql_shown() {
    local sql="$1" why="$2"
    [ -n "$why" ] && explain "  ${DIM}$why${RESET}"
    if [ "$NONINTERACTIVE" = 1 ]; then
        pg "$sql" >/dev/null || { error "step failed: $sql"; exit 1; }
    else
        show_cmd "psql -h localhost -p $PG_PORT -U coldfront -d coldfront -c \"$sql\""
        echo ""
        read -rp "Press Enter to run..." </dev/tty
        echo ""
        echo -e "${DIM}─── Output ─────────────────────────────────────────────────${RESET}"
        pg "$sql"
        local rc=$?
        echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"
        echo ""
        if [ "$rc" != 0 ]; then
            db_unreachable_msg
            return 1
        fi
    fi
}

# ── Mesh (Demo 4) node-addressed helpers ────────────────────────────────────
# The single-node helpers above are hardwired to $PG_PORT. The Distributed demo
# drives TWO nodes, so these siblings take a node label + host port and PRINT the
# node the query ran on — the whole point is showing "this ran on db2".

# mpg <port> <sql> — value capture against a mesh node by host port (like pg()).
mpg() { PGPASSWORD=coldfront psql -h localhost -p "$1" -U coldfront -d coldfront -tAX -c "$2"; }

# mshow <label> <port> <sql> — show the SQL + framed result, labelled by node.
mshow() {
    local label="$1" port="$2" q
    q=$(printf '%s' "$3" | tr '\n' ' ' | tr -s ' ' | sed 's/^ //;s/ *$//')
    echo ""
    echo -e "${ORANGE}\$ psql (${label}) -c \"${q}\"${RESET}"
    echo -e "${DIM}─── result (${label}) ──────────────────────────────────────${RESET}"
    PGPASSWORD=coldfront psql -h localhost -p "$port" -U coldfront -d coldfront -c "$3"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"
    echo ""
}

# mrun <label> <port> <sql> <why> — explain-first, then show + run a mutation on a
# named node. Mirrors run_sql_shown's contract (why prints BEFORE the command;
# non-zero return on failure so callers stop instead of Enter-through errors).
mrun() {
    local label="$1" port="$2" sql="$3" why="$4"
    [ -n "$why" ] && explain "  ${DIM}$why${RESET}"
    if [ "$NONINTERACTIVE" = 1 ]; then
        mpg "$port" "$sql" >/dev/null || { error "step failed on ${label}: $sql"; exit 1; }
    else
        show_cmd "psql (${label}) -c \"$sql\""
        echo ""
        read -rp "Press Enter to run..." </dev/tty
        echo ""
        echo -e "${DIM}─── Output (${label}) ──────────────────────────────────────${RESET}"
        mpg "$port" "$sql"
        local rc=$?
        echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"
        echo ""
        if [ "$rc" != 0 ]; then
            db_unreachable_msg
            return 1
        fi
    fi
}

# coldfront_installed — true once both extensions exist in this database.
coldfront_installed() {
    [ "$(pg "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_duckdb','coldfront');")" = "2" ]
}

# ensure_coldfront_setup [shown] — idempotently install ColdFront onto the running
# database: the two extensions + the cold-store secret. Pass "shown" to narrate each
# command (the tiered demo does this as Steps 4-5); omit to run silently (the other
# demos just need ColdFront present). Safe to call repeatedly.
ensure_coldfront_setup() {
    local mode="${1:-silent}"
    if [ "$mode" = shown ]; then
        # Liveness gate: confirm the db is reachable before the shown steps so a
        # dead/unreachable stack yields a clear diagnostic, not raw psql errors.
        require_db_reachable || return 1

        # CREATE EXTENSION and set_storage_secret return no rows / void — showing their
        # raw output is a blank box. So we run them, then show a CONFIRMATION query
        # (installed extensions / the stored cold-store target) as the visible result.
        explain "Now we install ColdFront onto your running database — two extensions:"
        explain "pg_duckdb (an in-process engine so Postgres can read Parquet in object"
        explain "storage) and coldfront (routes each query to the right tier and rewrites"
        explain "writes). No migration, no new database:"
        if [ "$NONINTERACTIVE" != 1 ]; then
            show_cmd "psql -c \"CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS coldfront;\""
            echo ""
            read -rp "Press Enter to run..." </dev/tty
            echo ""
        fi
        pg "CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS coldfront;" >/dev/null \
            || { db_unreachable_msg; return 1; }
        explain "See it worked — both extensions are now installed:"
        show_query "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_duckdb','coldfront') ORDER BY extname;"

        # set the secret only if not already present (idempotent — mirrors silent branch)
        if [ "$(pg "SELECT count(*) FROM coldfront.storage_secret;" 2>/dev/null)" != "1" ]; then
            explain "Now we tell ColdFront where the cold data lives. In production you'd pass"
            explain "your real bucket's key, secret, and endpoint here; for this walkthrough we"
            explain "point it at the local SeaweedFS emulator with throwaway creds. Either way,"
            explain "your application SQL doesn't change:"
            if [ "$NONINTERACTIVE" != 1 ]; then
                show_cmd "psql -c \"SELECT coldfront.set_storage_secret('admin','adminsecret','seaweedfs:8333');\""
                echo ""
                read -rp "Press Enter to run..." </dev/tty
                echo ""
            fi
            pg "SELECT coldfront.set_storage_secret('admin','adminsecret','seaweedfs:8333');" >/dev/null \
                || { db_unreachable_msg; return 1; }
        else
            explain "  ${DIM}Cold-store secret already set — skipping (idempotent).${RESET}"
        fi
        explain "See where the cold data will go — the stored target (credentials never shown):"
        show_query "SELECT name, storage_type, endpoint, region, url_style FROM coldfront.storage_secret;"
    else
        pg "CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS coldfront;" >/dev/null 2>&1
        # set the secret only if not already present (idempotent)
        if [ "$(pg "SELECT count(*) FROM coldfront.storage_secret;" 2>/dev/null)" != "1" ]; then
            pg "SELECT coldfront.set_storage_secret('admin','adminsecret','seaweedfs:8333');" >/dev/null 2>&1
        fi
    fi
}

# ensure_warehouse_and_namespace <lk_url> — bootstrap Lakekeeper, then POST
# warehouse 'wh' (retrying until config?warehouse=wh resolves — the POST validates
# its S3 profile against SeaweedFS and 4xx/5xxs until the S3 endpoint is live) and
# create the 'default' namespace. Returns non-zero if 'wh' never resolves. Shared
# by phase_a_bringup (single-node) and mesh_bringup (2-node); both seed the same
# warehouse against their own Lakekeeper on the SeaweedFS at http://seaweedfs:8333.
ensure_warehouse_and_namespace() {
    local lk="$1" ok=0 wid
    curl -sf -X POST "$lk/management/v1/bootstrap" \
        -H 'Content-Type: application/json' -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' "$lk/catalog/v1/config?warehouse=wh")" = 200 ]; then ok=1; break; fi
        curl -sf -X POST "$lk/management/v1/warehouse" \
            -H 'Content-Type: application/json' -d '{
              "warehouse-name":"wh",
              "storage-profile":{"type":"s3","bucket":"iceberg","region":"us-east-1",
                "endpoint":"http://seaweedfs:8333","path-style-access":true,
                "flavor":"s3-compat","sts-enabled":false,"remote-signing-enabled":false},
              "storage-credential":{"type":"s3","credential-type":"access-key",
                "aws-access-key-id":"admin","aws-secret-access-key":"adminsecret"}
            }' >/dev/null 2>&1 || true
        sleep 3
    done
    [ "$ok" = 1 ] || return 1
    wid=$(curl -s "$lk/management/v1/warehouse" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    curl -sf -X POST "$lk/catalog/v1/$wid/namespaces" \
        -H 'Content-Type: application/json' -d '{"namespace":["default"]}' >/dev/null 2>&1 || true
    return 0
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
    if ! ensure_warehouse_and_namespace "$LK_URL"; then
        stop_spinner
        error "Warehouse 'wh' did not become resolvable in Lakekeeper"
        $COMPOSE logs lakekeeper seaweedfs | tail -20
        exit 1
    fi
    stop_spinner
    info "[4/4] Warehouse 'wh' + namespace 'default' ready"
    echo ""
}

# ── Mesh (Demo 4) bring-up ──────────────────────────────────────────────────

# detect_mesh_ports — pick free host ports for the on-demand mesh stack from a
# base that avoids the single-node stack (5432/8181/8333), so the two can briefly
# coexist during a switch without colliding. Exports the COLDFRONT_MESH_* vars the
# mesh compose reads and updates the globals guide.sh drives the nodes over.
detect_mesh_ports() {
    MESH_PG1_PORT=$(pick_port "${COLDFRONT_MESH_PG1_PORT:-5442}")
    MESH_PG2_PORT=$(pick_port "$(( MESH_PG1_PORT + 1 ))")
    MESH_LK_PORT=$(pick_port "${COLDFRONT_MESH_LK_PORT:-8191}")
    MESH_S3_PORT=$(pick_port "${COLDFRONT_MESH_S3_PORT:-8343}")
    MESH_LK_URL="http://localhost:${MESH_LK_PORT}"
    export COLDFRONT_MESH_PG1_PORT="$MESH_PG1_PORT"
    export COLDFRONT_MESH_PG2_PORT="$MESH_PG2_PORT"
    export COLDFRONT_MESH_LK_PORT="$MESH_LK_PORT"
    export COLDFRONT_MESH_S3_PORT="$MESH_S3_PORT"
}

# mesh_bringup — switch from the single-node stack to a 2-node Spock mesh: tear the
# single-node stack down (a laptop can't hold both), bring up db1/db2 + a shared
# Lakekeeper + SeaweedFS, install the extensions, form the Spock mesh, and arm the
# bakery substrate on both nodes. Mirrors ci/topo/mesh.sh trimmed to 2 nodes and
# driven over host ports. Returns non-zero (does not exit) on any failure so the
# caller can fall back to the menu.
mesh_bringup() {
    header "Bringing up a 2-node distributed cluster"
    explain "The single-node stack from the other demos comes down first — a laptop"
    explain "can't hold both at once. In production these are separate machines"
    explain "(different regions or clouds); here they're two containers on one host,"
    explain "both pointed at ONE shared lake."
    echo ""

    detect_mesh_ports

    local ok=0 i port ext subs

    start_spinner "[1/6] Freeing existing stacks"
    $COMPOSE down -v >/dev/null 2>&1 || true
    $MESH_COMPOSE down -v >/dev/null 2>&1 || true   # clear any prior mesh so this run starts on fresh volumes
    stop_spinner; info "[1/6] Existing stacks down"

    start_spinner "[2/6] Starting 2 Postgres nodes + shared lake (Lakekeeper, S3)"
    $MESH_COMPOSE up -d --build >/dev/null 2>&1
    stop_spinner; info "[2/6] Containers started"

    start_spinner "[3/6] Waiting for both nodes to accept connections"
    for i in $(seq 1 40); do
        if mpg "$MESH_PG1_PORT" "SELECT 1" >/dev/null 2>&1 && mpg "$MESH_PG2_PORT" "SELECT 1" >/dev/null 2>&1; then ok=1; break; fi
        sleep 3
    done
    stop_spinner
    [ "$ok" = 1 ] || { error "Mesh Postgres nodes did not become ready"; $MESH_COMPOSE logs db1 db2 | tail -20; return 1; }
    info "[3/6] Both nodes ready"

    start_spinner "[4/6] Waiting for the shared Lakekeeper catalog + warehouse"
    ok=0
    for i in $(seq 1 40); do
        if curl -sf "$MESH_LK_URL/health" >/dev/null 2>&1 || curl -sf "$MESH_LK_URL/management/v1/info" >/dev/null 2>&1; then ok=1; break; fi
        sleep 3
    done
    [ "$ok" = 1 ] && { ensure_warehouse_and_namespace "$MESH_LK_URL" || ok=0; }
    stop_spinner
    [ "$ok" = 1 ] || { error "Shared Lakekeeper/warehouse did not become ready"; $MESH_COMPOSE logs lakekeeper seaweedfs | tail -20; return 1; }
    info "[4/6] Shared lake ready (warehouse 'wh', namespace 'default')"

    start_spinner "[5/6] Installing ColdFront + forming the Spock mesh"
    # Extensions on both nodes, one per call (a chained CREATE aborts the rest on
    # the first failure). dblink+snowflake+spock are the mesh substrate.
    for port in "$MESH_PG1_PORT" "$MESH_PG2_PORT"; do
        for ext in dblink snowflake spock pg_duckdb coldfront; do
            mpg "$port" "CREATE EXTENSION IF NOT EXISTS $ext;" >/dev/null 2>&1
        done
    done
    # Spock nodes reach each OTHER over the compose network (host=db1/db2, the
    # in-container port 5432) — NOT the published host ports we drive from here.
    mpg "$MESH_PG1_PORT" "SELECT CASE WHEN EXISTS(SELECT 1 FROM spock.node WHERE node_name='db1') THEN 'exists' ELSE spock.node_create('db1','host=db1 user=coldfront dbname=coldfront port=5432')::text END;" >/dev/null 2>&1
    mpg "$MESH_PG2_PORT" "SELECT CASE WHEN EXISTS(SELECT 1 FROM spock.node WHERE node_name='db2') THEN 'exists' ELSE spock.node_create('db2','host=db2 user=coldfront dbname=coldfront port=5432')::text END;" >/dev/null 2>&1
    mpg "$MESH_PG1_PORT" "SELECT spock.sub_create('sub_db1_from_db2','host=db2 user=coldfront dbname=coldfront port=5432');" >/dev/null 2>&1
    mpg "$MESH_PG2_PORT" "SELECT spock.sub_create('sub_db2_from_db1','host=db1 user=coldfront dbname=coldfront port=5432');" >/dev/null 2>&1
    mpg "$MESH_PG1_PORT" "SELECT spock.sub_wait_for_sync(sub_name) FROM spock.subscription;" >/dev/null 2>&1
    mpg "$MESH_PG2_PORT" "SELECT spock.sub_wait_for_sync(sub_name) FROM spock.subscription;" >/dev/null 2>&1
    stop_spinner
    subs=$(mpg "$MESH_PG1_PORT" "SELECT count(*) FROM spock.subscription;" 2>/dev/null)
    [ "$subs" = 1 ] || { error "Spock mesh not formed (db1 has '${subs:-0}' subscriptions, expected 1)"; return 1; }
    info "[5/6] ColdFront installed; Spock mesh formed (bidirectional)"

    start_spinner "[6/6] Arming the bakery + cold-store secret on both nodes"
    for port in "$MESH_PG1_PORT" "$MESH_PG2_PORT"; do
        # claims/claim_acks into the repset BEFORE any cold write — a peer must be
        # armed to ack an originator's claim, else the originator waits forever.
        mpg "$port" "SELECT coldfront._ensure_claims_replicated();" >/dev/null 2>&1
        mpg "$port" "SELECT spock.repset_add_table('default','coldfront.partition_config'::regclass, false);" >/dev/null 2>&1
        mpg "$port" "SELECT spock.repset_add_table('default','coldfront.storage_secret'::regclass, false);" >/dev/null 2>&1
        mpg "$port" "SELECT coldfront.set_storage_secret('admin','adminsecret','seaweedfs:8333');" >/dev/null 2>&1
    done
    stop_spinner; info "[6/6] Bakery substrate armed; cold-store secret set"
    echo ""
}

# ── Disk / sizing estimate ─────────────────────────────────────────────────
#
# Peak footprint is the transient high-water mark of a load, NOT the final
# heap size: it includes the composite PK index (id, ts) built alongside the
# heap, WAL for the INSERT, any temp/sort spill, AND the archiver's later
# Parquet write. Empirical calibration point: a 1M-row load FAILED at ~795 MB
# free (Docker disk-full), so the real peak is well above ~0.8 KB/row.
# We therefore use a conservative >=1 KB/row peak and
# require ~2x headroom: a size only "fits" when rows*1KB <= free/2. These
# constants are a starting estimate calibrated against that single data point;
# revisit PER_ROW_PEAK_KB / HEADROOM_DIV if loads still fail (or waste space).
PER_ROW_PEAK_KB=1        # conservative peak per row, in KB (heap+PK index+WAL+temp+Parquet)
HEADROOM_DIV=2           # require free/HEADROOM_DIV to cover the peak (~2x headroom)

# docker_free_mb — free MB on Docker's data root, probed from a throwaway
# container. Echoes 0 if Docker is unreachable.
docker_free_mb() {
  docker run --rm alpine:3.20 sh -c "df -m / | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0
}

# peak_mb <rows> — estimated peak footprint in MB for a row count.
peak_mb() {
  echo $(( $1 * PER_ROW_PEAK_KB / 1024 ))
}

# fits <rows> <free_mb> — 0 (true) if the row count fits with headroom.
fits() {
  local rows="$1" free_mb="$2"
  [ "$free_mb" -le 0 ] && return 0           # probe failed → don't block
  [ "$(peak_mb "$rows")" -le $(( free_mb / HEADROOM_DIV )) ]
}

# suggested_rows <free_mb> — largest "nice" round row count that fits with
# headroom. rows_max = free_mb*1024 / PER_ROW_PEAK / HEADROOM_DIV; with the
# defaults that is free_mb*512. Rounded down to a nice power-of-ten step, floor
# 50k so we always offer something runnable.
suggested_rows() {
  local free_mb="$1"
  if [ "$free_mb" -le 0 ]; then echo 1000000; return; fi
  local raw=$(( free_mb * 1024 / PER_ROW_PEAK_KB / HEADROOM_DIV ))
  local step=1000000
  if   [ "$raw" -lt 500000 ];  then step=50000
  elif [ "$raw" -lt 5000000 ]; then step=100000
  fi
  local rounded=$(( raw / step * step ))
  [ "$rounded" -lt 50000 ] && rounded=50000
  echo "$rounded"
}

# fit_note <rows> <free_mb> — human "does it fit" annotation for the menu.
fit_note() {
  local rows="$1" free_mb="$2" need
  [ "$free_mb" -le 0 ] && { echo ""; return; }
  need=$(peak_mb "$rows")
  if fits "$rows" "$free_mb"; then
    echo "(fits)"
  elif [ "$need" -ge 1024 ]; then
    echo "(needs ~$(( need / 1024 )) GB — more than your ~${free_mb} MB free)"
  else
    echo "(needs ~${need} MB — more than your ~${free_mb} MB free)"
  fi
}

# choose_volume — sets GEN_ROWS. The only feature-relevant prompt in the guide.
# Probes Docker's free disk FIRST, computes a Suggested row count that fits with
# headroom, and re-prompts if the user picks a fixed/custom size that won't fit
# (rather than proceeding into a load that will disk-full and roll back).
choose_volume() {
  if [ "$NONINTERACTIVE" = 1 ]; then GEN_ROWS="${WALKTHROUGH_ROWS:-1000000}"; return; fi

  local free_mb sugg
  start_spinner "Checking Docker's free disk"
  free_mb=$(docker_free_mb)
  stop_spinner
  sugg=$(suggested_rows "$free_mb")

  header "How much data should we generate?"
  explain "  The more you generate, the more storage visibly relocates to object"
  explain "  storage when we tier. Peak is the transient hot-heap high-water mark"
  explain "  BEFORE tiering (heap + PK index + WAL + temp + the Parquet write)."
  if [ "$free_mb" -gt 0 ]; then
    explain "  ${DIM}Docker has ~${free_mb} MB free on its data root.${RESET}"
  else
    warn "  Could not probe Docker's free disk — fit checks disabled."
  fi
  echo ""

  # shellcheck disable=SC2034  # GEN_ROWS consumed by Task-9 demo functions

  # If even the floored Suggested size doesn't fit, free disk is critically low.
  # Do NOT present a fitting-looking default — show an explicit message and
  # fall back to Custom-only so the user must type a row count they know fits,
  # or free space and re-run.
  if [ "$free_mb" -gt 0 ] && ! fits "$sugg" "$free_mb"; then
    warn "Free Docker disk (~${free_mb} MB) is too low even for the minimum"
    warn "suggested size (~${sugg} rows, needs ~$(peak_mb "$sugg") MB peak)."
    warn "Free space first:"
    warn "    docker system prune -af --volumes"
    warn "Or raise the Docker Desktop disk limit, then re-run the walkthrough."
    warn "If you still want to proceed, enter a custom row count (e.g. 10000)."
    echo ""
    while true; do
      printf "  C) Custom     enter a row count\n"
      echo ""
      read -rp "Rows (or Q to quit): " v </dev/tty
      case "$v" in
        [Qq]*) exit 0;;
        *)
          if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -le 0 ]; then
            warn "Enter a positive whole number."; echo ""; continue
          fi
          GEN_ROWS="$v"; return;;
      esac
    done
  fi

  while true; do
    printf "  S) Suggested  ~%s rows   %s   [default]\n" "$sugg" "$(fit_note "$sugg" "$free_mb")"
    printf "  1) Quick      ~1M rows    %s\n"  "$(fit_note 1000000 "$free_mb")"
    printf "  2) Standard   ~10M rows   %s\n"  "$(fit_note 10000000 "$free_mb")"
    printf "  3) Big        ~50M rows   %s\n"  "$(fit_note 50000000 "$free_mb")"
    printf "  4) Custom     enter a row count\n"
    echo ""
    read -rp "Choose [S/1/2/3/4]: " v </dev/tty

    local pick=""
    case "$v" in
      ""|[Ss]) GEN_ROWS="$sugg"; return;;
      1) pick=1000000;;
      2) pick=10000000;;
      3) pick=50000000;;
      4) read -rp "Rows: " pick </dev/tty
         if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -le 0 ]; then
             warn "Enter a positive whole number."; echo ""; continue
         fi
         ;;
      *) warn "Pick S, 1, 2, 3, or 4."; echo ""; continue;;
    esac

    if fits "$pick" "$free_mb"; then
      GEN_ROWS="$pick"; return
    fi
    warn "That size needs ~$(peak_mb "$pick") MB, you have ~${free_mb} MB free —"
    warn "pick a smaller size (Suggested is ~${sugg} rows), or free Docker disk with:"
    warn "    docker system prune -af --volumes"
    echo ""
  done
}

# generate_events — seed `events` across 4 historical months + the current one,
# all derived from now() (never invented literals). Explicit id keeps inserts
# on the fast set-based path. Spread <rows> over ~5 months by 'spacing'.
generate_events() {
  local rows="$1"
  local out; out=$(mktemp)
  start_spinner "Generating ${rows} rows"
  # psql_file uses ON_ERROR_STOP=1, so a disk-full (or any) INSERT error makes
  # psql exit non-zero. Capture stdout+stderr and check the exit code — never
  # report success unconditionally: a swallowed failure would misreport it
  # as "Generated N rows" when the txn had actually rolled back to 0 rows.
  psql_file >"$out" 2>&1 <<EOSQL
SET search_path = public;
-- Spread evenly across now-4mo .. now, two-minute spacing scaled to row count.
INSERT INTO events (id, ts, status, data)
SELECT i,
       now() - ((${rows} - i) * (interval '150 days' / ${rows})),
       (ARRAY['ok','warn','error'])[1 + i % 3],
       '{}'::jsonb
FROM generate_series(1, ${rows}) i;
EOSQL
  local rc=$?
  stop_spinner
  if [ "$rc" -ne 0 ]; then
    error "Load failed — the INSERT did not complete (rows rolled back):"
    tail -5 "$out" | sed 's/^/    /'
    rm -f "$out"
    return 1
  fi
  rm -f "$out"
  info "Loaded ${rows} rows."
}

# drop_iceberg_table <table_name> — drop the Iceberg cold table from the Lakekeeper
# REST catalog (with purge). The archiver and create_iceberg_table both do
# CREATE TABLE IF NOT EXISTS on the cold side, so a leftover table would be APPENDED
# to on a kept-infra re-run (inflated counts, duplicate ids). Dropping the catalog
# entry makes a re-run start clean. Best-effort: silent if the catalog/table is absent.
drop_iceberg_table() {
    local wh_id
    wh_id=$(curl -s "${LK_URL}/management/v1/warehouse" \
        | grep -o '"warehouse-id":"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -n "$wh_id" ] || return 0
    curl -s -o /dev/null -X DELETE \
        "${LK_URL}/catalog/v1/${wh_id}/namespaces/default/tables/$1?purgeRequested=true" || true
}

# teardown_tiered / teardown_decoupled — idempotent cleanup for a demo's objects.
# coldfront BLOCKS a DROP of a registered tiered/iceberg view ("cannot DROP … it has
# a cold tier"), so we UNREGISTER first (delete the registry + watermark rows, which
# lifts the block), THEN drop the PG objects — one statement per psql call and
# best-effort, so a wrong-relkind DROP (events can be a view OR a plain table) can't
# abort the rest — and finally drop the Iceberg cold table so re-runs start clean.
teardown_tiered() {
    pg "DELETE FROM coldfront.archive_watermark WHERE table_name='events';
        DELETE FROM coldfront.tiered_views     WHERE relname='events';" >/dev/null 2>&1 || true
    pg "DROP VIEW  IF EXISTS events  CASCADE;" >/dev/null 2>&1 || true
    pg "DROP TABLE IF EXISTS events  CASCADE;" >/dev/null 2>&1 || true
    pg "DROP TABLE IF EXISTS _events CASCADE;" >/dev/null 2>&1 || true
    drop_iceberg_table events
}
teardown_decoupled() {
    pg "DELETE FROM coldfront.tiered_views WHERE relname='events_lake';" >/dev/null 2>&1 || true
    pg "DROP VIEW  IF EXISTS events_lake CASCADE;" >/dev/null 2>&1 || true
    pg "DROP TABLE IF EXISTS events_lake CASCADE;" >/dev/null 2>&1 || true
    drop_iceberg_table events_lake
}

demo_tiered() {
    header "Tiered storage — start with a Postgres DB you already have"

    # Idempotent teardown: events may be a plain table (fresh) OR a tiered view with a
    # cold tier (prior run). teardown_tiered unregisters before dropping, so the
    # coldfront "has a cold tier" DROP block doesn't leave events behind.
    teardown_tiered

    # ── Part 1: you already have this — a data-laden plain Postgres table ──────────
    explain "Step 1 — Create the database table: an ordinary partitioned Postgres table"
    explain "  ${DIM}Now we create a range-partitioned Postgres table and its monthly${RESET}"
    explain "  ${DIM}partitions — standing in for the live DB you already run. No ColdFront yet.${RESET}"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi
    # generate_events seeds rows across now-150d .. now (~5 months). RANGE
    # partitioning REJECTS any insert with no covering partition, so we create
    # monthly partitions from now-6mo through the current month — that fully
    # covers the ~150-day window with margin (6 months > 150 days) under any
    # wall clock. Everything older than 30 days tiers to cold; the current month
    # stays hot.
    psql_file >/dev/null <<'EOSQL' || { error "Could not create the demo table — a previous run's 'events' may still exist. Try 'Reset demos' from the menu, then re-run."; return 1; }
SET search_path = public;
CREATE TABLE events (
    id     bigint GENERATED BY DEFAULT AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text,
    data   jsonb,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
DO $do$
DECLARE m date;
BEGIN
  FOR i IN 0..6 LOOP
    m := (date_trunc('month', now()) - make_interval(months => 6 - i))::date;
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF events FOR VALUES FROM (%L) TO (%L)',
                   'events_p_' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month'));
  END LOOP;
END $do$;
EOSQL

    # Load loop: pick a size, load, verify. On a failed/short load, loop back to
    # choose_volume so the user can pick smaller (choose_volume itself already
    # blocks a too-big fixed/custom pick). generate_events surfaces the real
    # error (e.g. disk-full) and returns non-zero — the primary failure signal;
    # the row-count check below is belt-and-suspenders for a silent short load.
    # NON-INTERACTIVE never loops: on failure it errors and returns (CI must not
    # hang), and empties the partial table first so a rolled-back load can't be
    # mistaken for a valid post-run state.
    local before
    while true; do
        choose_volume
        explain "Loading ~6 months of history into the table (your accumulated data):"
        if ! generate_events "$GEN_ROWS"; then
            if [ "$NONINTERACTIVE" = 1 ]; then
                pg "TRUNCATE events;" >/dev/null 2>&1
                return
            fi
            warn "Load did not complete — pick a smaller size, or free Docker disk, and try again."
            pg "TRUNCATE events;" >/dev/null 2>&1   # clear any partial state before retry
            continue
        fi
        # Correctness gate: every generated row must have landed (no partition gaps).
        before=$(pg "SELECT count(*) FROM events;")
        if [ "$before" = "$GEN_ROWS" ]; then break; fi
        error "Row-count mismatch: generated ${GEN_ROWS} but events has ${before}."
        if [ "$NONINTERACTIVE" = 1 ]; then pg "TRUNCATE events;" >/dev/null 2>&1; return; fi
        warn "Short load — pick a smaller size and try again."
        pg "TRUNCATE events;" >/dev/null 2>&1
    done

    # Step "see the problem": how much hot storage, and it's ALL hot. ColdFront is not
    # installed yet, so this is a plain-Postgres query over the partitioned table.
    # (pg_total_relation_size on a partitioned PARENT reports 0 — the real heap is the
    # sum over its partition tree.) hot_before is also captured for the later before/
    # after takeaway.
    local hot_before; hot_before=$(heap_size events)
    explain "See the problem — how many rows there are:"
    show_query "SELECT count(*) AS rows FROM events;"
    explain "...and how much Postgres (hot) storage they take (summed across the partition tree):"
    show_query "SELECT pg_size_pretty(pg_total_relation_size('events') +
                       COALESCE((SELECT sum(pg_total_relation_size(relid))
                                 FROM pg_partition_tree('events')
                                 WHERE relid <> 'events'::regclass), 0)) AS postgres_heap;"
    info "All ${before} rows are on hot, expensive storage (${hot_before}); nothing in object storage yet."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # ── Part 2: add ColdFront to the existing database (shown, AFTER the data load) ─
    header "Add ColdFront to that database"
    # If the db went unreachable mid-demo, ensure_coldfront_setup prints the
    # diagnostic and returns non-zero — stop here and return to the menu rather
    # than pressing on into more connection-refused errors.
    ensure_coldfront_setup shown || return
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # ── Part 3: tier it, and prove it ──────────────────────────────────────────────
    header "Tier it — relocate the cold data, prove it moved"
    # Concise policy summary (the meaningful rule), NOT the whole YAML: the archiver
    # config also carries dsn/iceberg/s3 plumbing that only clutters the story here.
    explain "The archiver reads a small policy from config/archiver.yaml:"
    echo -e "  ${DIM}Policy: table=events, monthly partitions, hot_period=30 days${RESET}"
    echo -e "  ${DIM}        → partitions older than 30 days move to object storage.${RESET}"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # Own explain → prompt → run beat: the "what it does" line MUST print before the
    # Enter that triggers the archiver, so the viewer knows what is about to happen.
    # Production-vs-demo: in production the archiver is a scheduled cron/timer job on
    # ONE node; here we invoke the same binary once, by hand, so the move is visible.
    explain "In production the archiver runs unattended on a schedule — a cron job or a"
    explain "systemd timer fires one pass per period, on a single node. Here we run that"
    explain "same binary once, by hand, so you can watch the move happen:"
    explain "  ${DIM}It moves partitions older than 30 days PG → Parquet in S3, and rebuilds events as a unified hot+cold view.${RESET}"
    # The archiver reads its managed-table set from coldfront.partition_config, not
    # from the YAML at run time; seed it once from the YAML's archiver.tables block.
    if ! $COMPOSE run --rm --no-deps archiver import --config /config/archiver.yaml >/tmp/wt-archiver.log 2>&1; then
        error "Registering the table failed (archiver import) — see /tmp/wt-archiver.log"
        grep -vE '^ Container ' /tmp/wt-archiver.log | tail -5 | sed 's/^/    /'
        return 1
    fi
    if [ "$NONINTERACTIVE" != 1 ]; then
        show_cmd "docker compose run --rm --no-deps archiver --config /config/archiver.yaml"
        echo ""
        read -rp "Press Enter to run the archiver..." </dev/tty
        echo ""
    fi
    start_spinner "Archiving cold partitions to object storage"
    # --no-deps: use the already-running, data-populated db over the shared compose
    # network. Without it, `compose run` re-evaluates depends_on:db and can RECREATE
    # the db from its config hash — replacing the loaded db with a fresh one, so the
    # archiver's host=db then finds no `events` table.
    $COMPOSE run --rm --no-deps archiver --config /config/archiver.yaml >>/tmp/wt-archiver.log 2>&1
    local rc=$?
    stop_spinner
    if [ "$rc" != 0 ]; then
        # Clean failure: one-line reason + the last few RELEVANT log lines (drop the
        # compose container-lifecycle noise), then return to the menu cleanly.
        local reason
        reason=$(grep -iE 'error|fatal|panic|does not exist|not found' /tmp/wt-archiver.log | tail -1)
        [ -n "$reason" ] || reason="see /tmp/wt-archiver.log for details"
        error "The archiver failed — ${reason}"
        grep -vE '^ Container ' /tmp/wt-archiver.log | tail -5 | sed 's/^/    /'
        return 1
    fi

    # Proof (a): it's really Parquet in S3. iceberg_metadata() lists the data files
    # of a table, but pg_duckdb's table-function form resolves its argument as a
    # filesystem path — a REST-catalog-managed table can't be addressed by name
    # there. So we ask the catalog for the table's metadata.json location (warehouse
    # UUID → loadTable), then point iceberg_metadata at that explicit S3 path. Run as
    # a native pg_duckdb table function (NOT duckdb.raw_query, which returns void for
    # SELECTs) so the rows reach the viewer. All values derived at runtime.
    explain "Proof it really moved — the cold rows are now Parquet files in object storage:"
    if show_parquet_files events; then
        info "Real .parquet objects in the bucket — the cold rows aren't in Postgres anymore."
    fi

    # Proof (b): events is now a VIEW (relkind = v) — shown, not asserted.
    explain "And events itself is now a unified VIEW over hot + cold — ColdFront swapped the table for a view (relkind = v); _events holds only the hot remainder:"
    show_query "SELECT relkind FROM pg_class WHERE relname='events' AND relnamespace='public'::regnamespace;"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # Step 8 — the hot/cold accounting (the payoff vs the 'see the problem' baseline).
    # Shown as two proven-safe simple counts (pg_duckdb's planner hook mishandles a
    # combined count+SIZE over the tiered parent); cold = total - hot is stated in the
    # takeaway, and the heap figure comes from heap_size (a catalog-only sum).
    header "Where the data lives now — hot vs cold"
    explain "Rows still in the Postgres hot heap (_events):"
    show_query "SELECT count(*) AS hot_rows FROM _events;"
    explain "Rows total — hot + cold — through the unified view:"
    show_query "SELECT count(*) AS total_rows FROM events;"
    local hot_rows total cold_rows hot_after
    hot_rows=$(pg "SELECT count(*) FROM _events;")
    total=$(pg "SELECT count(*) FROM events;")
    cold_rows=$((total - hot_rows))
    hot_after=$(heap_size _events)
    info "So ${cold_rows} of ${total} rows now live as Parquet in object storage (0 bytes in PG); only ${hot_rows} remain in the Postgres heap — which is down to ${hot_after}. Before ColdFront: ${before} rows at ${hot_before}, all hot. Same total, a fraction of the hot footprint."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # Step 9 — query across tiers.
    explain "One query spans both tiers — the app can't tell hot from cold:"
    show_query "SELECT id, ts, status FROM events
                 WHERE ts < date_trunc('month', now()) - interval '3 months'
                 ORDER BY ts LIMIT 3;"
    info "Those rows came from Parquet in S3 through the same events table."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # Step 10 — write to cold data (the differentiator).
    header "Write to cold data — no rehydration, no separate tool"
    # Capture cold_id in a SEPARATE query: a sub-select over the same tiered view
    # inside the UPDATE is rejected (the rewrite retargets the leading reference).
    local cold_id; cold_id=$(pg "SELECT id FROM events WHERE ts < date_trunc('month',now()) - interval '2 months' ORDER BY ts LIMIT 1;")
    explain "How do we know this row is really cold, not just sitting in Postgres?"
    explain "First — it is NOT in the Postgres hot heap (_events is plain Postgres, no lake):"
    show_query "SELECT count(*) AS in_hot_heap FROM _events WHERE id=${cold_id};"
    explain "And the hot heap only holds the recent window — its oldest row is far newer than our archived one:"
    show_query "SELECT min(ts) AS oldest_row_in_hot_heap FROM _events;"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi
    explain "Now the physical proof — the rows literally live as Parquet objects in object"
    explain "storage. We read one of those objects straight from the bucket (no Postgres heap involved):"
    show_parquet_contents events || true
    explain "And that same archived row reads back through the unified events view — served from"
    explain "the cold tier, not from Postgres:"
    show_query "SELECT id, ts, status FROM events WHERE id=${cold_id};"
    info "Zero rows in the hot heap; the data physically sits in Parquet objects in S3; yet the row reads back through events. It lives only in object storage."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi
    explain "Now we update that archived row through the same table — one line of plain SQL, and the write goes straight to the cold tier in object storage:"
    run_sql_shown "UPDATE events SET status='corrected' WHERE id=${cold_id};" "" || return
    explain "Read it back through the view — the change is there:"
    show_query "SELECT id, ts, status FROM events WHERE id=${cold_id};"
    explain "And prove it STAYED cold — still 0 rows in the Postgres hot heap, so the write"
    explain "went straight to object storage without rehydrating the row into Postgres:"
    show_query "SELECT count(*) AS in_hot_heap FROM _events WHERE id=${cold_id};"
    info "status = corrected, in_hot_heap = 0 — the update landed directly in object storage. No rehydration, no restore job, no second tool."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # Step 11 — prove it stuck (fresh connection). Each psql -c is a brand-new backend
    # process, so showing pg_backend_pid() — and watching it change between the two
    # calls — is visible proof that these are genuinely fresh sessions, not the one
    # that did the write. The committed value surviving that proves durability.
    header "Prove it stuck — it's real, not a session trick"
    explain "Each psql command opens a brand-new connection — a fresh backend process. The"
    explain "pg_backend_pid() below changes call to call, proving these really are new sessions"
    explain "and the corrected value is committed and durable, not a cached artifact of the writer."
    explain "Fresh connection — its backend PID:"
    show_query "SELECT pg_backend_pid() AS session_pid;"
    explain "Yet another fresh connection — re-read the corrected row:"
    show_query "SELECT id, ts, status FROM events WHERE id=${cold_id};"
    explain "One more fresh connection — note the PID differs again (a different backend each time):"
    show_query "SELECT pg_backend_pid() AS session_pid;"
    local hot_final; hot_final=$(heap_size _events)
    info "Different session_pid across calls = genuinely new connections; the corrected row survives every one. All ${total} rows present, hot heap still ${hot_final} — durable, and the data never came back to Postgres. That is ColdFront: cheaper storage that's still writeable."

    # No DELETE here — keeps the final count clean. (A DELETE works identically;
    # the script notes it only as an aside.) Exit cleanup is interactive-only: CI
    # runs non-interactively and asserts on the post-run state (events is a view,
    # watermark row present), so we MUST leave events/_events/watermark intact when
    # NONINTERACTIVE=1.
    if [ "$NONINTERACTIVE" != 1 ]; then
        read -rp "Drop this demo's data to reclaim disk before returning to the menu? [Y/n]: " a </dev/tty
        [[ "$a" =~ ^[Nn]$ ]] || teardown_tiered
    fi
}
demo_decoupled() {
    ensure_coldfront_setup        # silent — ColdFront may not be installed yet if this demo ran first
    header "Decoupled — a table whose data lives in the lake, not in Postgres"

    explain "\"I want a table whose data lives in the lake from day one — full SQL,"
    explain " none of the Postgres storage cost.\" That's decoupled mode."
    explain "  ${DIM}Unlike tiered, the data is never in a Postgres heap — it starts in the lake.${RESET}"
    echo ""

    # Idempotent teardown: events_lake may be a leftover iceberg-only view + registry
    # row + cold table. teardown_decoupled unregisters before dropping (lifts the
    # coldfront cold-tier DROP block) and drops the Iceberg table so re-runs start clean.
    teardown_decoupled

    # Step 2 — create the lake-native table (one call).
    explain "Now we create a lake-native table in a single call. It builds a view plus a"
    explain "registry row and NO Postgres heap — the rows will have nowhere to live but the lake:"
    if [ "$NONINTERACTIVE" != 1 ]; then
        explain "  ${DIM}One function call, passing the column definitions as JSON:${RESET}"
        show_cmd "SELECT coldfront.create_iceberg_table('public', 'events_lake',
      '[ id bigint, ts timestamptz, status text, data jsonb ]'::jsonb);"
        echo ""
        read -rp "Press Enter to create the lake-native table..." </dev/tty
        echo ""
    fi
    # The Iceberg namespace is pre-seeded in Phase A. DuckDB 1.5.x defers an
    # Iceberg CREATE SCHEMA to COMMIT but POSTs CREATE TABLE eagerly, so
    # create_iceberg_table — both in ONE plpgsql txn — would 404 on a cold
    # warehouse. With the namespace already committed this no-ops; the loop is a
    # thin safety net in case seeding raced the warehouse.
    local i ok=0
    for i in 1 2 3 4 5; do
        pg "SELECT coldfront.create_iceberg_table('public','events_lake','[{\"name\":\"id\",\"type\":\"bigint\"},{\"name\":\"ts\",\"type\":\"timestamptz\"},{\"name\":\"status\",\"type\":\"text\"},{\"name\":\"data\",\"type\":\"jsonb\"}]'::jsonb);" >/dev/null 2>&1
        if [ "$(pg "SELECT count(*) FROM pg_class WHERE relname='events_lake' AND relkind='v';")" = "1" ]; then ok=1; break; fi
        sleep 2
    done
    [ "$ok" = 1 ] || { error "create_iceberg_table did not succeed"; return 1; }
    explain "Confirm what it created — events_lake is a VIEW (relkind = v), not a table:"
    show_query "SELECT relkind FROM pg_class WHERE relname='events_lake';"
    info "relkind = v — events_lake is a VIEW, no heap table was created. The data has nowhere to live but the lake."

    # Step 3 — registry proof (iceberg-only, no hot table).
    explain "The registry confirms it's iceberg-only, with no Postgres hot table behind it:"
    show_query "SELECT relname, is_iceberg_only, hot_table FROM coldfront.tiered_views WHERE relname='events_lake';"
    info "is_iceberg_only = t, hot_table = NULL — nothing in Postgres holds these rows."

    # Step 4 — use it like any Postgres table. Every write is SHOWN (run_sql_shown):
    # the differentiator here is that ordinary INSERT/UPDATE/DELETE land in Iceberg,
    # so the viewer must SEE each write command, not just its before/after.
    header "Use it like any Postgres table"
    explain "Now we insert three rows — ordinary SQL, but each row lands as Parquet in the lake, not in a Postgres heap:"
    run_sql_shown "INSERT INTO events_lake VALUES (1, now(), 'ok', '{\"k\":1}'), (2, now(), 'ok', '{\"k\":2}'), (3, now(), 'warn', '{\"k\":3}');" "" || return
    explain "Read them back through the view:"
    show_query "SELECT id, status, data->>'k' AS k FROM events_lake ORDER BY id;"
    explain "Now we correct row 1 — an UPDATE that goes straight to Iceberg:"
    run_sql_shown "UPDATE events_lake SET status='corrected' WHERE id=1;" "" || return
    explain "And delete row 3 — again ordinary SQL, straight to the lake:"
    run_sql_shown "DELETE FROM events_lake WHERE id=3;" "" || return
    explain "Read back the result — row 1 corrected, row 3 gone:"
    show_query "SELECT id, status FROM events_lake ORDER BY id;"
    info "Full read/write SQL — your application code is identical to any Postgres table, yet none of it lives in a Postgres heap."

    # Step 5 — prove the data isn't in Postgres (the climax).
    header "Prove the data isn't in Postgres"
    explain "events_lake is a view (views store no rows), and there's no heap table behind it:"
    show_query "SELECT relkind, pg_size_pretty(pg_relation_size(c.oid)) AS pg_bytes
                FROM pg_class c WHERE c.relname='events_lake';"
    show_query "SELECT count(*) AS heap_tables_named_events_lake
                FROM pg_class WHERE relname LIKE 'events_lake%' AND relkind='r';"
    explain "Yet the rows are really there — as Parquet files in object storage:"
    show_parquet_files events_lake || true
    info "A fully queryable, writeable SQL table with real rows — and Postgres stores 0 bytes of that data."

    # Durability — fresh connection.
    explain "And it's durable — a brand-new connection sees every row, still 0 bytes in Postgres:"
    show_query "SELECT count(*) AS rows FROM events_lake;"
    show_query "SELECT pg_size_pretty(pg_relation_size('events_lake')) AS pg_bytes;"

    # Step 6 — scale-out bridge (narrative only, no commands).
    header "Where this goes next: scale compute, not storage"
    explain "Because the data lives in the lake — not in THIS node — you can point more"
    explain "Postgres nodes at the very same data: pure added compute over one shared copy,"
    explain "no data to replicate. ColdFront serializes their writes so they never collide"
    explain "(a Spock-replicated, TLA+-verified protocol)."
    explain "  ${DIM}Seeing that live — write on node A, read on node B, concurrent writes with no${RESET}"
    explain "  ${DIM}conflicts — is its own story: the Distributed walkthrough (coming as #4).${RESET}"
    echo ""

    # Exit cleanup is interactive-only: CI / NONINTERACTIVE runs assert on the
    # post-run state (events_lake is a view + iceberg-only registry row), so we
    # MUST leave it intact when NONINTERACTIVE=1.
    if [ "$NONINTERACTIVE" != 1 ]; then
        read -rp "Drop events_lake before returning to the menu? [Y/n]: " a </dev/tty
        [[ "$a" =~ ^[Nn]$ ]] || teardown_decoupled
    fi
}
demo_partitioner() {
    ensure_coldfront_setup        # silent — ColdFront may not be installed yet if this demo ran first
    header "Standalone partitioner — automated partitioning, no cold tier"
    explain "Only want automated PostgreSQL partition maintenance? The partitioner"
    explain "binary alone is the whole product — no Iceberg, no DuckDB, no cold tier."
    echo ""

    pg "DROP TABLE IF EXISTS part_demo CASCADE;" >/dev/null 2>&1 || true

    # Step 1 — the bare partitioned table, with no partitions yet.
    explain "Step 1 — First we create an empty range-partitioned table. It has no"
    explain "partitions yet, so an INSERT right now would fail with 'no partition found':"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi
    psql_file >/dev/null <<'EOSQL'
SET search_path = public;
CREATE TABLE part_demo (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL,
    note text,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
EOSQL
    explain "Confirm it starts with zero partitions:"
    show_query "SELECT count(*) AS partitions FROM pg_inherits WHERE inhparent='part_demo'::regclass;"

    # Step 2 — register the policy (records intent, builds nothing yet).
    header "Register a partitioning policy"
    explain "Now we register the table with the partitioner: monthly partitions, 12-month"
    explain "retention. This records the policy only — it doesn't build any partitions yet."
    if [ "$NONINTERACTIVE" != 1 ]; then
        show_cmd "partitioner register --table part_demo --period monthly --retention \"12 months\""
        echo ""
        read -rp "Press Enter to register the policy..." </dev/tty
        echo ""
    fi
    start_spinner "Registering the partitioning policy"
    # --no-deps: reuse the already-running db (see the archiver note above) — a plain
    # `compose run` can recreate the db from its config hash and wipe the loaded data.
    $COMPOSE run --rm --no-deps --entrypoint partitioner archiver \
        register --config /config/partitioner.yaml --table part_demo \
        --period monthly --retention "12 months" >/tmp/wt-part.log 2>&1
    local rc=$?
    stop_spinner
    if [ "$rc" != 0 ]; then
        error "Registration failed — see /tmp/wt-part.log"
        grep -vE '^ Container ' /tmp/wt-part.log | tail -5 | sed 's/^/    /'
        return 1
    fi
    info "Policy registered."

    # Step 3 — reconcile: build the partitions the policy calls for.
    header "Reconcile — let the partitioner build what the policy requires"
    # Production-vs-demo: in production this is a scheduled cron/timer pass; here we
    # run one pass by hand so the created partitions are visible in the moment.
    explain "In production the partitioner runs on a schedule — a cron job or systemd"
    explain "timer — so the forward window keeps rolling and partitions past retention"
    explain "get dropped automatically. Here we run one pass by hand so you can see it work:"
    explain "  ${DIM}It reads the policy and creates the missing partitions — the current month plus the forward window — so writes never hit a gap.${RESET}"
    if [ "$NONINTERACTIVE" != 1 ]; then
        show_cmd "partitioner --config /config/partitioner.yaml"
        echo ""
        read -rp "Press Enter to reconcile partitions..." </dev/tty
        echo ""
    fi
    start_spinner "Reconciling partitions"
    $COMPOSE run --rm --no-deps --entrypoint partitioner archiver --config /config/partitioner.yaml >>/tmp/wt-part.log 2>&1
    rc=$?
    stop_spinner
    if [ "$rc" != 0 ]; then
        error "Reconcile failed — see /tmp/wt-part.log"
        grep -vE '^ Container ' /tmp/wt-part.log | tail -5 | sed 's/^/    /'
        return 1
    fi

    # Step 4 — see the result: the forward window, built automatically.
    explain "See the result — the partitioner created the forward window for you:"
    show_query "SELECT c.relname AS partition
                FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                WHERE i.inhparent='part_demo'::regclass ORDER BY c.relname;"
    info "Every month in the forward window now has a partition — created and maintained for you, no cold tier involved. On a schedule, the same run also drops partitions older than the 12-month retention."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # Exit cleanup is interactive-only: a NONINTERACTIVE / CI run asserts on the
    # post-run partition count, so part_demo MUST be left intact in that mode.
    if [ "$NONINTERACTIVE" != 1 ]; then
        read -rp "Drop part_demo before returning to the menu? [Y/n]: " a </dev/tty
        [[ "$a" =~ ^[Nn]$ ]] || pg "DROP TABLE IF EXISTS part_demo CASCADE;" >/dev/null 2>&1
    fi
}

# ── Stack switch (single-node ↔ mesh) ───────────────────────────────────────
# The single-node stack and the 2-node mesh can't run at once on a laptop, so the
# menu switches between them lazily — a switch runs only on an actual transition.
# ACTIVE_STACK (single | mesh | none) tracks which is up.

# ensure_single_stack — demos 1-3 need the single-node stack. If the mesh is up,
# tear it down and bring the single-node stack back.
ensure_single_stack() {
    [ "$ACTIVE_STACK" = single ] && return 0
    header "Restoring the single-node stack"
    explain "Freeing the 2-node cluster and bringing the single-node stack back —"
    explain "only one can run at a time on a single machine."
    start_spinner "Tearing down the 2-node cluster"
    $MESH_COMPOSE down -v >/dev/null 2>&1 || true
    stop_spinner
    phase_a_bringup
    ACTIVE_STACK=single
}

# ensure_mesh_stack — Demo 4 needs the 2-node mesh. mesh_bringup tears the
# single-node stack down first. On failure ACTIVE_STACK drops to 'none' so the
# next single-node demo restores cleanly.
ensure_mesh_stack() {
    [ "$ACTIVE_STACK" = mesh ] && return 0
    if mesh_bringup; then ACTIVE_STACK=mesh; return 0; fi
    error "Mesh bring-up failed — returning to the menu."
    ACTIVE_STACK=none
    return 1
}

# _CREATE_EVENTS_LAKE — the column JSON for events_lake, shared by the db1 create
# and the db2 re-register (identical call — create_iceberg_table is idempotent).
_CREATE_EVENTS_LAKE="SELECT coldfront.create_iceberg_table('public','events_lake','[{\"name\":\"id\",\"type\":\"bigint\"},{\"name\":\"ts\",\"type\":\"timestamptz\"},{\"name\":\"status\",\"type\":\"text\"},{\"name\":\"data\",\"type\":\"jsonb\"}]'::jsonb);"

demo_distributed() {
    header "Distributed — scale compute, not storage"
    explain "The Decoupled demo ended by pointing here: once a table's data lives in the"
    explain "lake, you can point MORE Postgres nodes at the very same data. Let's do"
    explain "exactly that — two nodes, one shared lake — and prove two things:"
    explain "  ${DIM}• a write on one node is instantly readable on the other${RESET}"
    explain "  ${DIM}• concurrent writes from both nodes never collide${RESET}"
    echo ""
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    ensure_mesh_stack || return

    # ── Beat 1 — the mesh is real ───────────────────────────────────────────
    header "The cluster: two nodes, one lake"
    explain "Two Postgres nodes in an active-active Spock mesh. Both are ColdFront nodes"
    explain "pointed at the SAME Lakekeeper catalog and object store — one shared copy of"
    explain "the data. Here are the nodes:"
    mshow db1 "$MESH_PG1_PORT" "SELECT node_name FROM spock.node ORDER BY node_name;"
    explain "And the bidirectional subscriptions that carry ColdFront's coordination"
    explain "metadata between them (one per direction, synced at bring-up):"
    mshow db1 "$MESH_PG1_PORT" "SELECT sub_name FROM spock.subscription ORDER BY sub_name;"
    mshow db2 "$MESH_PG2_PORT" "SELECT sub_name FROM spock.subscription ORDER BY sub_name;"
    info "Two nodes, replicating tiny coordination metadata — NOT the data. The data stays in the lake."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # ── Beat 2 — cross-node visibility ──────────────────────────────────────
    header "Write on one node, read on the other"
    explain "We create a lake-native table on db1 — the same one-call create as the"
    explain "Decoupled demo, columns passed as JSON:"
    if [ "$NONINTERACTIVE" != 1 ]; then
        show_cmd "psql (db1) -c \"SELECT coldfront.create_iceberg_table('public','events_lake', '[ id bigint, ts timestamptz, status text, data jsonb ]');\""
        echo ""
        read -rp "Press Enter to create the table on db1..." </dev/tty
        echo ""
    fi
    local i ok=0
    for i in 1 2 3 4 5; do
        mpg "$MESH_PG1_PORT" "$_CREATE_EVENTS_LAKE" >/dev/null 2>&1
        if [ "$(mpg "$MESH_PG1_PORT" "SELECT count(*) FROM pg_class WHERE relname='events_lake' AND relkind='v';")" = "1" ]; then ok=1; break; fi
        sleep 2
    done
    [ "$ok" = 1 ] || { error "create_iceberg_table did not succeed on db1"; return 1; }
    info "events_lake created on db1 — a VIEW over the shared Iceberg table, no Postgres heap."

    explain "Now register the same table on db2 so that node can read AND write it. The"
    explain "Iceberg table already exists — this just gives db2 its own local view +"
    explain "registry row (create_iceberg_table is idempotent, keyed by name):"
    ok=0
    for i in 1 2 3 4 5; do
        mpg "$MESH_PG2_PORT" "$_CREATE_EVENTS_LAKE" >/dev/null 2>&1
        if [ "$(mpg "$MESH_PG2_PORT" "SELECT count(*) FROM coldfront.tiered_views WHERE relname='events_lake' AND is_iceberg_only;")" = "1" ]; then ok=1; break; fi
        sleep 2
    done
    [ "$ok" = 1 ] || { error "could not register events_lake on db2"; return 1; }
    mshow db2 "$MESH_PG2_PORT" "SELECT relname, is_iceberg_only, hot_table FROM coldfront.tiered_views WHERE relname='events_lake';"
    info "Registered on db2 — is_iceberg_only = t, hot_table = NULL. Both nodes now front the one shared lake table."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    explain "Insert three rows on db1 — ordinary SQL, landing as Parquet in the shared lake:"
    mrun db1 "$MESH_PG1_PORT" "INSERT INTO events_lake VALUES (1, now(), 'ok', '{\"n\":\"db1\"}'), (2, now(), 'ok', '{\"n\":\"db1\"}'), (3, now(), 'warn', '{\"n\":\"db1\"}');" "Written on db1 — but the rows live in the lake, not in db1's heap." || return
    explain "Now read them back on db2 — a DIFFERENT node that stored none of this data:"
    mshow db2 "$MESH_PG2_PORT" "SELECT id, status, data->>'n' AS written_by FROM events_lake ORDER BY id;"
    info "db2 sees every row db1 wrote — over the shared lake. Spock never shipped these rows node-to-node."
    explain "And db2 truly holds none of it — events_lake is a VIEW there, zero heap bytes:"
    mshow db2 "$MESH_PG2_PORT" "SELECT relkind, pg_size_pretty(pg_relation_size('events_lake')) AS pg_bytes FROM pg_class WHERE relname='events_lake';"
    info "Zero bytes on db2. That's the point: add a node for more COMPUTE over one shared copy of the data — no storage to replicate."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # ── Beat 3 — bakery serialization ───────────────────────────────────────
    header "Concurrent writes, no collisions"
    explain "The hard part: both nodes write to the SAME lake table at the SAME time."
    explain "Two Iceberg commits racing one table would normally collide — Lakekeeper"
    explain "returns 409 Conflict and the app has to retry. ColdFront's bakery protocol"
    explain "serializes them cluster-wide: each write takes a globally-ordered ticket"
    explain "(Spock-replicated, TLA+-verified) and waits its turn. Every write lands, no retries."
    echo ""
    explain "  ${DIM}We fire 10 writers at once — 5 on db1 (ids 101-105) and 5 on db2 (201-205),${RESET}"
    explain "  ${DIM}all committing events_lake at the same instant. Multiple cold writes are${RESET}"
    explain "  ${DIM}in flight on each node AND across both — the exact contention the bakery${RESET}"
    explain "  ${DIM}must serialize so no two Iceberg commits collide.${RESET}"
    explain "First — the row count before the storm:"
    local before; before=$(mpg "$MESH_PG2_PORT" "SELECT count(*) FROM events_lake;")
    mshow db2 "$MESH_PG2_PORT" "SELECT count(*) AS rows_before FROM events_lake;"
    if [ "$NONINTERACTIVE" != 1 ]; then
        show_cmd "# simultaneously, on BOTH nodes:  INSERT INTO events_lake VALUES (…, 'storm', …);"
        echo ""
        read -rp "Press Enter to fire the concurrent writes..." </dev/tty
        echo ""
    fi
    # All 10 writers fire at once (no per-round wait): 5 concurrent on db1 AND 5 on
    # db2, same table. Two layers serialize them — a node-local advisory lock keeps
    # one cold writer per node in the bakery, and the R-A claim protocol serializes
    # across nodes — so every commit lands, no 409 (ci/journey.sh:story_mesh_multiwriter).
    local tmp i; tmp=$(mktemp -d)
    for i in 1 2 3 4 5; do
        mpg "$MESH_PG1_PORT" "INSERT INTO events_lake VALUES (10$i, now(), 'storm', '{\"n\":\"db1\"}');" >"$tmp/db1.$i" 2>&1 &
        mpg "$MESH_PG2_PORT" "INSERT INTO events_lake VALUES (20$i, now(), 'storm', '{\"n\":\"db2\"}');" >"$tmp/db2.$i" 2>&1 &
    done
    wait
    # Assert on the real +10 row delta, not just a token grep — a client that dies
    # without printing 'error/conflict/409' (dropped connection, 5xx) must still fail.
    local errs after landed
    errs=$(cat "$tmp"/* 2>/dev/null | grep -cEi 'error|conflict|409')
    rm -rf "$tmp"
    after=$(mpg "$MESH_PG2_PORT" "SELECT count(*) FROM events_lake;")
    landed=$((after - before))
    if [ "$landed" = 10 ] && [ "$errs" = 0 ]; then
        info "All 10 concurrent writers committed — +10 rows, 0 conflicts, 0 Lakekeeper 409s."
    else
        error "Storm did not fully land: +$landed rows (want +10), $errs error/conflict line(s)."
        [ "$NONINTERACTIVE" = 1 ] && { $MESH_COMPOSE logs db1 db2 | tail -30; exit 1; }
    fi
    explain "First the receipts — the bakery's durable proof. Each cold write took a"
    explain "globally-ordered ticket; the peer node acked it before the commit. This trail"
    explain "records every one (node names resolved from spock.node, not hardcoded):"
    mshow db1 "$MESH_PG1_PORT" "SELECT ca.ticket,
                iss.node_name  AS issued_by,
                ackn.node_name AS acked_by,
                ca.iceberg_table
             FROM coldfront.claim_acks ca
             JOIN spock.node iss  ON (hashtext(iss.node_name)  & 1023) = snowflake.get_node(ca.ticket)
             JOIN spock.node ackn ON (hashtext(ackn.node_name) & 1023) = ca.ack_from_node
             ORDER BY ca.ticket;"
    info "Tickets issued by BOTH nodes, each acked by its peer — the bakery serialized them cluster-wide, so no two Iceberg commits ever collided."
    explain "And the row count confirms it — up by exactly 10, every concurrent write landed (none lost to a conflict):"
    mshow db2 "$MESH_PG2_PORT" "SELECT count(*) AS rows_after FROM events_lake;"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # ── Beat 4 — close ──────────────────────────────────────────────────────
    header "Where the ladder ends: scale compute, keep one copy"
    explain "That's the top rung. Same SQL, same tables — now scaled horizontally across"
    explain "nodes. Add a node for more compute; storage stays one copy in the lake. Put"
    explain "the nodes in different regions or clouds and the picture doesn't change."
    explain "  ${DIM}Tiered → Decoupled → Distributed: one adoption ladder, no re-platforming.${RESET}"
    echo ""
    if [ "$NONINTERACTIVE" != 1 ]; then
        info "The 2-node cluster stays up. Pick another demo to switch back to the single-node stack, or Q to quit (offers to remove everything)."
        prompt_continue
    fi
}

reset_demos() {
    # Restore the single-node stack first (no-op if already there). Covers the mesh
    # case AND a failed switch that left ACTIVE_STACK=none with a mesh still up, so
    # the leftover mesh is torn down and the teardown_* SQL runs against a live db.
    ensure_single_stack
    teardown_tiered       # events + _events + registry/watermark + Iceberg cold table
    teardown_decoupled    # events_lake + registry + Iceberg table
    pg "DROP TABLE IF EXISTS part_demo CASCADE;" >/dev/null 2>&1 || true   # plain table, no cold tier
    info "Demo tables dropped."
}

quit_walkthrough() {
    echo ""
    if [ "$NONINTERACTIVE" = 1 ]; then exit 0; fi
    read -rp "Remove the whole stack now (docker compose down -v)? [y/N]: " a </dev/tty
    if [[ "$a" =~ ^[Yy]$ ]]; then
        $COMPOSE down -v
        $MESH_COMPOSE down -v 2>/dev/null || true   # the mesh project, if a Distributed run left it up
    fi
    exit 0
}

main_menu() {
    while true; do
        header "ColdFront — what would you like to see?"
        explain "  ${DIM}\"My Postgres database is getting expensive.\"${RESET}"
        explain "  1) Tiered storage   — relocate cold data to object storage, same table, still writeable"
        echo ""
        explain "  ${DIM}\"I want a table whose data lives in the lake from day one.\"${RESET}"
        explain "  2) Decoupled        — Postgres as a front-end to the lake (data in Iceberg from day one)"
        echo ""
        explain "  ${DIM}\"I just want automated partition maintenance.\"${RESET}"
        explain "  3) Partitioner      — automated PG range-partitioning, no cold tier"
        echo ""
        explain "  ${DIM}\"I want to scale across nodes without copying the data.\"${RESET}"
        explain "  4) Distributed      — two Postgres nodes, one shared lake (switches to a 2-node cluster)"
        echo ""
        explain "  R) Reset            — drop demo tables / reclaim disk"
        explain "  Q) Quit             — (offers docker compose down -v)"
        echo ""
        read -rp "Choose [1/2/3/4/R/Q]: " c </dev/tty
        case "$c" in
            1) ensure_single_stack; demo_tiered;;
            2) ensure_single_stack; demo_decoupled;;
            3) ensure_single_stack; demo_partitioner;;
            4) demo_distributed;;
            [Rr]) reset_demos;;
            [Qq]) quit_walkthrough;;
            *) warn "Pick 1, 2, 3, 4, R, or Q.";;
        esac
    done
}

# main
bash "$SCRIPT_DIR/setup.sh"
detect_ports

# NONINTERACTIVE Distributed is self-contained: demo_distributed brings up its own
# 2-node mesh, so skip the single-node detect + bring-up entirely (no point standing
# up a stack we'd immediately tear down).
if [ "$NONINTERACTIVE" = 1 ] && [ "${WALKTHROUGH_DEMO:-}" = distributed ]; then
    demo_distributed || exit 1   # propagate a mesh bring-up failure (else a broken CI run reports pass)
    exit 0
fi

# ── Clean up a leftover Distributed (mesh) cluster ──────────────────────────
# The mesh stack is on-demand (Demo 4 only) and its own compose project, so the
# single-node detect below never sees it. A leftover mesh from a prior Demo 4
# would otherwise run ALONGSIDE the single-node stack we bring up next — twice
# the containers and resource contention. The menu baseline is single-node and
# Demo 4 rebuilds the mesh when picked, so remove any leftover mesh now.
if [ "${NONINTERACTIVE:-0}" != 1 ] && [ -n "$($MESH_COMPOSE ps --status running -q 2>/dev/null)" ]; then
    echo ""
    warn "A 2-node Distributed cluster from a previous Demo 4 is still running."
    info "Removing it so it doesn't run alongside the single-node stack (Demo 4 rebuilds it on demand)."
    $MESH_COMPOSE down -v
    echo ""
fi

# ── Detect an existing stack ────────────────────────────────────────────────
if [ "${NONINTERACTIVE:-0}" != 1 ] && [ -n "$($COMPOSE ps --status running -q 2>/dev/null)" ]; then
    echo ""
    warn "Found an existing ColdFront walkthrough stack from a previous run."
    echo ""
    explain "  It may still hold a previous run's demo data. The Docker image is already"
    explain "  built, so rebuilding fresh is quick — and it's the most reliable way to start"
    explain "  clean (it wipes the old Postgres, object store, and catalog outright)."
    echo ""
    explain "  1) Rebuild fresh   ${DIM}(recommended — wipes old demo data, quick: image is cached)${RESET}"
    explain "  2) Keep it running ${DIM}(reuse the stack and any data a previous run left behind)${RESET}"
    explain "  3) Cancel"
    echo ""
    read -rp "  Choose [1/2/3] (default 1): " _stack_choice </dev/tty
    case "$_stack_choice" in
        2)
            info "Keeping the stack running and continuing..."
            echo ""
            ;;
        3)
            info "Cancelled."
            exit 0
            ;;
        *)
            info "Rebuilding the stack fresh..."
            $COMPOSE down -v
            info "Done. Starting fresh..."
            echo ""
            ;;
    esac
fi

phase_a_bringup
ACTIVE_STACK=single
if [ "$NONINTERACTIVE" = 1 ]; then
    case "${WALKTHROUGH_DEMO:-tiered}" in
        tiered) demo_tiered || exit 1;; decoupled) demo_decoupled || exit 1;; partitioner) demo_partitioner || exit 1;;
        *) error "unknown WALKTHROUGH_DEMO: ${WALKTHROUGH_DEMO:-}"; exit 2;;
    esac
    exit 0
fi
main_menu
