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
# shellcheck disable=SC2034  # set by choose_volume, consumed by Task-9 demos
GEN_ROWS=1000000

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
    # The warehouse POST validates its S3 storage profile against SeaweedFS, so it
    # 500s/4xxs until the S3 endpoint is live. Retry until the catalog can resolve
    # warehouse 'wh' (config?warehouse=wh → 200) — a missing warehouse here makes
    # the archiver's later Iceberg ATTACH 404 on this exact endpoint.
    ok=0
    for _ in $(seq 1 40); do
        if [ "$(curl -s -o /dev/null -w '%{http_code}' "$LK_URL/catalog/v1/config?warehouse=wh")" = 200 ]; then ok=1; break; fi
        curl -sf -X POST "$LK_URL/management/v1/warehouse" \
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
    stop_spinner
    [ "$ok" = 1 ] || { error "Warehouse 'wh' did not become resolvable in Lakekeeper"; $COMPOSE logs lakekeeper seaweedfs | tail -20; exit 1; }
    local wid
    wid=$(curl -s "$LK_URL/management/v1/warehouse" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    curl -sf -X POST "$LK_URL/catalog/v1/$wid/namespaces" \
        -H 'Content-Type: application/json' -d '{"namespace":["default"]}' >/dev/null 2>&1 || true
    info "[4/4] Warehouse 'wh' + namespace 'default' ready"
    echo ""
}

# choose_volume — sets GEN_ROWS. The only feature-relevant prompt in the guide.
choose_volume() {
  if [ "$NONINTERACTIVE" = 1 ]; then GEN_ROWS="${WALKTHROUGH_ROWS:-1000000}"; return; fi
  header "How much data should we generate?"
  explain "  The more you generate, the more storage visibly relocates to object"
  explain "  storage when we tier. Peak is the hot-heap size BEFORE tiering."
  echo ""
  explain "  1) Quick     ~1M rows   (~150 MB, seconds)         [default]"
  explain "  2) Standard  ~10M rows  (~1.5 GB, ~1 min)"
  explain "  3) Big       ~50M rows  (~7 GB, a few min)"
  explain "  4) Custom    enter a row count"
  echo ""
  read -rp "Choose [1/2/3/4]: " v </dev/tty
  # shellcheck disable=SC2034  # GEN_ROWS consumed by Task-9 demo functions
  case "$v" in
    2) GEN_ROWS=10000000;;
    3) GEN_ROWS=50000000;;
    4) read -rp "Rows: " GEN_ROWS </dev/tty;;
    *) GEN_ROWS=1000000;;
  esac
}

# disk_preflight — rough guard: ~150 bytes/row peak (heap+WAL+temp). Compares to
# Docker's available space. Aborts a tier that clearly won't fit.
disk_preflight() {
  local rows="$1"
  local need_mb=$(( rows * 150 / 1024 / 1024 ))
  # Available space on Docker's data root, probed from inside a throwaway container.
  local avail_mb
  avail_mb=$(docker run --rm alpine:3.20 sh -c "df -m / | awk 'NR==2{print \$4}'" 2>/dev/null || echo 0)
  explain "  Estimated peak: ~${need_mb} MB; Docker has ~${avail_mb} MB free."
  if [ "$avail_mb" -gt 0 ] && [ "$need_mb" -gt "$avail_mb" ]; then
    warn "This volume may not fit in Docker's disk allocation."
    if [[ "$(uname -s)" == "Darwin" ]]; then
      warn "On macOS, raise Docker Desktop > Settings > Resources > Virtual disk limit,"
      warn "or pick a smaller volume / run 'R) Reset' first."
    fi
    if [ "$NONINTERACTIVE" = 1 ]; then return 0; fi
    read -rp "Continue anyway? [y/N]: " a </dev/tty
    [[ "$a" =~ ^[Yy]$ ]] || return 1
  fi
  return 0
}

