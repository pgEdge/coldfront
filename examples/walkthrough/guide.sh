#!/usr/bin/env bash
set -uo pipefail   # not -e: demo bodies must continue past an assertion

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=runner.sh
source "$SCRIPT_DIR/runner.sh"

COMPOSE="docker compose -f $SCRIPT_DIR/docker-compose.yml"
OS="$(uname -s)"
PG_PORT="${COLDFRONT_PG_PORT:-5432}"
LK_PORT="${COLDFRONT_LK_PORT:-8181}"
LK_URL="http://localhost:${LK_PORT}"
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

# show_query — run a SELECT and print it as an aligned psql table, framed, for the
# viewer to read. Use this for anything shown on screen. (pg() stays -tAX, only for
# values captured into shell variables.)
show_query() {
    echo -e "${DIM}─── result ─────────────────────────────────────────────────${RESET}"
    PGPASSWORD=coldfront psql -h localhost -p "$PG_PORT" -U coldfront -d coldfront -c "$1"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"
}

# show_parquet_files <table_name> — resolve the table's metadata.json S3 path from
# the Lakekeeper catalog (warehouse id → GET …/catalog/v1/<wh_id>/namespaces/default/tables/<table_name>
# → metadata-location), then list its .parquet data files via iceberg_metadata().
# On a failed resolution (empty metadata-location), prints a warn and returns non-zero
# (non-fatal — callers continue). Consumes LK_URL, show_query, warn.
show_parquet_files() {
    local table_name="$1"
    local wh_id meta_loc
    wh_id=$(curl -s "${LK_URL}/management/v1/warehouse" \
        | grep -o '"warehouse-id":"[^"]*"' | head -1 | cut -d'"' -f4)
    meta_loc=$(curl -s "${LK_URL}/catalog/v1/${wh_id}/namespaces/default/tables/${table_name}" \
        -H 'accept: application/json' \
        | grep -o '"metadata-location":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ -n "$meta_loc" ]; then
        show_query "SELECT file_path FROM iceberg_metadata('${meta_loc}')
                     WHERE file_path LIKE '%.parquet' LIMIT 3;"
    else
        warn "Could not resolve the Iceberg metadata location from the catalog; skipping the Parquet listing."
        return 1
    fi
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

# run_sql_shown — explain what the command does FIRST, then show + run it.
# The "why" MUST print before the command/output so the viewer knows what they're
# about to run before hitting Enter — never after.
run_sql_shown() {
    local sql="$1" why="$2"
    [ -n "$why" ] && explain "  ${DIM}$why${RESET}"
    if [ "$NONINTERACTIVE" = 1 ]; then
        pg "$sql" >/dev/null || { error "step failed: $sql"; exit 1; }
    else
        prompt_run "psql -h localhost -p $PG_PORT -U coldfront -d coldfront -c \"$sql\""
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
        run_sql_shown "CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS coldfront;" \
            "pg_duckdb adds an in-process engine that reads Parquet in object storage; coldfront routes queries to the right tier and rewrites writes. No migration — installed onto the running database."
        # set the secret only if not already present (idempotent — mirrors silent branch)
        if [ "$(pg "SELECT count(*) FROM coldfront.storage_secret;" 2>/dev/null)" != "1" ]; then
            run_sql_shown "SELECT coldfront.set_storage_secret('admin','adminsecret','seaweedfs:8333');" \
                "Tells ColdFront where cold data goes. Throwaway local creds; in production you pass your real bucket's key/secret/endpoint here — application SQL is unchanged."
        else
            explain "  ${DIM}Cold-store secret already set — skipping (idempotent).${RESET}"
        fi
    else
        pg "CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS coldfront;" >/dev/null 2>&1
        # set the secret only if not already present (idempotent)
        if [ "$(pg "SELECT count(*) FROM coldfront.storage_secret;" 2>/dev/null)" != "1" ]; then
            pg "SELECT coldfront.set_storage_secret('admin','adminsecret','seaweedfs:8333');" >/dev/null 2>&1
        fi
    fi
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

# ── Disk / sizing estimate ─────────────────────────────────────────────────
#
# Peak footprint is the transient high-water mark of a load, NOT the final
# heap size: it includes the composite PK index (id, ts) built alongside the
# heap, WAL for the INSERT, any temp/sort spill, AND the archiver's later
# Parquet write. Empirical calibration point: a 1M-row load FAILED at ~795 MB
# free (Docker disk-full), so the real peak is well above the old 150 B/row
# guess — > ~0.8 KB/row. We therefore use a conservative >=1 KB/row peak and
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
  # report success unconditionally (a swallowed failure previously masqueraded
  # as "Generated N rows" while the txn had rolled back to 0 rows).
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

demo_tiered() {
    header "Tiered storage — start with a Postgres DB you already have"

    # Idempotent teardown: events may be a table OR a view from a prior run.
    pg "DROP TABLE IF EXISTS events CASCADE; DROP VIEW IF EXISTS events CASCADE;
        DROP TABLE IF EXISTS _events CASCADE;
        DELETE FROM coldfront.tiered_views WHERE relname='events';
        DELETE FROM coldfront.archive_watermark WHERE table_name='events';" >/dev/null 2>&1 || true

    # ── Part 1: you already have this — a data-laden plain Postgres table ──────────
    explain "Step 1 — Creating the database table: an ordinary partitioned Postgres table"
    explain "  ${DIM}We create a range-partitioned Postgres table standing in for the live${RESET}"
    explain "  ${DIM}DB you already run — no ColdFront yet.${RESET}"
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
    explain "  ${DIM}Monthly partitions covering the full data window — nothing ColdFront-specific yet.${RESET}"

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

    # Step "see the problem": how much hot storage, and it's ALL hot. Shown from
    # captured values (count alone via pg(); size summed over partitions via
    # heap_size): pg_duckdb's preloaded planner hook mishandles a count+size SELECT
    # over a partitioned parent, so we render the numbers rather than re-run it.
    local hot_before; hot_before=$(heap_size events)
    explain "See the problem — how much Postgres (hot) storage this takes, and it only grows:"
    echo -e "${DIM}─── result ─────────────────────────────────────────────────${RESET}"
    printf "  %12s   %s\n" "Rows" "Postgres heap"
    printf "  %12s   %s\n" "----" "-------------"
    printf "  %12s   %s\n" "$before" "$hot_before"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"
    info "All ${before} rows are on hot, expensive storage (${hot_before}); nothing in object storage yet."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # ── Part 2: add ColdFront to the existing database (shown, AFTER the data load) ─
    header "Add ColdFront to that database"
    ensure_coldfront_setup shown
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
    explain "Run the archiver — it moves old partitions PG → Parquet in S3 and rebuilds events as a unified view:"
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
    $COMPOSE run --rm --no-deps archiver --config /config/archiver.yaml >/tmp/wt-archiver.log 2>&1
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
        return
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

    # Proof (b): events is now a view.
    local relkind; relkind=$(pg "SELECT relkind FROM pg_class WHERE relname='events' AND relnamespace='public'::regnamespace;")
    [ "$relkind" = "v" ] && info "events is now a unified VIEW over hot + cold; _events holds only the hot remainder."

    # Step 8 — the hot/cold accounting (the payoff vs the 'see the problem' baseline).
    header "Where the data lives now — hot vs cold"
    local hot_rows total cold_rows hot_after
    hot_rows=$(pg "SELECT count(*) FROM _events;")
    total=$(pg "SELECT count(*) FROM events;")
    cold_rows=$((total - hot_rows))
    hot_after=$(heap_size _events)
    printf "  %-22s %12s   %s\n" "Tier" "Rows" "Postgres heap"
    printf "  %-22s %12s   %s\n" "----" "----" "-------------"
    printf "  %-22s %12s   %s\n" "Hot  (Postgres)"      "$hot_rows"  "$hot_after"
    printf "  %-22s %12s   %s\n" "Cold (Parquet in S3)" "$cold_rows" "0 bytes in PG"
    printf "  %-22s %12s\n"      "Total"                "$total"
    info "Before: ${before} rows, ${hot_before}, all hot. Now: ${hot_rows} rows (${hot_after}) hot; ${cold_rows} in object storage — same total, a fraction of the hot footprint."
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi

    # Step 9 — query across tiers.
    explain "One query spans both tiers — the app can't tell hot from cold:"
    show_query "SELECT id, ts, status FROM events
                 WHERE ts < date_trunc('month', now()) - interval '3 months'
                 ORDER BY ts LIMIT 3;"
    info "Those rows came from Parquet in S3 through the same events table."

    # Step 10 — write to cold data (the differentiator).
    header "Write to cold data — no rehydration, no separate tool"
    # Capture cold_id in a SEPARATE query: a sub-select over the same tiered view
    # inside the UPDATE is rejected (the rewrite retargets the leading reference).
    local cold_id; cold_id=$(pg "SELECT id FROM events WHERE ts < date_trunc('month',now()) - interval '2 months' ORDER BY ts LIMIT 1;")
    explain "Here is an archived row, living in object storage:"
    show_query "SELECT id, ts, status FROM events WHERE id=${cold_id};"
    explain "Update it through the same table — one line of plain SQL, straight to the cold tier:"
    pg "UPDATE events SET status='corrected' WHERE id=${cold_id};" >/dev/null
    show_query "SELECT id, ts, status FROM events WHERE id=${cold_id};"
    info "No rehydration, no restore job, no second tool — that row is still in S3, now corrected."

    # Step 11 — prove it stuck (fresh connection).
    header "Prove it stuck — it's real, not a session trick"
    explain "Reconnect (fresh session) and re-check the row, the total, and the hot heap:"
    show_query "SELECT id, status FROM events WHERE id=${cold_id};"
    show_query "SELECT count(*) AS total_rows FROM events;"
    local hot_final; hot_final=$(heap_size _events)
    info "Archived row still 'corrected', all ${total} rows present, hot heap still ${hot_final} — the data never came back to Postgres. That is ColdFront: cheaper storage that's still writeable."

    # No DELETE here — keeps the final count clean. (A DELETE works identically;
    # the script notes it only as an aside.) Exit cleanup is interactive-only: CI
    # runs non-interactively and asserts on the post-run state (events is a view,
    # watermark row present), so we MUST leave events/_events/watermark intact when
    # NONINTERACTIVE=1.
    if [ "$NONINTERACTIVE" != 1 ]; then
        read -rp "Drop this demo's data to reclaim disk before returning to the menu? [Y/n]: " a </dev/tty
        [[ "$a" =~ ^[Nn]$ ]] || pg "DROP TABLE IF EXISTS _events CASCADE; DROP VIEW IF EXISTS events CASCADE;
            DELETE FROM coldfront.tiered_views WHERE relname='events';
            DELETE FROM coldfront.archive_watermark WHERE table_name='events';" >/dev/null 2>&1
    fi
}
demo_decoupled() {
    ensure_coldfront_setup        # silent — ColdFront may not be installed yet if this demo ran first
    header "Decoupled — a table whose data lives in the lake, not in Postgres"

    explain "\"I want a table whose data lives in the lake from day one — full SQL,"
    explain " none of the Postgres storage cost.\" That's decoupled mode."
    explain "  ${DIM}Unlike tiered, the data is never in a Postgres heap — it starts in the lake.${RESET}"
    echo ""

    # Idempotent teardown: events_lake may be a leftover view + registry row.
    pg "DROP VIEW IF EXISTS events_lake CASCADE;
        DELETE FROM coldfront.tiered_views WHERE relname='events_lake';" >/dev/null 2>&1 || true

    # Step 2 — create the lake-native table (one call).
    explain "Create a lake-native table in one call — it makes a view + registry row, no Postgres heap:"
    if [ "$NONINTERACTIVE" != 1 ]; then prompt_continue; fi
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
    [ "$ok" = 1 ] || { error "create_iceberg_table did not succeed"; return; }
    show_query "SELECT relkind FROM pg_class WHERE relname='events_lake';"
    info "relkind = v — events_lake is a VIEW, no heap table was created. The data has nowhere to live but the lake."

    # Step 3 — registry proof (iceberg-only, no hot table).
    explain "The registry confirms it's iceberg-only, with no Postgres hot table behind it:"
    show_query "SELECT relname, is_iceberg_only, hot_table FROM coldfront.tiered_views WHERE relname='events_lake';"
    info "is_iceberg_only = t, hot_table = NULL — nothing in Postgres holds these rows."

    # Step 4 — use it like any Postgres table.
    header "Use it like any Postgres table"
    explain "Insert, read, update, delete — ordinary SQL; every write goes to Iceberg:"
    psql_file <<'EOSQL'
INSERT INTO events_lake VALUES
  (1, now(), 'ok',   '{"k":1}'),
  (2, now(), 'ok',   '{"k":2}'),
  (3, now(), 'warn', '{"k":3}');
EOSQL
    show_query "SELECT id, status, data->>'k' AS k FROM events_lake ORDER BY id;"
    pg "UPDATE events_lake SET status='corrected' WHERE id=1;" >/dev/null
    pg "DELETE FROM events_lake WHERE id=3;" >/dev/null
    show_query "SELECT id, status FROM events_lake ORDER BY id;"
    info "Full read/write SQL — your application code is identical to any Postgres table."

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
        [[ "$a" =~ ^[Nn]$ ]] || pg "DROP VIEW IF EXISTS events_lake CASCADE; DELETE FROM coldfront.tiered_views WHERE relname='events_lake';" >/dev/null 2>&1
    fi
}
demo_partitioner() {
    ensure_coldfront_setup        # silent — ColdFront may not be installed yet if this demo ran first
    header "Standalone partitioner — automated partitioning, no cold tier"
    explain "Only want automated PostgreSQL partition maintenance? The partitioner"
    explain "binary alone is the whole product — no Iceberg, no DuckDB, no cold tier."
    echo ""

    pg "DROP TABLE IF EXISTS part_demo CASCADE;" >/dev/null 2>&1 || true
    psql_file >/dev/null <<'EOSQL'
SET search_path = public;
CREATE TABLE part_demo (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL,
    note text,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
EOSQL

    explain "Register it with the partitioner (monthly, 12-month retention):"
    start_spinner "Registering + reconciling partitions"
    # --no-deps: reuse the already-running db (see the archiver note above) — a plain
    # `compose run` can recreate the db from its config hash and wipe the loaded data.
    $COMPOSE run --rm --no-deps --entrypoint partitioner archiver \
        register --config /config/partitioner.yaml --table part_demo \
        --period monthly --retention "12 months" >/tmp/wt-part.log 2>&1
    $COMPOSE run --rm --no-deps --entrypoint partitioner archiver --config /config/partitioner.yaml >>/tmp/wt-part.log 2>&1
    stop_spinner

    explain "Partitions auto-created for the forward window:"
    pg "SELECT count(*) AS partitions FROM pg_inherits WHERE inhparent='part_demo'::regclass;"
    echo ""

    # Exit cleanup is interactive-only: a NONINTERACTIVE / CI run asserts on the
    # post-run partition count, so part_demo MUST be left intact in that mode.
    if [ "$NONINTERACTIVE" != 1 ]; then
        read -rp "Drop part_demo before returning to the menu? [Y/n]: " a </dev/tty
        [[ "$a" =~ ^[Nn]$ ]] || pg "DROP TABLE IF EXISTS part_demo CASCADE;" >/dev/null 2>&1
    fi
}

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
        explain "  ${DIM}\"My Postgres database is getting expensive.\"${RESET}"
        explain "  1) Tiered storage   — relocate cold data to object storage, same table, still writeable"
        echo ""
        explain "  ${DIM}\"I want a table whose data lives in the lake from day one.\"${RESET}"
        explain "  2) Decoupled        — Postgres as a front-end to the lake (data in Iceberg from day one)"
        echo ""
        explain "  ${DIM}\"I just want automated partition maintenance.\"${RESET}"
        explain "  3) Partitioner      — automated PG range-partitioning, no cold tier"
        echo ""
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
detect_ports

# ── Detect an existing stack ────────────────────────────────────────────────
if [ "${NONINTERACTIVE:-0}" != 1 ] && [ -n "$($COMPOSE ps --status running -q 2>/dev/null)" ]; then
    echo ""
    warn "An existing ColdFront walkthrough stack is already running."
    echo ""
    explain "  1) Tear down and start fresh"
    explain "  2) Keep it running and continue"
    explain "  3) Cancel"
    echo ""
    read -rp "  Choose [1/2/3]: " _stack_choice </dev/tty
    case "$_stack_choice" in
        1)
            info "Tearing down existing stack..."
            $COMPOSE down -v
            info "Done. Starting fresh..."
            echo ""
            ;;
        3)
            info "Cancelled."
            exit 0
            ;;
        *)
            info "Keeping the stack running and continuing..."
            echo ""
            ;;
    esac
fi

phase_a_bringup
if [ "$NONINTERACTIVE" = 1 ]; then
    case "${WALKTHROUGH_DEMO:-tiered}" in
        tiered) demo_tiered;; decoupled) demo_decoupled;; partitioner) demo_partitioner;;
    esac
    exit 0
fi
main_menu