# generate_events — seed `events` across 4 historical months + the current one,
# all derived from now() (never invented literals). Explicit id keeps inserts
# on the fast set-based path. Spread <rows> over ~5 months by 'spacing'.
generate_events() {
  local rows="$1"
  start_spinner "Generating ${rows} rows"
  psql_file >/dev/null 2>&1 <<EOSQL
SET search_path = public;
-- Spread evenly across now-4mo .. now, two-minute spacing scaled to row count.
INSERT INTO events (id, ts, status, data)
SELECT i,
       now() - ((${rows} - i) * (interval '150 days' / ${rows})),
       (ARRAY['ok','warn','error'])[1 + i % 3],
       '{}'::jsonb
FROM generate_series(1, ${rows}) i;
EOSQL
  stop_spinner; info "Generated ${rows} rows."
}

demo_tiered() {
    header "Tiered storage — the bytes move, the table does not"

    # Idempotent teardown: events may be a table OR a view from a prior run.
    pg "DROP TABLE IF EXISTS events CASCADE; DROP VIEW IF EXISTS events CASCADE;
        DROP TABLE IF EXISTS _events CASCADE;
        DELETE FROM coldfront.tiered_views WHERE relname='events';
        DELETE FROM coldfront.archive_watermark WHERE table_name='events';" >/dev/null 2>&1 || true

    # Shown: create the partitioned table + now()-relative monthly partitions.
    explain "First, a normal partitioned PostgreSQL table:"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi
    # generate_events seeds rows across now-150d .. now (~5 months). RANGE
    # partitioning REJECTS any insert with no covering partition, so we create
    # monthly partitions from now-6mo through the current month — that fully
    # covers the ~150-day window with margin (6 months > 150 days) under any
    # wall clock. Everything older than 30 days tiers to cold; the current month
    # stays hot.
    psql_file >/dev/null <<'EOSQL'
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
    explain "  ${DIM}Monthly partitions covering the full data window: the older months go cold, the current one stays hot.${RESET}"
    echo ""

    explain "The archiver config (config/archiver.yaml) tiers anything older than 30 days:"
    if [ "$NONINTERACTIVE" != 1 ]; then show_cmd "cat config/archiver.yaml"; sed 's/^/    /' "$SCRIPT_DIR/config/archiver.yaml"; prompt_continue; fi

    choose_volume
    disk_preflight "$GEN_ROWS" || { warn "Skipping tiered demo."; return; }
    generate_events "$GEN_ROWS"

    # Correctness gate: every generated row must have landed (no partition gaps).
    local before; before=$(pg "SELECT count(*) FROM events;")
    if [ "$before" != "$GEN_ROWS" ]; then
        error "Row-count mismatch: generated ${GEN_ROWS} but events has ${before} — a partition gap dropped rows."
        return
    fi
    local hot_before; hot_before=$(pg "SELECT pg_size_pretty(sum(pg_total_relation_size(c.oid))) FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='events'::regclass;")
    info "Before tiering: ${before} rows, hot heap ${hot_before}"

    explain "Now run the archiver — it moves the cold partitions to Iceberg/S3:"
    start_spinner "Archiving cold partitions to object storage"
    $COMPOSE run --rm archiver --config /config/archiver.yaml >/tmp/wt-archiver.log 2>&1
    local rc=$?
    stop_spinner
    [ "$rc" = 0 ] || { error "archiver failed"; tail -10 /tmp/wt-archiver.log; return; }

    local after; after=$(pg "SELECT count(*) FROM events;")
    local relkind; relkind=$(pg "SELECT relkind FROM pg_class WHERE relname='events' AND relnamespace='public'::regnamespace;")
    local hot_after; hot_after=$(pg "SELECT pg_size_pretty(pg_total_relation_size('_events'));")
    info "After tiering: ${after} rows (unchanged), hot heap now ${hot_after}"
    [ "$relkind" = "v" ] && info "events is now a unified view over hot + cold."

    explain "The same table still returns everything — hot and cold, one query:"
    pg "SELECT count(*) AS total FROM events;"
    pg "SELECT count(*) AS cold_rows FROM events WHERE ts < date_trunc('month',now());"

    explain "And cold data is WRITEABLE — update an archived row through the same table:"
    # Pick a cold row's id first, then UPDATE by that id. The id must come from a
    # SEPARATE query: a sub-select over the same tiered view inside the UPDATE is
    # rejected (a tiered view can only be referenced once per DML — the rewrite
    # retargets the leading reference).
    local cold_id; cold_id=$(pg "SELECT id FROM events WHERE ts < date_trunc('month',now()) - interval '2 months' ORDER BY ts LIMIT 1;")
    pg "UPDATE events SET status='corrected' WHERE id=${cold_id};"
    pg "SELECT count(*) AS corrected FROM events WHERE status='corrected';"
    info "An archived row was updated through the same SQL — no app change."

    explain "Cold data is also DELETABLE through the same table:"
    pg "DELETE FROM events WHERE id=${cold_id};"
    pg "SELECT count(*) AS total_after_delete FROM events;"
    info "An archived row was deleted through the same SQL."
    echo ""

    # Exit cleanup is interactive-only: CI runs non-interactively and asserts on
    # the post-run state (events is a view, watermark row present), so we MUST
    # leave events/_events/watermark intact when NONINTERACTIVE=1.
    if [ "$NONINTERACTIVE" != 1 ]; then
        read -rp "Drop this demo's data to reclaim disk before returning to the menu? [Y/n]: " a </dev/tty
        [[ "$a" =~ ^[Nn]$ ]] || pg "DROP TABLE IF EXISTS _events CASCADE; DROP VIEW IF EXISTS events CASCADE;
            DELETE FROM coldfront.tiered_views WHERE relname='events';
            DELETE FROM coldfront.archive_watermark WHERE table_name='events';" >/dev/null 2>&1
    fi
}
demo_decoupled() {
    header "Decoupled — Postgres as a front-end to the lake"
    explain "A different on-ramp: if data belongs in the lake from day one, skip"
    explain "tiering entirely. One call provisions an Iceberg table fronted by a"
    explain "Postgres view. (This is a fresh table — there is no migration from the"
    explain "tiered demo; the two modes are distinct.)"
    echo ""

    # Idempotent teardown: events_lake may be a leftover view + registry row.
    pg "DROP VIEW IF EXISTS events_lake CASCADE;
        DELETE FROM coldfront.tiered_views WHERE relname='events_lake';" >/dev/null 2>&1 || true

    explain "Create an Iceberg-only table in one call:"
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
    if [ "$ok" = 1 ]; then
        info "events_lake created (a view; every row lives in Iceberg)."
    else
        error "create_iceberg_table did not succeed"
        return
    fi

    explain "It reads and writes like any Postgres table — but it is all in the lake:"
    psql_file <<'EOSQL'
INSERT INTO events_lake VALUES
  (1, now(), 'ok',  '{"a":1}'),
  (2, now(), 'ok',  '{"a":2}');
SELECT count(*) AS rows_in_lake FROM events_lake;
UPDATE events_lake SET status='upd' WHERE id=1;
SELECT id, status FROM events_lake ORDER BY id;
DELETE FROM events_lake WHERE id=2;
SELECT count(*) AS after_delete FROM events_lake;
EOSQL
    echo ""

    # Exit cleanup is interactive-only: CI / NONINTERACTIVE runs assert on the
    # post-run state (events_lake is a view + iceberg-only registry row), so we
    # MUST leave it intact when NONINTERACTIVE=1.
    if [ "$NONINTERACTIVE" != 1 ]; then
        read -rp "Drop events_lake before returning to the menu? [Y/n]: " a </dev/tty
        [[ "$a" =~ ^[Nn]$ ]] || pg "DROP VIEW IF EXISTS events_lake CASCADE; DELETE FROM coldfront.tiered_views WHERE relname='events_lake';" >/dev/null 2>&1
    fi
}
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
