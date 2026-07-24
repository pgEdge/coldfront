#!/bin/bash
# ci/journey.sh — THE canonical ColdFront user journey (the E2E spec).
#
# One ordered walk through every beta user story, parameterized by topology so
# the SAME assertions run in every matrix cell. Run by ci/matrix.sh after a
# topology is up (ci/topo/*.sh). Not -e: assertions must continue past a
# failure so we see the full picture; the exit code comes from summary().
#
# Usage:
#   ci/journey.sh --host <container> --db-ip <ip> --sw-ip <ip> --lk-ip <ip> \
#                 --mode tiered|decoupled [--mesh --peers "<c2> <c3>"] \
#                 [--standby <container>] [--archiver ./bin/archiver]
#
# Addresses: --host is the container name for in-DB psql (docker exec). The
# *-ip args are container IPs the host-side archiver uses to reach PG / S3 /
# Lakekeeper (the in-DB Iceberg attach uses the node's own GUCs).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/lib.sh"

HOST=""; MODE="tiered"; MESH=0; PEERS=""; STANDBY=""
DB_IP=""; SW_IP=""; LK_IP=""; WAREHOUSE="wh"
# Cold-store backend: s3 (default) or azure (ADLS Gen2, DuckDB 1.5.x stack). The
# journey STORIES are storage-agnostic — only the secret call and the archiver
# config block differ. Real azure creds come from env (never committed): the
# connection string carries the shared key (AccountName=…;AccountKey=…).
BACKEND="${COLDFRONT_BACKEND:-s3}"
AZURE_CONN="${COLDFRONT_AZURE_CONNECTION_STRING:-}"
# GCS is not a separate backend — it's the s3 path pointed at the GCS S3-interop
# endpoint with an HMAC key pair. These feed the same set_storage_secret / s3
# config block, just with the GCS endpoint + use_ssl.
GCS_KEY="${COLDFRONT_GCS_ACCESS_KEY:-}"
GCS_SECRET="${COLDFRONT_GCS_SECRET_KEY:-}"
# aws = REAL AWS S3 — the same s3 path with NO endpoint (DuckDB uses AWS-native
# vhost+HTTPS) and the bucket's real Region. Creds/Region from env (never committed).
AWS_KEY="${COLDFRONT_AWS_ACCESS_KEY:-}"
AWS_SECRET="${COLDFRONT_AWS_SECRET_KEY:-}"
AWS_REGION="${COLDFRONT_AWS_REGION:-}"
ARCHIVER="${ARCHIVER:-./bin/archiver}"
COMPACTOR="${COMPACTOR:-./bin/compactor}"
PARTITIONER="${PARTITIONER:-./bin/partitioner}"
while [ $# -gt 0 ]; do case "$1" in
  --host) HOST="$2"; shift 2;;
  --mode) MODE="$2"; shift 2;;
  --mesh) MESH=1; shift;;
  --peers) PEERS="$2"; shift 2;;
  --standby) STANDBY="$2"; shift 2;;
  --db-ip) DB_IP="$2"; shift 2;;
  --sw-ip) SW_IP="$2"; shift 2;;
  --lk-ip) LK_IP="$2"; shift 2;;
  --warehouse) WAREHOUSE="$2"; shift 2;;
  --backend) BACKEND="$2"; shift 2;;
  --azure-conn) AZURE_CONN="$2"; shift 2;;
  --archiver) ARCHIVER="$2"; shift 2;;
  --compactor) COMPACTOR="$2"; shift 2;;
  --partitioner) PARTITIONER="$2"; shift 2;;
  *) echo "journey.sh: unknown arg $1"; exit 2;;
esac; done
[ -n "$HOST" ] || { echo "journey.sh: --host required"; exit 2; }
[ "$BACKEND" = azure ] && [ -z "$AZURE_CONN" ] && { echo "journey.sh: --backend azure needs --azure-conn / COLDFRONT_AZURE_CONNECTION_STRING"; exit 2; }
[ "$BACKEND" = gcs ] && { [ -z "$GCS_KEY" ] || [ -z "$GCS_SECRET" ]; } && { echo "journey.sh: --backend gcs needs COLDFRONT_GCS_ACCESS_KEY + COLDFRONT_GCS_SECRET_KEY (HMAC)"; exit 2; }
[ "$BACKEND" = aws ] && { [ -z "$AWS_KEY" ] || [ -z "$AWS_SECRET" ] || [ -z "$AWS_REGION" ]; } && { echo "journey.sh: --backend aws needs COLDFRONT_AWS_ACCESS_KEY + COLDFRONT_AWS_SECRET_KEY + COLDFRONT_AWS_REGION"; exit 2; }

# storage_secret_sql — the SQL that sets the cold-store credential, per backend.
storage_secret_sql() {
    if [ "$BACKEND" = azure-vended ]; then
        printf "SELECT coldfront.set_storage_secret_vended('azure');"
    elif [ "$BACKEND" = vended ]; then
        # Vended (minted) creds: no credential stored. Lakekeeper mints per-table
        # STS creds and ensure_attached() uses ACCESS_DELEGATION_MODE VENDED_CREDENTIALS.
        printf "SELECT coldfront.set_storage_secret_vended();"
    elif [ "$BACKEND" = azure ]; then
        printf "SELECT coldfront.set_storage_secret_azure('%s');" "$AZURE_CONN"
    elif [ "$BACKEND" = gcs ]; then
        # GCS via S3-interop: same s3 setter, GCS endpoint + HMAC + TLS.
        printf "SELECT coldfront.set_storage_secret('%s','%s','storage.googleapis.com','us-east-1','path',true);" "$GCS_KEY" "$GCS_SECRET"
    elif [ "$BACKEND" = aws ]; then
        # REAL AWS S3: NULL endpoint ⇒ omit ENDPOINT/URL_STYLE/USE_SSL, AWS-native
        # vhost+HTTPS. Region is the bucket's real Region (drives the per-Region host).
        printf "SELECT coldfront.set_storage_secret('%s','%s',NULL,'%s');" "$AWS_KEY" "$AWS_SECRET" "$AWS_REGION"
    else
        printf "SELECT coldfront.set_storage_secret('admin','adminsecret','%s:8333');" "$SW_IP"
    fi
}

# storage_yaml — the cold-store block for an archiver YAML config, per backend.
storage_yaml() {
    if [ "$BACKEND" = vended ] || [ "$BACKEND" = azure-vended ]; then
        # Vended: the YAML carries NO storage block. The archiver reads
        # coldfront.storage_secret.vended and attaches with credential vending.
        printf ''
    elif [ "$BACKEND" = azure ]; then
        printf 'azure:\n  connection_string: "%s"' "$AZURE_CONN"
    elif [ "$BACKEND" = gcs ]; then
        # GCS = the s3 block pointed at the interop endpoint over TLS, HMAC creds.
        printf 's3:\n  endpoint: "storage.googleapis.com"\n  region: "us-east-1"\n  access_key: "%s"\n  secret_key: "%s"\n  use_ssl: true' "$GCS_KEY" "$GCS_SECRET"
    elif [ "$BACKEND" = aws ]; then
        # REAL AWS S3 = the s3 block with NO endpoint ⇒ archiver uses AWS-native
        # vhost+HTTPS (region = the bucket's real Region).
        printf 's3:\n  region: "%s"\n  access_key: "%s"\n  secret_key: "%s"' "$AWS_REGION" "$AWS_KEY" "$AWS_SECRET"
    else
        printf 's3:\n  endpoint: "%s:8333"\n  region: "us-east-1"\n  access_key: "admin"\n  secret_key: "adminsecret"' "$SW_IP"
    fi
}

step "JOURNEY  host=$HOST  mode=$MODE  mesh=$MESH  standby=${STANDBY:-none}"

# ───────────────────────────────────────────────────────────────────────────
# Story 1 — Setup: extensions + the cold-tier S3 secret via set_storage_secret.
# (GUCs warehouse/lakekeeper_endpoint live in the node's postgresql.conf; the
#  topology brought up Lakekeeper + the warehouse already.)
# ───────────────────────────────────────────────────────────────────────────
story_setup() {
    step "1. Setup (extensions, storage secret)"
    qf "$HOST" <<EOSQL >/dev/null
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
-- iceberg/avro: the patched binary is shipped in the image + autoloaded on
-- ATTACH (TYPE ICEBERG) with allow_unsigned; no install_extension needed.
-- set_storage_secret writes the in-DB row AND materializes a DuckDB PERSISTENT
-- secret (loaded at init), so cold reads/writes resolve creds with no login
-- trigger — the mechanism that works on PG 16/17/18.
$(storage_secret_sql)
EOSQL
    local ext; ext=$(q "$HOST" "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_duckdb','coldfront');")
    assert_eq "extensions present" "2" "$ext"
    local secret; secret=$(q "$HOST" "SELECT count(*) FROM coldfront.storage_secret;")
    assert_eq "storage secret row written" "1" "$secret"
    if [ "$BACKEND" = vended ] || [ "$BACKEND" = azure-vended ]; then
        assert_eq "storage secret is vended (no credential stored)" "t" \
            "$(q "$HOST" "SELECT vended FROM coldfront.storage_secret LIMIT 1;")"
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Story 2 — Provision (tiered): create a partitioned table, seed 280 rows,
# run the archiver once (swap → view → register → archive Jan/Feb).
# ───────────────────────────────────────────────────────────────────────────
story_provision_tiered() {
    step "2. Provision tiered table + seed + first archiver run"
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL,
    status text,
    data jsonb,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
-- Fake historical data over the 4 months BEFORE the current one, all derived
-- from now() (never invented calendar literals), so the hot/cold split is
-- correct under any wall clock. Months, oldest→newest: m4 m3 m2 (cold) and m1
-- (the most recent — stays hot after the cutoff below). Partitions are pre-made
-- with the partitioner's own table-scoped names (events_p_YYYY_MM) derived from
-- those months; the archiver premakes current/future and does the conversion.
DO $do$
DECLARE m date;
BEGIN
  FOR i IN 1..4 LOOP                                       -- now-4mo .. now-1mo
    m := (date_trunc('month', now()) - make_interval(months => 5 - i))::date;
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF events FOR VALUES FROM (%L) TO (%L)',
                   'events_p_' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month'));
  END LOOP;
END $do$;
INSERT INTO events (ts, status, data) SELECT date_trunc('month',now()) - interval '4 months' + interval '14 days' + (i*interval '1 hour'), 'ok', '{"m":"m4"}'::jsonb FROM generate_series(1,100) i;
INSERT INTO events (ts, status, data) SELECT date_trunc('month',now()) - interval '3 months' + interval '9 days'  + (i*interval '1 hour'), 'ok', '{"m":"m3"}'::jsonb FROM generate_series(1,80) i;
INSERT INTO events (ts, status, data) SELECT date_trunc('month',now()) - interval '2 months' + interval '4 days'  + (i*interval '1 hour'), 'ok', '{"m":"m2"}'::jsonb FROM generate_series(1,60) i;
INSERT INTO events (ts, status, data) SELECT date_trunc('month',now()) - interval '1 months'                      + (i*interval '1 hour'), 'ok', '{"m":"m1"}'::jsonb FROM generate_series(1,40) i;
EOSQL
    local seeded; seeded=$(q "$HOST" "SELECT count(*) FROM public.events;")
    assert_eq "seeded 280 rows (pre-archive, plain table)" "280" "$seeded"

    # Cutoff = the START of the most-recent seeded month (now-1mo). The archiver
    # computes cutoff = now − hot_period, so hot_period (in days) = now − that
    # month start: the m4/m3/m2 partitions are fully past it (→ cold) and m1 stays
    # hot. Anchored to now(), so this holds under any wall clock — no invented date.
    local cutoff_date; cutoff_date=$(date -u -d "$(date -u +%Y-%m-01) -1 month" +%Y-%m-%d)
    local ret_days=$(( ( $(date -u +%s) - $(date -u -d "$cutoff_date" +%s) ) / 86400 ))
    cat > /tmp/journey-archiver.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "${WAREHOUSE}"
  lakekeeper_endpoint: "http://${LK_IP}:8181/catalog"
$(storage_yaml)
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      hot_period: "${ret_days} days"
EOF
    # Managed tables live in coldfront.partition_config; seed events from the YAML.
    if ! "$ARCHIVER" import --config /tmp/journey-archiver.yaml >/tmp/journey-archiver.log 2>&1; then
        fail "import events into partition_config — see /tmp/journey-archiver.log"; tail -5 /tmp/journey-archiver.log; return
    fi
    if "$ARCHIVER" --config /tmp/journey-archiver.yaml >>/tmp/journey-archiver.log 2>&1; then
        pass "archiver first run completed"
    else
        fail "archiver first run — see /tmp/journey-archiver.log"; tail -5 /tmp/journey-archiver.log
    fi
    local relkind; relkind=$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='events' AND relnamespace='public'::regnamespace;")
    assert_eq "events is now a view" "v" "$relkind"
    local wm; wm=$(q "$HOST" "SELECT count(*) FROM coldfront.archive_watermark WHERE table_name='events';")
    assert_eq "watermark registered" "1" "$wm"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — cold retention: a second archiver run with retention_period set drops
# Iceberg data older than it (the destroy end of the lifecycle: hot →hot_period→
# cold →retention_period→ gone). By now Jan–Mar are already cold and Apr is hot,
# so nothing is past the hot window — this exercises the cold-expiry-only path.
# The retention cutoff (start of now-3mo, = m4 boundary) drops the m4 cold rows and keeps m3/m2.
# Runs last so it doesn't perturb earlier stories' counts; jan_before is read
# dynamically so the row-math holds regardless of what else landed in cold.
# ───────────────────────────────────────────────────────────────────────────
story_cold_retention() {
    step "Cold retention: drop Iceberg data past retention_period"
    local before jan_before
    before=$(q "$HOST" "SELECT count(*) FROM events;")
    jan_before=$(q "$HOST" "SELECT count(*) FROM events WHERE ts >= date_trunc('month',now()) - interval '4 months' AND ts < date_trunc('month',now()) - interval '3 months';")
    assert_gt "m4 cold rows present before retention" "0" "$jan_before"

    local ret_days ret_long hot_date drop_date
    hot_date=$(date -u -d "$(date -u +%Y-%m-01) -1 month" +%Y-%m-%d)              # hot cutoff  = start of now-1mo
    drop_date=$(date -u -d "$(date -u +%Y-%m-01) -3 month" +%Y-%m-%d)             # drop cutoff = start of now-3mo (m4 boundary)
    ret_days=$(( ( $(date -u +%s) - $(date -u -d "$hot_date" +%s) ) / 86400 ))
    ret_long=$(( ( $(date -u +%s) - $(date -u -d "$drop_date" +%s) ) / 86400 ))
    cat > /tmp/journey-coldret.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "${WAREHOUSE}"
  lakekeeper_endpoint: "http://${LK_IP}:8181/catalog"
$(storage_yaml)
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      hot_period: "${ret_days} days"
      retention_period: "${ret_long} days"
EOF
    # events is already managed (tiered); add the drop boundary via set.
    if ! "$ARCHIVER" set --config /tmp/journey-coldret.yaml --table events --retention "${ret_long} days" >/tmp/journey-coldret.log 2>&1; then
        fail "set retention on events — see /tmp/journey-coldret.log"; tail -5 /tmp/journey-coldret.log; return
    fi
    if "$ARCHIVER" --config /tmp/journey-coldret.yaml >>/tmp/journey-coldret.log 2>&1; then
        pass "archiver cold-retention run completed"
    else
        fail "archiver cold-retention run — see /tmp/journey-coldret.log"; tail -5 /tmp/journey-coldret.log
    fi
    assert_eq "m4 cold rows dropped by retention" "0" \
        "$(q "$HOST" "SELECT count(*) FROM events WHERE ts >= date_trunc('month',now()) - interval '4 months' AND ts < date_trunc('month',now()) - interval '3 months';")"
    assert_gt "m3 cold rows retained" "0" \
        "$(q "$HOST" "SELECT count(*) FROM events WHERE ts >= date_trunc('month',now()) - interval '3 months' AND ts < date_trunc('month',now()) - interval '2 months';")"
    assert_eq "exactly the past-retention rows were removed" "$((before - jan_before))" \
        "$(q "$HOST" "SELECT count(*) FROM events;")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 2 (decoupled) — provision an all-Iceberg table via create_iceberg_table:
# a shared Lakekeeper-stored Iceberg table + a PG wrapper view + an is_iceberg_
# only registry row. No PG hot tier. The C hook routes all DML to Iceberg.
# ───────────────────────────────────────────────────────────────────────────
story_provision_decoupled() {
    step "2. Provision decoupled (iceberg-only) table"
    # The Iceberg namespace is pre-seeded at warehouse provisioning (see
    # ci/topo/*.sh): DuckDB 1.5.x defers an Iceberg CREATE SCHEMA to COMMIT but
    # POSTs CREATE TABLE eagerly, so create_iceberg_table — which runs both in
    # ONE plpgsql transaction — would 404 on a cold warehouse (the table POST
    # references a namespace not yet committed). With the namespace already
    # committed, its in-txn CREATE SCHEMA IF NOT EXISTS no-ops and CREATE TABLE
    # succeeds. The loop is a thin safety net in case seeding raced the warehouse.
    local i
    for i in 1 2 3 4 5; do
        q_may "$HOST" "SELECT coldfront.create_iceberg_table('public','iceonly','[{\"name\":\"id\",\"type\":\"bigint\"},{\"name\":\"ts\",\"type\":\"timestamptz\"},{\"name\":\"status\",\"type\":\"text\"},{\"name\":\"data\",\"type\":\"jsonb\"}]'::jsonb);" >/dev/null 2>&1
        [ "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='iceonly' AND relkind='v' AND relnamespace='public'::regnamespace;")" = "1" ] && break
        sleep 2
    done
    assert_eq "iceonly wrapper view created" "v" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='iceonly' AND relnamespace='public'::regnamespace;")"
    assert_eq "iceberg-only registry row present" "1" "$(q "$HOST" "SELECT count(*) FROM coldfront.tiered_views WHERE is_iceberg_only AND iceberg_table='ice.public.iceonly';")"
    assert_eq "no hot table for iceberg-only view" "" "$(q "$HOST" "SELECT hot_table FROM coldfront.tiered_views WHERE iceberg_table='ice.public.iceonly';")"
}

# ───────────────────────────────────────────────────────────────────────────
# Decoupled CRUD — every DML on the wrapper view is rewritten by the C hook to
# a single duckdb.raw_query against Iceberg (no INSTEAD OF trigger). Covers the
# INSERT shapes, jsonb surfacing, UPDATE, DELETE.
# ───────────────────────────────────────────────────────────────────────────
story_decoupled_crud() {
    step "6. Decoupled CRUD (INSERT/SELECT/UPDATE/DELETE → Iceberg via the hook)"
    local O; O=$(qf "$HOST" <<'EOSQL'
INSERT INTO iceonly VALUES (1,date_trunc('month',now()) + interval '10 hours 0 minutes 0 seconds','s1','{"a":1}'),(2,date_trunc('month',now()) + interval '10 hours 0 minutes 1 seconds','s2','{"a":2}');
SELECT 'CNT:'||count(*) FROM iceonly;
SELECT 'JSONTYPE:'||pg_typeof(data)::text FROM iceonly LIMIT 1;
SELECT 'JSON:'||(data->>'a') FROM iceonly WHERE id=1;
INSERT INTO iceonly VALUES (10,date_trunc('month',now()) + interval '10 hours 1 minutes 0 seconds','multi','{}'),(11,date_trunc('month',now()) + interval '10 hours 1 minutes 1 seconds','multi','{}'),(12,date_trunc('month',now()) + interval '10 hours 1 minutes 2 seconds','multi','{}');
SELECT 'MULTI:'||count(*) FROM iceonly WHERE status='multi';
UPDATE iceonly SET status='upd' WHERE id=1;
SELECT 'UPD:'||status FROM iceonly WHERE id=1;
DELETE FROM iceonly WHERE id=2;
SELECT 'DEL:'||count(*) FROM iceonly WHERE id=2;
EOSQL
)
    assert_eq "decoupled INSERT + read (2 rows)"        "2"    "$(extract CNT "$O")"
    assert_eq "decoupled jsonb surfaces as json"        "json" "$(extract JSONTYPE "$O")"
    assert_eq "decoupled jsonb round-trip (data->>a)"   "1"    "$(extract JSON "$O")"
    assert_eq "decoupled multi-row INSERT (3 rows)"     "3"    "$(extract MULTI "$O")"
    assert_eq "decoupled UPDATE visible"                "upd"  "$(extract UPD "$O")"
    assert_eq "decoupled DELETE visible (0 of id=2)"    "0"    "$(extract DEL "$O")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 6b' — Decoupled CRUD from INSIDE plpgsql (a DO block). Every iceonly DML
# is cold (emit_tiered_insert / emit_cold); a plpgsql var ⇒ a $N kept live via
# format() (Cause 1), and inside plpgsql the rewrite is the DML-tagged carrier
# shape (Cause 2). RED before / GREEN after. Exercises the jsonb param branch.
# ───────────────────────────────────────────────────────────────────────────
story_decoupled_plpgsql() {
    step "6b'. Decoupled CRUD from inside plpgsql (DO block, bound params)"
    local O; O=$(qf "$HOST" <<'EOSQL'
DO $$
DECLARE v_id int := 500; v_st text := 'pp_ins'; v_data jsonb := '{"k":1}';
BEGIN INSERT INTO iceonly VALUES (v_id,date_trunc('month',now()) + interval '1 days' + interval '10 hours 0 minutes 0 seconds',v_st,v_data); END $$;
SELECT 'PP_INS:' || count(*) FROM iceonly WHERE id=500;
DO $$
DECLARE v_id int := 500; v_new text := 'pp_upd';
BEGIN UPDATE iceonly SET status = v_new WHERE id = v_id; END $$;
SELECT 'PP_UPD:' || coalesce(max(status),'<none>') FROM iceonly WHERE id=500;
DO $$
DECLARE v_id int := 500;
BEGIN DELETE FROM iceonly WHERE id = v_id; END $$;
SELECT 'PP_DEL:' || count(*) FROM iceonly WHERE id=500;
EOSQL
)
    assert_eq "decoupled plpgsql INSERT (var values incl. jsonb)" "1"      "$(extract PP_INS "$O")"
    assert_eq "decoupled plpgsql UPDATE (var SET+WHERE)"          "pp_upd" "$(extract PP_UPD "$O")"
    assert_eq "decoupled plpgsql DELETE (var WHERE)"              "0"      "$(extract PP_DEL "$O")"
}

# ───────────────────────────────────────────────────────────────────────────
# Decoupled concurrency / no-409 — parallel cold writers to ONE iceberg-only
# table must all land. Vanilla serializes them with the local advisory-lock
# bakery (_exec_iceberg_with_claim, v_armed=false → pg_advisory_xact_lock);
# without it, concurrent Iceberg commits race Lakekeeper's assert-ref-snapshot
# precondition and 409 (CatalogCommitConflict), silently losing rows. (Standing
# rule: multi-writer no-409 probe in vanilla. The bakery is essential.)
# ───────────────────────────────────────────────────────────────────────────
story_decoupled_concurrency() {
    step "9. Concurrency: parallel cold writers serialize via the bakery (no 409)"
    local k pids=()
    rm -f /tmp/journey-conc.* 2>/dev/null
    for k in 1 2 3 4 5 6 7 8; do
        q "$HOST" "INSERT INTO iceonly VALUES (${k}00,date_trunc('month',now()) + interval '1 month' + interval '$((k-1)) days' + interval '10 hours','conc','{}');" >/tmp/journey-conc.$k 2>&1 &
        pids+=("$!")
    done
    local p; for p in "${pids[@]}"; do wait "$p"; done
    assert_eq "no concurrent cold writer errored (no 409/abort)" "0" \
        "$(cat /tmp/journey-conc.* 2>/dev/null | grep -cEi 'error|conflict|409')"
    assert_eq "8 concurrent cold writers all landed (no 409/loss)" "8" \
        "$(q "$HOST" "SELECT count(*) FROM iceonly WHERE status='conc';")"
    rm -f /tmp/journey-conc.* 2>/dev/null
}

# ───────────────────────────────────────────────────────────────────────────
# Decoupled read-your-own-write — the wrapper view sources duckdb.query (not
# iceberg_scan), so an in-transaction SELECT sees the same tx's prior write,
# and ROLLBACK undoes the Iceberg INSERT (pg_duckdb XactCallback ties the txns).
# ───────────────────────────────────────────────────────────────────────────
story_decoupled_ryw() {
    step "10. Decoupled read-your-own-write + rollback"
    local O; O=$(qf "$HOST" <<'EOSQL'
BEGIN;
INSERT INTO iceonly VALUES (99,date_trunc('month',now()) + interval '11 hours 0 minutes 0 seconds','in_tx','{}');
SELECT 'INTX:'||count(*) FROM iceonly WHERE id=99;
ROLLBACK;
SELECT 'POSTRB:'||count(*) FROM iceonly WHERE id=99;
EOSQL
)
    assert_eq "in-tx SELECT sees just-inserted iceberg row" "1" "$(extract INTX "$O")"
    assert_eq "ROLLBACK undoes the iceberg INSERT"          "0" "$(extract POSTRB "$O")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 4 — Reads + jsonb surfacing (proven assertions from run-ci-local).
# ───────────────────────────────────────────────────────────────────────────
story_reads() {
    step "4. Reads (hot/cold/cross-tier, jsonb surfacing)"
    local O; O=$(qf "$HOST" <<'EOSQL'
SELECT 'RO_TOTAL:' || count(*) FROM events;
SELECT 'RO_HOT:'   || count(*) FROM events WHERE ts >= date_trunc('month',now()) - interval '2 months';
SELECT 'RO_COLD:'  || count(*) FROM events WHERE ts  < date_trunc('month',now()) - interval '2 months';
SELECT 'JSONB_TYPE:'   || pg_typeof(data)::text FROM events LIMIT 1;
SELECT 'JSONB_COLD_M:' || (data->>'m') FROM events WHERE ts < date_trunc('month',now()) - interval '2 months' AND status='ok' ORDER BY ts LIMIT 1;
SELECT 'JSONB_HOT_M:'  || (data->>'m') FROM events WHERE ts >= date_trunc('month',now()) - interval '2 months' AND status='ok' ORDER BY ts LIMIT 1;
-- Read-path jsonb→json whitelist. The whole view query runs in DuckDB; the hook
-- translates the ::jsonb cast (so an explicit cast does not hit DuckDB's missing
-- jsonb type) and jsonb_array_length (verified identical in both engines). Cold and
-- hot, on real Iceberg data.
SELECT 'CAST_COLD:' || ((data::jsonb)->>'m') FROM events WHERE ts < date_trunc('month',now()) - interval '2 months' AND status='ok' ORDER BY ts LIMIT 1;
SELECT 'CAST_HOT:'  || ((data::jsonb)->>'m') FROM events WHERE ts >= date_trunc('month',now()) - interval '2 months' AND status='ok' ORDER BY ts LIMIT 1;
SELECT 'ALEN_COLD:' || jsonb_array_length('[10,20,30]'::jsonb) FROM events WHERE ts < date_trunc('month',now()) - interval '2 months' AND status='ok' ORDER BY ts LIMIT 1;
EOSQL
)
    assert_eq "total rows (hot+cold via view)" "280"  "$(extract RO_TOTAL "$O")"
    assert_eq "rows ts>=now-2mo (m2 cold + m1 hot)" "100" "$(extract RO_HOT "$O")"
    assert_eq "cold rows ts<now-2mo (m4+m3, read from Iceberg)" "180" "$(extract RO_COLD "$O")"
    assert_eq "data surfaces as json" "json" "$(extract JSONB_TYPE "$O")"
    assert_eq "json cold round-trip"  "m4"  "$(extract JSONB_COLD_M "$O")"
    assert_eq "json hot round-trip"   "m2"  "$(extract JSONB_HOT_M "$O")"
    assert_eq "::jsonb cast translated, cold" "m4" "$(extract CAST_COLD "$O")"
    assert_eq "::jsonb cast translated, hot"  "m2" "$(extract CAST_HOT "$O")"
    assert_eq "jsonb_array_length→json_array_length" "3" "$(extract ALEN_COLD "$O")"

    # Hot-tier read routing: a read whose WHERE provably restricts to the hot tier
    # (ts >= the watermark) is rewritten to the hot heap and runs in plain PostgreSQL,
    # so jsonb operators/functions DuckDB lacks (jsonb_typeof, @>) work. m1..m4 all
    # predate the watermark (date_trunc('month',now())), so insert a now() row (hot),
    # exercise it, then delete it — the row counts asserted above stay intact.
    qf "$HOST" >/dev/null <<'EOSQL'
INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{"m":"hotjson","arr":[1,2,3]}'::jsonb);
EOSQL
    local HR; HR=$(qf "$HOST" <<'EOSQL'
SELECT 'HOT_TYPEOF:'  || jsonb_typeof(data::jsonb)                         FROM events WHERE ts >= date_trunc('month',now()) AND data->>'m'='hotjson';
SELECT 'HOT_CONTAIN:' || ((data::jsonb) @> '{"m":"hotjson"}'::jsonb)::text FROM events WHERE ts >= date_trunc('month',now()) AND data->>'m'='hotjson';
SELECT 'HOT_HASKEY:' || ((data::jsonb) ? 'arr')::text                     FROM events WHERE ts >= date_trunc('month',now()) AND data->>'m'='hotjson';
EOSQL
)
    qf "$HOST" >/dev/null <<'EOSQL'
DELETE FROM events WHERE ts >= date_trunc('month',now()) AND data->>'m'='hotjson';
EOSQL
    assert_eq "hot read routes to PG: jsonb_typeof (DuckDB lacks it)"   "object" "$(extract HOT_TYPEOF "$HR")"
    assert_eq "hot read routes to PG: @> containment (DuckDB lacks it)" "true"   "$(extract HOT_CONTAIN "$HR")"
    assert_eq "hot read routes to PG: ? key-exists (DuckDB lacks it)"   "true"   "$(extract HOT_HASKEY "$HR")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 5 — Data-type matrix: round-trip every supported type through hot+cold.
# A separate tiered table whose Jan partition is archived (cold) and Apr stays
# hot; one representative value per type written to each tier and read back.
# ───────────────────────────────────────────────────────────────────────────
story_types() {
    step "5. Data-type matrix round-trip (hot + cold)"
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS typed (
    id      bigint GENERATED ALWAYS AS IDENTITY,
    ts      timestamptz NOT NULL,
    c_int   integer, c_small smallint, c_real real, c_dbl double precision,
    c_bool  boolean, c_date date, c_uuid uuid, c_txt text, c_vc varchar(8),
    c_bytea bytea, c_num numeric(20,5), c_jsonb jsonb,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
-- Partitions for the m4 (cold) and m1 (hot) months, table-scoped names derived
-- from now()-relative months (never invented calendar literals).
DO $do$
DECLARE m date;
BEGIN
  FOREACH m IN ARRAY ARRAY[(date_trunc('month',now()) - interval '4 months')::date,
                           (date_trunc('month',now()) - interval '1 month')::date] LOOP
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF typed FOR VALUES FROM (%L) TO (%L)',
                   'typed_p_' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month'));
  END LOOP;
END $do$;
-- inet/cidr are intentionally absent: pg_duckdb cannot process inet (Oid 869)
-- in an Iceberg-backed query, so they are rejected at provisioning (asserted
-- below). IP data is stored as text instead.
INSERT INTO typed (ts,c_int,c_small,c_real,c_dbl,c_bool,c_date,c_uuid,c_txt,c_vc,c_bytea,c_num,c_jsonb)
VALUES (date_trunc('month',now()) - interval '4 months' + interval '9 days', 42, 7, 1.5, 2.5, true, (date_trunc('month',now()) - interval '4 months' + interval '9 days')::date, '11111111-1111-1111-1111-111111111111','hi','abc','\xdeadbeef'::bytea, 123.45, '{"k":1}');
INSERT INTO typed (ts,c_int,c_small,c_real,c_dbl,c_bool,c_date,c_uuid,c_txt,c_vc,c_bytea,c_num,c_jsonb)
VALUES (date_trunc('month',now()) - interval '1 month' + interval '9 days', 42, 7, 1.5, 2.5, true, (date_trunc('month',now()) - interval '4 months' + interval '9 days')::date, '11111111-1111-1111-1111-111111111111','hi','abc','\xdeadbeef'::bytea, 123.45, '{"k":1}');
EOSQL
    # Same fixed-cutoff pin as events (cutoff = start of now-1mo): typed's m4
    # partition cold, m1 hot, deterministically.
    local ret_days=$(( ( $(date -u +%s) - $(date -u -d "$(date -u +%Y-%m-01) -1 month" +%s) ) / 86400 ))
    cat > /tmp/journey-typed.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog" }
$(storage_yaml)
archiver: { tables: [ { source_table: typed, partition_period: monthly, hot_period: "${ret_days} days" } ] }
EOF
    if ! "$ARCHIVER" import --config /tmp/journey-typed.yaml >/tmp/journey-typed.log 2>&1; then
        fail "import typed into partition_config — see /tmp/journey-typed.log"; tail -5 /tmp/journey-typed.log; return
    fi
    if "$ARCHIVER" --config /tmp/journey-typed.yaml >>/tmp/journey-typed.log 2>&1; then
        pass "typed table archived (Jan → cold)"
    else
        fail "typed archive — see /tmp/journey-typed.log"; tail -5 /tmp/journey-typed.log
    fi
    local O; O=$(qf "$HOST" <<'EOSQL'
SELECT 'COLD_NUM:'  || c_num::text   FROM typed WHERE ts < date_trunc('month',now()) - interval '3 months';
SELECT 'COLD_UUID:' || c_uuid::text  FROM typed WHERE ts < date_trunc('month',now()) - interval '3 months';
SELECT 'COLD_SMALL:'|| c_small::text FROM typed WHERE ts < date_trunc('month',now()) - interval '3 months';
SELECT 'COLD_BOOL:' || c_bool::text  FROM typed WHERE ts < date_trunc('month',now()) - interval '3 months';
-- bytea: encode()/hex() aren't exposed through pg_duckdb and its ::text render
-- carries backslashes that the shell's echo mangles. Compare the cold value to
-- the hot source value as a bool — backslash-free and verifies content fidelity.
SELECT 'BYTEAEQ:' || (c_bytea = (SELECT c_bytea FROM typed WHERE ts >= date_trunc('month',now()) - interval '1 month' LIMIT 1))::text FROM typed WHERE ts < date_trunc('month',now()) - interval '3 months';
-- Native byte count: '\xdeadbeef' is 4 bytes. A stringification bug would store
-- the 10-char text '\xdeadbeef' (10 bytes). Independent of the equality check.
SELECT 'BYTEALEN:' || octet_length(c_bytea)::text FROM typed WHERE ts < date_trunc('month',now()) - interval '3 months';
SELECT 'HOT_NUM:'   || c_num::text   FROM typed WHERE ts >= date_trunc('month',now()) - interval '1 month';
EOSQL
)
    assert_eq "cold numeric(20,5) round-trip" "123.45000" "$(extract COLD_NUM "$O")"
    assert_eq "cold uuid round-trip"  "11111111-1111-1111-1111-111111111111" "$(extract COLD_UUID "$O")"
    assert_eq "cold smallint round-trip (widened to int)" "7" "$(extract COLD_SMALL "$O")"
    assert_eq "cold boolean round-trip" "true"   "$(extract COLD_BOOL "$O")"
    assert_eq "cold bytea round-trip (cold == hot source)" "true" "$(extract BYTEAEQ "$O")"
    assert_eq "cold bytea stored as 4 native bytes" "4" "$(extract BYTEALEN "$O")"
    assert_eq "hot numeric round-trip" "123.45000" "$(extract HOT_NUM "$O")"

    # Cold INSERT via the view trigger (ts < cutoff) must store bytea NATIVELY,
    # not ::text-stringified. '\xcafe' is 2 bytes; a stringification bug would
    # store the 6-char text '\xcafe' (6 bytes). Exercises the trigger cold path,
    # distinct from the archiver bulk-export path above.
    local CI; CI=$(qf "$HOST" <<'EOSQL'
INSERT INTO typed (ts,c_int,c_small,c_real,c_dbl,c_bool,c_date,c_uuid,c_txt,c_vc,c_bytea,c_num,c_jsonb)
VALUES (date_trunc('month',now()) - interval '4 months' + interval '19 days', 1,1,1,1,true,(date_trunc('month',now()) - interval '4 months' + interval '19 days')::date,'22222222-2222-2222-2222-222222222222','x','y','\xcafe'::bytea, 1.0, '{}');
SELECT 'COLDINS_LEN:' || octet_length(c_bytea)::text FROM typed
  WHERE c_uuid = '22222222-2222-2222-2222-222222222222' AND ts < date_trunc('month',now()) - interval '3 months';
EOSQL
)
    assert_eq "cold-INSERT-via-trigger bytea stored natively (2 bytes)" "2" "$(extract COLDINS_LEN "$CI")"

    # inet/cidr/oid are rejected at provisioning: no cast makes them readable
    # through pg_duckdb once the table is Iceberg-backed. Match the specific
    # rejection text, not just the type name (which the input itself contains).
    local IE; IE=$(q_may "$HOST" "SELECT coldfront.create_iceberg_table('public','ip_reject','[{\"name\":\"a\",\"type\":\"inet\"}]'::jsonb);")
    assert_contains "inet rejected at provisioning" "store IP data as text" "$IE"
    # oid archives but its column is unreadable through the pg_duckdb-planned
    # view after cutover, so it is rejected up front like inet; use bigint.
    local OE; OE=$(q_may "$HOST" "SELECT coldfront.create_iceberg_table('public','oid_reject','[{\"name\":\"a\",\"type\":\"oid\"}]'::jsonb);")
    assert_contains "oid rejected at provisioning" "oid values as bigint" "$OE"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 6 — Writes via the view (proven assertions from run-ci-local).
# ───────────────────────────────────────────────────────────────────────────
story_writes() {
    step "6. Writes via view (hot/cold INSERT-UPDATE-DELETE, dual-tier)"
    local O; O=$(qf "$HOST" <<'EOSQL'
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '1 month' + interval '8 days' + interval '12 hours','ci_hot_ins','{}');
SELECT 'RW_HOT_INS:'  || count(*) FROM _events WHERE status='ci_hot_ins';
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '14 days' + interval '12 hours','ci_cold_ins','{}');
SELECT 'RW_COLD_INS:' || count(*) FROM events WHERE status='ci_cold_ins';
UPDATE events SET status='ci_hot_upd' WHERE ts=date_trunc('month',now()) - interval '1 month' + interval '8 days' + interval '12 hours' AND status='ci_hot_ins';
SELECT 'RW_HOT_UPD:'  || status FROM _events WHERE ts=date_trunc('month',now()) - interval '1 month' + interval '8 days' + interval '12 hours';
UPDATE events SET status='ci_cold_upd' WHERE ts=date_trunc('month',now()) - interval '4 months' + interval '14 days' + interval '1 hour';
SELECT 'RW_COLD_UPD:' || count(*) FROM events WHERE status='ci_cold_upd';
DELETE FROM events WHERE ts=date_trunc('month',now()) - interval '1 month' + interval '8 days' + interval '12 hours' AND status='ci_hot_upd';
SELECT 'RW_HOT_DEL:'  || count(*) FROM _events WHERE status='ci_hot_upd';
DELETE FROM events WHERE ts=date_trunc('month',now()) - interval '4 months' + interval '14 days' + interval '1 hour' AND status='ci_cold_upd';
SELECT 'RW_COLD_DEL:' || count(*) FROM events WHERE status='ci_cold_upd';
SELECT 'DUAL_HOT_PRE:'    || count(*) FROM _events WHERE status='ok';
SELECT 'DUAL_TOTAL_PRE:'  || count(*) FROM events  WHERE status='ok';
UPDATE events SET status='dual_upd' WHERE status='ok';
SELECT 'DUAL_HOT_POST:'   || count(*) FROM _events WHERE status='dual_upd';
SELECT 'DUAL_TOTAL_POST:' || count(*) FROM events  WHERE status='dual_upd';
SELECT 'DUAL_REMAINING_OK:' || count(*) FROM events WHERE status='ok';
EOSQL
)
    assert_eq "hot insert via view"  "1" "$(extract RW_HOT_INS "$O")"
    assert_eq "cold insert via view" "1" "$(extract RW_COLD_INS "$O")"
    assert_eq "hot update via view"  "ci_hot_upd" "$(extract RW_HOT_UPD "$O")"
    assert_eq "cold update via view" "1" "$(extract RW_COLD_UPD "$O")"
    assert_eq "hot delete via view"  "0" "$(extract RW_HOT_DEL "$O")"
    assert_eq "cold delete via view" "0" "$(extract RW_COLD_DEL "$O")"
    # Mixed-tier (dual) write hit BOTH tiers: the hot count is preserved and the
    # total (hot+cold) is preserved, and total>hot proves cold rows were in play.
    local dhp dtp; dhp=$(extract DUAL_HOT_PRE "$O"); dtp=$(extract DUAL_TOTAL_PRE "$O")
    assert_eq "mixed write updated the hot tier"        "$dhp" "$(extract DUAL_HOT_POST "$O")"
    assert_eq "mixed write updated both tiers (total)"  "$dtp" "$(extract DUAL_TOTAL_POST "$O")"
    assert_gt "mixed write genuinely spanned the cold tier" "$dhp" "$dtp"
    assert_eq "dual update cleared all ok" "0" "$(extract DUAL_REMAINING_OK "$O")"
    # Strict mode rejects an ambiguous predicate.
    local e; e=$(q_may "$HOST" "SET coldfront.allow_mixed_writes=off; UPDATE events SET status='x' WHERE data->>'m'='nope';")
    assert_err "strict mode rejects ambiguous predicate" "must include" "$e"
    # A self-join / second reference to the tiered view is rejected cleanly (the
    # rewrite retargets only the leading reference — see ARCHITECTURE_TIERED).
    local sj; sj=$(q_may "$HOST" "UPDATE events SET status='x' FROM events e2 WHERE events.ts=e2.ts;")
    assert_err "self-join on a tiered view rejected" "more than once" "$sj"
    # RETURNING that touches the cold tier is rejected (duckdb-iceberg can't return
    # rows) rather than silently returning a partial/void result.
    local cr; cr=$(q_may "$HOST" "UPDATE events SET status='x' WHERE ts < date_trunc('month',now()) - interval '3 months' RETURNING id;")
    assert_err "cold-tier RETURNING rejected" "cold tier" "$cr"
    story_cross_tier_move
}

# ───────────────────────────────────────────────────────────────────────────
# Story 6c — Cross-tier move: an UPDATE whose SET changes the partition column
# across the hot/cold cutoff relocates the row between tiers. Permissive mode
# (coldfront.allow_mixed_writes, default
# on) performs the move; strict mode rejects it. Each scenario seeds its own
# rows with a distinct status marker so the counts are independent of prior
# stories. "Hot" is membership in the _events heap; total is the view.
#  - HOT ts that has a pre-made partition: now-1mo + 10d (m1, seeded hot above).
#  - COLD ts: now-4mo + 10d (m4, archived).
# ───────────────────────────────────────────────────────────────────────────
story_cross_tier_move() {
    step "6c. Cross-tier move (partition-key UPDATE relocates the row)"
    local O; O=$(qf "$HOST" <<'EOSQL'
-- cold→hot: seed one cold row, then move its ts into the hot range.
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '10 days','move_c2h','{}');
UPDATE events SET ts = date_trunc('month',now()) - interval '1 month' + interval '10 days' WHERE status='move_c2h';
SELECT 'C2H_TOTAL:' || count(*) FROM events  WHERE status='move_c2h';
SELECT 'C2H_HOT:'   || count(*) FROM _events WHERE status='move_c2h';
-- hot→cold: seed one hot row, then move its ts into the cold range.
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '1 month' + interval '10 days','move_h2c','{}');
UPDATE events SET ts = date_trunc('month',now()) - interval '4 months' + interval '10 days' WHERE status='move_h2c';
SELECT 'H2C_TOTAL:' || count(*) FROM events  WHERE status='move_h2c';
SELECT 'H2C_HOT:'   || count(*) FROM _events WHERE status='move_h2c';
-- row-dependent SET that moves only SOME rows: one cold row crosses into hot
-- (cold + 4mo lands in m1 hot), one stays cold (m4 + 1mo = m3, still cold).
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '3 months' + interval '10 days','move_mix','{}');
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '10 days','move_mix','{}');
SELECT 'MIX_TOTAL_PRE:' || count(*) FROM events WHERE status='move_mix';
UPDATE events SET ts = ts + interval '2 months' WHERE status='move_mix';
SELECT 'MIX_TOTAL_POST:' || count(*) FROM events  WHERE status='move_mix';
SELECT 'MIX_HOT_POST:'   || count(*) FROM _events WHERE status='move_mix';
-- A row-dependent SET with a value-independent WHERE must apply the new value
-- exactly once: the cold→hot row, once inserted into the heap, must not be
-- updated a second time by the in-place stay-hot UPDATE. m3+10d + 2mo = m1+10d.
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '3 months' + interval '10 days','move_dbl','{}');
UPDATE events SET ts = ts + interval '2 months' WHERE status='move_dbl';
SELECT 'DBL_ONCE:' || (ts = date_trunc('month',now()) - interval '1 month' + interval '10 days')::text FROM events WHERE status='move_dbl';
EOSQL
)
    assert_eq "cold→hot move: row preserved (total)" "1" "$(extract C2H_TOTAL "$O")"
    assert_eq "cold→hot move: row now in the hot heap" "1" "$(extract C2H_HOT "$O")"
    assert_eq "hot→cold move: row preserved (total)" "1" "$(extract H2C_TOTAL "$O")"
    assert_eq "hot→cold move: row no longer in the hot heap" "0" "$(extract H2C_HOT "$O")"
    # A row-dependent SET moves only the rows whose new ts crosses the cutoff; no
    # row is lost and the partial split lands in the right tiers.
    local mp; mp=$(extract MIX_TOTAL_PRE "$O")
    assert_eq "row-dependent move: no row lost (total preserved)" "$mp" "$(extract MIX_TOTAL_POST "$O")"
    assert_eq "row-dependent move: exactly the crossing row went hot" "1" "$(extract MIX_HOT_POST "$O")"
    # The crossing row's new value is applied exactly once, not re-applied by the
    # in-place stay-hot UPDATE after it is inserted into the heap.
    assert_eq "row-dependent cold→hot move applies the new value exactly once" "true" "$(extract DBL_ONCE "$O")"
    # A move whose target hot ts has no pre-made partition is rejected cleanly,
    # naming the view, and must not leak the internal _events heap name in any form.
    local np; np=$(q_may "$HOST" "UPDATE events SET ts = now() + interval '20 years' WHERE status='move_c2h';")
    assert_err "move to a ts with no hot partition rejected" "events" "$np"
    case "$np" in
        *"no partition of relation"*) fail "raw partition-routing error leaked: $np";;
        *_events*)                    fail "internal _events name leaked: $np";;
        *)                            pass "no raw partition error or _events name leaked";;
    esac
    # Strict mode still rejects any partition-key SET (no atomic move to fall back on).
    local sm; sm=$(q_may "$HOST" "SET coldfront.allow_mixed_writes=off; UPDATE events SET ts = date_trunc('month',now()) - interval '4 months' + interval '10 days' WHERE status='move_c2h';")
    assert_err "strict mode rejects the cross-tier move" "partition column" "$sm"
}

# ───────────────────────────────────────────────────────────────────────────
# require_compactor — stories 6d/6e drive the standalone Go compactor (cmd/compactor,
# a separate iceberg-go module). Assert its binary is present before they run: a missing
# "$COMPACTOR" otherwise gets captured into the dry-run output as "No such file or
# directory" and reported as "nothing to compact", masking the real cause:
# 6d/6e ran against a vanilla.sh that never built the compactor.
require_compactor() {
    [ -x "$COMPACTOR" ] && return 0
    fail "compactor binary not found/executable at $COMPACTOR — build it with 'make compactor'; stories 6d/6e require it"
    return 1
}

# Story 6d — Compaction: the standalone Go compactor (cmd/compactor) consolidates
# the cold tier's many small Parquet files into fewer large ones via
# apache/iceberg-go RewriteDataFiles, serialized through the bakery (the SAME
# claim cold writes take — coldfront._claim_iceberg_external, formally cleared in
# docs/formal). The compactor reads the SAME deployment YAML the archiver does
# (/tmp/journey-archiver.yaml). We use the compactor's own --dry-run as the
# file-count oracle: it reports group(s) before, "nothing to compact" after, and
# all rows survive. Six same-day cold INSERTs guarantee >= MinInputFiles (5) small
# files in one group regardless of prior stories.
# ───────────────────────────────────────────────────────────────────────────
story_compaction() {
    # The manifest-list format-version interop patch (docker/iceberg-manifest-list-
    # format-version-v15.patch) tags the manifest list Avro with the table's
    # format-version, so apache/iceberg-go reads the (v2) manifests instead of
    # defaulting to v1 and rejecting them at PlanFiles (manifest.go:629). This live
    # story validates that fix end-to-end.
    step "6d. Compaction: iceberg-go RewriteDataFiles consolidates small cold files (bakery-serialized)"
    require_compactor || return
    qf "$HOST" <<'EOSQL'
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '1 days' + interval '0 hours','cmp1','{}');
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '1 days' + interval '1 hours','cmp2','{}');
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '1 days' + interval '2 hours','cmp3','{}');
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '1 days' + interval '3 hours','cmp4','{}');
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '1 days' + interval '4 hours','cmp5','{}');
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '1 days' + interval '5 hours','cmp6','{}');
EOSQL
    local rows_before; rows_before=$(q "$HOST" "SELECT count(*) FROM events;")

    local before; before=$("$COMPACTOR" --config /tmp/journey-archiver.yaml --table events --dry-run 2>&1)
    if echo "$before" | grep -q "group(s)"; then
        pass "compactor sees small cold files to compact"
    else
        fail "compactor --dry-run found nothing to compact: $before"; return
    fi

    if "$COMPACTOR" --config /tmp/journey-archiver.yaml --table events >/tmp/journey-compact.log 2>&1; then
        pass "compaction ran (bakery-serialized, no 409)"
    else
        fail "compaction failed — see /tmp/journey-compact.log"; tail -8 /tmp/journey-compact.log; return
    fi

    local after; after=$("$COMPACTOR" --config /tmp/journey-archiver.yaml --table events --dry-run 2>&1)
    if echo "$after" | grep -q "nothing to compact"; then
        pass "small files consolidated (none left below target)"
    else
        fail "files still below target after compaction: $after"
    fi
    assert_eq "compaction preserved all rows" "$rows_before" "$(q "$HOST" "SELECT count(*) FROM events;")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 6e — Maintenance: reclaim the snapshot + small-file bloat compaction leaves
# behind, via iceberg-go's ExpireSnapshots + DeleteOrphanFiles (cmd/compactor),
# bakery-serialized through the SAME claim cold writes take (coldfront._claim_iceberg_
# external; stock-ordering claimant, formally cleared in docs/formal). Lakekeeper is a
# catalog and does NOT do Iceberg snapshot/orphan maintenance — this is the go-native
# path. The chain is natural (no synthetic files): after 6d's compaction the pre-compaction
# snapshots still pin the superseded small files; --expire-keep-files drops those snapshots
# (metadata) but leaves their files, which the --orphans pass then reclaims. The compactor's
# own --dry-run is the oracle (snapshot count, orphan count), as in 6d.
# ───────────────────────────────────────────────────────────────────────────
story_maintenance() {
    step "6e. Maintenance: expire old snapshots + reclaim orphan files (iceberg-go, bakery-serialized)"
    require_compactor || return
    local rows_before; rows_before=$(q "$HOST" "SELECT count(*) FROM events;")

    local snaps; snaps=$("$COMPACTOR" --config /tmp/journey-archiver.yaml --table events --expire-snapshots --dry-run 2>&1)
    local nsnap; nsnap=$(echo "$snaps" | grep -oE '[0-9]+ snapshot' | head -1 | grep -oE '[0-9]+')
    if [ "${nsnap:-0}" -gt 1 ]; then
        pass "expire sees >1 snapshot (compaction + cold writes left $nsnap)"
    else
        fail "expire --dry-run shows nothing to expire: $snaps"; return
    fi

    # Expire metadata, KEEP files — leaves the superseded smalls as real orphans for --orphans.
    # --expire-older-than 0s: Iceberg expiry is age-driven, so expire all but the current
    # snapshot now (the freshly-created test snapshots are only seconds old).
    if "$COMPACTOR" --config /tmp/journey-archiver.yaml --table events \
         --expire-snapshots --expire-older-than 0s --expire-retain-last 1 --expire-keep-files >/tmp/journey-expire.log 2>&1; then
        pass "snapshots expired (bakery-serialized, no 409)"
    else
        fail "expire failed — see /tmp/journey-expire.log"; tail -8 /tmp/journey-expire.log; return
    fi

    local after; after=$("$COMPACTOR" --config /tmp/journey-archiver.yaml --table events --expire-snapshots --dry-run 2>&1)
    local nafter; nafter=$(echo "$after" | grep -oE '[0-9]+ snapshot' | head -1 | grep -oE '[0-9]+')
    if [ "${nafter:-0}" -eq 1 ]; then
        pass "expired down to the retain-last target (1 snapshot)"
    else
        fail "snapshot count not at retain target after expire: $after"
    fi

    # The files those expired snapshots alone pinned are now orphans (referenced by nothing).
    local orph; orph=$("$COMPACTOR" --config /tmp/journey-archiver.yaml --table events --orphans --orphan-age 0s --dry-run 2>&1)
    local norph; norph=$(echo "$orph" | grep -oE '[0-9]+ orphan' | head -1 | grep -oE '[0-9]+')
    if [ "${norph:-0}" -gt 0 ]; then
        pass "orphan scan finds the freed files ($norph; real backend, no prefix-mismatch)"
    else
        fail "no orphans detected after expire-keep-files: $orph"; return
    fi

    if "$COMPACTOR" --config /tmp/journey-archiver.yaml --table events --orphans --orphan-age 0s >/tmp/journey-orphans.log 2>&1; then
        pass "orphan files deleted (bakery-serialized)"
    else
        fail "orphan deletion failed — see /tmp/journey-orphans.log"; tail -8 /tmp/journey-orphans.log; return
    fi

    local orph2; orph2=$("$COMPACTOR" --config /tmp/journey-archiver.yaml --table events --orphans --orphan-age 0s --dry-run 2>&1)
    local norph2; norph2=$(echo "$orph2" | grep -oE '[0-9]+ orphan' | head -1 | grep -oE '[0-9]+')
    if [ "${norph2:-1}" -eq 0 ]; then
        pass "no orphans remain (reclaimed)"
    else
        fail "orphans remain after deletion: $orph2"
    fi

    assert_eq "maintenance preserved all rows" "$rows_before" "$(q "$HOST" "SELECT count(*) FROM events;")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 6c — Cold + dual-tier DML issued from INSIDE plpgsql (a DO block). This
# is the end-to-end test of BOTH fixes: plpgsql variable refs become $N bound
# params (Cause 1, kept live via format()), and the rewrite must be a DML-tagged
# statement plpgsql accepts rather than a bare SELECT (Cause 2, the
# coldfront._dummy_dml_target carrier — only used here, in the in-plpgsql case).
# RED before the fix (DuckDB param error, then "query has no destination"),
# GREEN after, on every backend+topology. Cold = m4 (< the start-of-now-1mo cutoff).
# ───────────────────────────────────────────────────────────────────────────
story_writes_plpgsql() {
    step "6c. Cold + dual-tier DML from inside plpgsql (DO block, bound params)"
    local O; O=$(qf "$HOST" <<'EOSQL'
INSERT INTO events (ts,status,data) VALUES
  (date_trunc('month',now()) - interval '4 months' + interval '21 days' + interval '4 hours','pp_upd_seed','{}'),(date_trunc('month',now()) - interval '4 months' + interval '22 days' + interval '4 hours','pp_del_seed','{}');
-- cold UPDATE from plpgsql: var in SET and WHERE
DO $$
DECLARE v_new text := 'pp_upd_done'; v_old text := 'pp_upd_seed';
BEGIN UPDATE events SET status = v_new WHERE status = v_old AND ts < date_trunc('month',now()) - interval '3 months'; END $$;
SELECT 'PP_UPD:' || count(*) FROM events WHERE status='pp_upd_done';
-- cold DELETE from plpgsql: var in WHERE
DO $$
DECLARE v_st text := 'pp_del_seed';
BEGIN DELETE FROM events WHERE status = v_st AND ts < date_trunc('month',now()) - interval '3 months'; END $$;
SELECT 'PP_DEL:' || count(*) FROM events WHERE status='pp_del_seed';
-- dual-tier UPDATE from plpgsql: ambiguous (status-only) predicate ⇒ dual CTE
-- (hot leg keeps native $N, cold leg goes through format()).
INSERT INTO events (ts,status,data) VALUES
  (date_trunc('month',now()) - interval '1 month' + interval '23 days' + interval '5 hours','pp_dual','{}'),(date_trunc('month',now()) - interval '4 months' + interval '23 days' + interval '5 hours','pp_dual','{}');
DO $$
DECLARE v_new text := 'pp_dual_done';
BEGIN UPDATE events SET status = v_new WHERE status = 'pp_dual'; END $$;
SELECT 'PP_DUAL_HOT:'   || count(*) FROM _events WHERE status='pp_dual_done';
SELECT 'PP_DUAL_TOTAL:' || count(*) FROM events  WHERE status='pp_dual_done';
-- cold INSERT from plpgsql: events.id is GENERATED ALWAYS AS IDENTITY, so the
-- INSERT must omit it → the slow tiered-INSERT loop (coldfront._tiered_insert_cold,
-- whose source SQL runs in a PG cursor). The jsonb var exercises the native-PG
-- arg rendering (not the DuckDB from_hex/::text used on the raw_query paths).
DO $$
DECLARE v_st text := 'pp_ins'; v_data jsonb := '{"k":9}';
BEGIN INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '24 days' + interval '6 hours', v_st, v_data); END $$;
SELECT 'PP_INS:' || count(*) FROM events WHERE status='pp_ins' AND ts < date_trunc('month',now()) - interval '3 months';
EOSQL
)
    assert_eq "plpgsql cold UPDATE (var SET+WHERE) hit the cold tier" "1" "$(extract PP_UPD "$O")"
    assert_eq "plpgsql cold DELETE (var WHERE) removed the cold row"  "0" "$(extract PP_DEL "$O")"
    assert_eq "plpgsql dual UPDATE updated the hot tier"              "1" "$(extract PP_DUAL_HOT "$O")"
    assert_eq "plpgsql dual UPDATE updated both tiers (hot+cold)"     "2" "$(extract PP_DUAL_TOTAL "$O")"
    assert_eq "plpgsql cold INSERT (IDENTITY-omit slow path, jsonb var)" "1" "$(extract PP_INS "$O")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 6b — Concurrency × mixed-tier: parallel dual-tier UPDATEs (each spanning
# hot + cold via an ambiguous predicate) all land with no 409. The dual CTE's
# cold leg is coldfront._exec_iceberg_with_claim (emit_dual), the same bakery as
# single cold writes — so concurrent mixed writers serialize on the cold commit
# (advisory lock in vanilla). Self-contained: seeds 4 groups, each 1 hot (Apr,
# still hot here) + 1 cold (Jan) row, then updates the 4 groups concurrently.
# Must run before the race-window story archives the last hot partition.
# ───────────────────────────────────────────────────────────────────────────
story_mixed_concurrency() {
    step "6b. Concurrency: parallel MIXED-tier writers (dual CTE via bakery, no 409)"
    qf "$HOST" <<'EOSQL' >/dev/null 2>&1
INSERT INTO events (ts,status,data) VALUES
 (date_trunc('month',now()) - interval '1 month' + interval '4 days','mixseed0','{}'),(date_trunc('month',now()) - interval '4 months' + interval '4 days','mixseed0','{}'),
 (date_trunc('month',now()) - interval '1 month' + interval '5 days','mixseed1','{}'),(date_trunc('month',now()) - interval '4 months' + interval '5 days','mixseed1','{}'),
 (date_trunc('month',now()) - interval '1 month' + interval '6 days','mixseed2','{}'),(date_trunc('month',now()) - interval '4 months' + interval '6 days','mixseed2','{}'),
 (date_trunc('month',now()) - interval '1 month' + interval '7 days','mixseed3','{}'),(date_trunc('month',now()) - interval '4 months' + interval '7 days','mixseed3','{}');
EOSQL
    local k pids=()
    rm -f /tmp/journey-mix.* 2>/dev/null
    for k in 0 1 2 3; do
        # status-only predicate ⇒ TIER_AMBIGUOUS ⇒ dual-tier CTE (hot UPDATE +
        # cold _exec_iceberg_with_claim). Disjoint groups ⇒ no hot-row lock
        # contention; the cold legs contend on the bakery and serialize.
        q "$HOST" "UPDATE events SET status='mixdone' WHERE status='mixseed${k}';" >/tmp/journey-mix.$k 2>&1 &
        pids+=("$!")
    done
    local p; for p in "${pids[@]}"; do wait "$p"; done
    assert_eq "no concurrent mixed-tier writer errored (no 409/abort)" "0" \
        "$(cat /tmp/journey-mix.* 2>/dev/null | grep -cEi 'error|conflict|409')"
    rm -f /tmp/journey-mix.* 2>/dev/null
    assert_eq "4 concurrent mixed-tier writers all landed (no 409/loss)" "8" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='mixdone';")"
    assert_eq "no mixseed rows left"                                     "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE status LIKE 'mixseed%';")"
    assert_eq "concurrent mixed write updated the cold tier (4 m4 rows)" "4" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='mixdone' AND ts < date_trunc('month',now()) - interval '3 months';")"
    assert_eq "concurrent mixed write updated the hot tier (4 m1 rows)"  "4" "$(q "$HOST" "SELECT count(*) FROM _events WHERE status='mixdone';")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 7 — Schema DDL. Column-shape changes (ADD/DROP/ALTER-TYPE/RENAME COLUMN)
# are MIRRORED onto the Iceberg cold tier and the transparent view is rebuilt;
# an unsupported column type is rejected up front. RENAME TABLE/VIEW touch only
# the PG side. Exercised on a scratch column so the table shape is restored for
# later stories. Each cross-tier read after a change only succeeds if the Iceberg
# schema actually followed it (else the rebuilt cold branch fails to resolve).
# ───────────────────────────────────────────────────────────────────────────
story_ddl() {
    step "7. Schema DDL mirrored to Iceberg (ADD/DROP/ALTER TYPE/RENAME COLUMN); rename table/view"
    local cutoff="date_trunc('month',now()) - interval '2 months'"   # m2 boundary

    # ADD COLUMN → mirrored; the cold UNION branch now projects it.
    q "$HOST" "ALTER TABLE _events ADD COLUMN cnt integer;" >/dev/null
    assert_gt "cold tier readable after ADD COLUMN (mirrored to Iceberg)" "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE ts < $cutoff;")"
    assert_eq "view exposes the added column" "cnt" "$(q "$HOST" "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='events' AND column_name='cnt';")"
    assert_eq "added column is NULL on historical cold rows" "" "$(q "$HOST" "SELECT cnt FROM events WHERE ts < $cutoff ORDER BY ts LIMIT 1;")"

    # ALTER COLUMN TYPE → mirrored safe promotion (INTEGER -> BIGINT).
    q "$HOST" "ALTER TABLE _events ALTER COLUMN cnt TYPE bigint;" >/dev/null
    assert_gt "cold tier readable after ALTER COLUMN TYPE" "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE ts < $cutoff;")"

    # RENAME COLUMN → Iceberg column renamed too, or the rebuilt cold branch
    # (r['ctr']) could not resolve against the old Iceberg name.
    q "$HOST" "ALTER TABLE _events RENAME COLUMN cnt TO ctr;" >/dev/null
    assert_gt "cold tier readable after RENAME COLUMN (Iceberg col renamed)" "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE ts < $cutoff;")"
    assert_eq "renamed column visible on the view" "ctr" "$(q "$HOST" "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='events' AND column_name='ctr';")"

    # DROP COLUMN → mirrored; restores the original shape for later stories.
    q "$HOST" "ALTER TABLE _events DROP COLUMN ctr;" >/dev/null
    assert_eq "scratch column dropped from the view" "0" "$(q "$HOST" "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='events' AND column_name IN ('cnt','ctr');")"
    assert_gt "cold tier readable after DROP COLUMN" "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE ts < $cutoff;")"

    # Data-type correspondence is enforced: an unsupported type is rejected up front.
    assert_err "ADD COLUMN inet rejected (no Iceberg mapping)" "no Iceberg-compatible mapping" "$(q_may "$HOST" "ALTER TABLE _events ADD COLUMN ip inet;")"

    # RENAME VIEW is supported and must migrate the watermark so the cold branch survives.
    q "$HOST" "ALTER VIEW events RENAME TO events_v2;" >/dev/null
    assert_gt "cold tier survives view rename" "0" "$(q "$HOST" "SELECT count(*) FROM events_v2 WHERE ts < $cutoff;")"
    q "$HOST" "ALTER VIEW events_v2 RENAME TO events;" >/dev/null
    pass "view renamed back to events"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 8 — Blocked operations.
# ───────────────────────────────────────────────────────────────────────────
story_blocks() {
    step "8. DROP/TRUNCATE on a tiered relation are blocked"
    assert_err "DROP TABLE blocked"  "cold tier" "$(q_may "$HOST" "DROP TABLE _events;")"
    assert_err "DROP VIEW blocked"   "cold tier" "$(q_may "$HOST" "DROP VIEW events;")"
    assert_err "TRUNCATE blocked"    "cold-tier" "$(q_may "$HOST" "TRUNCATE _events;")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — Extension dependency. coldfront.control declares
# requires = 'pg_duckdb', so on a database without pg_duckdb, CREATE EXTENSION
# coldfront is rejected up front ("required extension ... is not installed")
# instead of failing later at runtime with schema "duckdb" not existing. Use a
# throwaway database and drop pg_duckdb to guarantee its absence regardless of
# what template1 carries.
# ───────────────────────────────────────────────────────────────────────────
story_ext_requires() {
    step "Extension dependency: CREATE EXTENSION coldfront without pg_duckdb is rejected"
    q "$HOST" "DROP DATABASE IF EXISTS cf_dep_check;"
    q "$HOST" "CREATE DATABASE cf_dep_check;"
    docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE=cf_dep_check "$HOST" "$CF_PSQL" -tA \
        -c "DROP EXTENSION IF EXISTS pg_duckdb CASCADE;" >/dev/null 2>&1 || true
    assert_err "missing pg_duckdb rejected at CREATE EXTENSION" "required extension" \
        "$(docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE=cf_dep_check "$HOST" "$CF_PSQL" -tA \
            -c "CREATE EXTENSION coldfront;" 2>&1 || true)"
    q "$HOST" "DROP DATABASE cf_dep_check;"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — Packaging: load the bundled .duckdb_extension files from a custom
# duckdb.extension_directory. The Docker image places them under the DEFAULT
# dir ($PGDATA/pg_duckdb/extensions); an RPM/DEB can't write PGDATA, so it
# installs them under <dir>/<ver>/<platform>/ and points the GUC at <dir>.
# This proves pg_duckdb honours that GUC (so the packaging path is supported),
# with an empty-dir negative control so it can't pass via the default dir.
# ───────────────────────────────────────────────────────────────────────────
story_ext_directory_guc() {
    step "Packaging: pg_duckdb loads extensions from a custom duckdb.extension_directory"
    # duckdb.extension_directory is read at server start, so this applies it via a
    # restart. Skip in mesh, where a mid-journey node restart would churn spock;
    # the GUC behaviour is mode-independent, so the single-node run covers it.
    if [ "$MESH" = 1 ]; then pass "extension_directory check skipped in mesh (single-node)"; return; fi
    # Build the package-style layout in a writable, restart-persistent place
    # (under the data dir, postgres-owned) by cloning the working default
    # extension tree — it already has the correct <version>/<platform> subdirs.
    # cfpkg = populated (the "package installed it here" case), cfpkg-empty =
    # negative control.
    local pgdata
    pgdata="$(q "$HOST" "SHOW data_directory;" | tail -1)"
    docker exec "$HOST" bash -c "rm -rf '$pgdata/cfpkg' '$pgdata/cfpkg-empty'; cp -a '$pgdata/pg_duckdb/extensions' '$pgdata/cfpkg'; mkdir -p '$pgdata/cfpkg-empty'"

    _cf_wait_pg() {
        local i=0
        until docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "$HOST" "$CF_PSQL" -tAc 'SELECT 1' >/dev/null 2>&1; do
            i=$((i + 1)); [ "$i" -gt 60 ] && { fail "postgres did not come back after restart"; return 1; }; sleep 1
        done
    }

    # Disable autoinstall: with it on, an empty dir is masked by DuckDB
    # downloading the (unpatched) upstream extension. A package must ship our
    # patched files and not silently fetch upstream, so the test mirrors that.
    q "$HOST" "ALTER SYSTEM SET duckdb.autoinstall_known_extensions = false;"
    # Negative control: empty package dir -> LOAD iceberg must FAIL, proving the
    # GUC actually redirects (the default dir is not used as a fallback).
    q "$HOST" "ALTER SYSTEM SET duckdb.extension_directory = '$pgdata/cfpkg-empty';"
    docker restart "$HOST" >/dev/null; _cf_wait_pg || return
    case "$(q_may "$HOST" "SELECT duckdb.raw_query('LOAD iceberg');")" in
        *Success*) fail "empty extension_directory: LOAD iceberg unexpectedly succeeded" ;;
        *)         pass "empty extension_directory: LOAD iceberg fails (GUC redirects; no autoinstall)" ;;
    esac

    # Positive: populated package dir -> LOAD iceberg must succeed.
    q "$HOST" "ALTER SYSTEM SET duckdb.extension_directory = '$pgdata/cfpkg';"
    docker restart "$HOST" >/dev/null; _cf_wait_pg || return
    local out; out="$(q_may "$HOST" "SELECT duckdb.raw_query('LOAD iceberg');")"
    case "$out" in
        *Success*) pass "populated extension_directory: LOAD iceberg succeeds" ;;
        *)         fail "populated extension_directory: LOAD iceberg did not succeed — $out" ;;
    esac

    # Restore image defaults so later stories load from $PGDATA as usual.
    q "$HOST" "ALTER SYSTEM RESET duckdb.extension_directory;"
    q "$HOST" "ALTER SYSTEM RESET duckdb.autoinstall_known_extensions;"
    docker restart "$HOST" >/dev/null; _cf_wait_pg || return
}

# ───────────────────────────────────────────────────────────────────────────
# Story 9 — Concurrency / no-409: writes that race the archive cycle survive.
# The m1 (now-1mo) partition is still hot after the first cycle (cutoff = start
# of now-1mo). A second cycle with the cutoff pinned PAST the start of the
# current month expires it; --debug-export-delay
# holds the capture window open while concurrent UPDATE/DELETE/INSERT race into
# the delta trigger, which the cold replay must apply. (Ported from
# run-ci-local.sh step 8b — the one E2E behaviour the journey didn't yet cover.)
# ───────────────────────────────────────────────────────────────────────────
story_concurrency() {
    step "9. Race window: writes during the archive cycle survive into cold"
    qf "$HOST" <<'EOSQL' >/dev/null
INSERT INTO events (ts, status, data) VALUES
  (date_trunc('month',now()) - interval '1 month' + interval '14 days' + interval '12 hours','race_seed_a','{}'),
  (date_trunc('month',now()) - interval '1 month' + interval '15 days' + interval '12 hours','race_seed_b','{}'),
  (date_trunc('month',now()) - interval '1 month' + interval '16 days' + interval '12 hours','race_seed_c','{}'),
  (date_trunc('month',now()) - interval '1 month' + interval '17 days' + interval '12 hours','race_will_delete','{}');
EOSQL
    # Pin the race cutoff PAST the start of the current month (target = start of
    # now + 14 days) so the m1 partition — the last hot one — is expired by this
    # cycle, deterministically.
    local ret_race=$(( ( $(date -u +%s) - $(date -u -d "$(date -u +%Y-%m-01) +14 days" +%s) ) / 86400 ))
    cat > /tmp/journey-race.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog" }
$(storage_yaml)
archiver: { tables: [ { source_table: events, partition_period: monthly, hot_period: "${ret_race} days" } ] }
EOF
    # Widen events' hot window for this run so m1 expires now; restore it after
    # the run (one shared partition_config row) so later stories keep events' config.
    local prev_hot; prev_hot=$(q "$HOST" "SELECT hot_period::text FROM coldfront.partition_config WHERE schema_name='public' AND table_name='events';")
    if ! "$ARCHIVER" set --config /tmp/journey-race.yaml --table events --hot-period "${ret_race} days" >/tmp/journey-race.log 2>&1; then
        fail "set race hot-period on events — see /tmp/journey-race.log"; tail -5 /tmp/journey-race.log; return
    fi
    "$ARCHIVER" --config /tmp/journey-race.yaml --debug-export-delay 4s >>/tmp/journey-race.log 2>&1 &
    local apid=$!
    local i
    for i in $(seq 1 30); do
        grep -q "debug-export-delay" /tmp/journey-race.log 2>/dev/null && break
        sleep 1
    done
    # Concurrent writes land in the capture window: UPDATE 3 seeds, DELETE 1,
    # INSERT 1 new — all must propagate to the cold tier via delta replay.
    qf "$HOST" <<'EOSQL' >/dev/null 2>&1
UPDATE events SET status='during_archive' WHERE status IN ('race_seed_a','race_seed_b','race_seed_c');
DELETE FROM events WHERE status='race_will_delete';
INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) - interval '1 month' + interval '18 days' + interval '12 hours','during_archive_insert','{}');
EOSQL
    if wait "$apid"; then pass "archiver cycle 2 completed cleanly (no 409)"
    else fail "archiver errored during race window"; tail -5 /tmp/journey-race.log; fi
    # Restore events' hot_period (shared partition_config row) so later stories see
    # its original config; a failed restore would corrupt them, so fail loud.
    "$ARCHIVER" set --config /tmp/journey-race.yaml --table events --hot-period "$prev_hot" >/dev/null 2>&1 \
        || fail "restore events hot_period after race window"
    assert_eq "race UPDATEs survived (3 retagged in cold)" "3" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='during_archive';")"
    assert_eq "race INSERT survived (1 new in cold)"       "1" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='during_archive_insert';")"
    assert_eq "race DELETE survived (0 remaining)"         "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='race_will_delete';")"
    assert_eq "no rows left in original race_seed status"  "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE status IN ('race_seed_a','race_seed_b','race_seed_c');")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 9b — Concurrency / no-409 (tiered): parallel COLD writers to one table
# all land. By this point every partition is archived (cutoff past the start of
# the current month), so below-cutoff INSERTs route through the cold path
# (_tiered_insert_cold) and the same advisory-lock bakery serializes them.
# Parity with the decoupled
# probe — the standing multi-writer no-409 rule applies to both modes.
# ───────────────────────────────────────────────────────────────────────────
story_concurrent_writers() {
    step "9b. Concurrency: parallel tiered COLD writers serialize via the bakery (no 409)"
    local k pids=()
    rm -f /tmp/journey-tconc.* 2>/dev/null
    for k in 1 2 3 4 5 6 7 8; do
        q "$HOST" "INSERT INTO events (ts,status,data) VALUES (date_trunc('month',now()) - interval '1 month' + interval '$((19+k)) days' + interval '9 hours','tconc','{}');" >/tmp/journey-tconc.$k 2>&1 &
        pids+=("$!")
    done
    local p; for p in "${pids[@]}"; do wait "$p"; done
    assert_eq "no concurrent tiered COLD writer errored (no 409/abort)" "0" \
        "$(cat /tmp/journey-tconc.* 2>/dev/null | grep -cEi 'error|conflict|409')"
    assert_eq "8 concurrent tiered COLD writers all landed (no 409/loss)" "8" \
        "$(q "$HOST" "SELECT count(*) FROM events WHERE status='tconc';")"
    rm -f /tmp/journey-tconc.* 2>/dev/null
}

# ───────────────────────────────────────────────────────────────────────────
# Story 10 — Transactions: rollback undoes both tiers; archiver idempotent.
# ───────────────────────────────────────────────────────────────────────────
story_txn() {
    step "10. Rollback undoes both tiers; archiver idempotent"
    local O; O=$(qf "$HOST" <<'EOSQL'
BEGIN;
UPDATE events SET status='rollback_me' WHERE status='dual_upd';
ROLLBACK;
SELECT 'RB_TOTAL:' || count(*) FROM events WHERE status='rollback_me';
EOSQL
)
    assert_eq "rollback undoes hot+cold" "0" "$(extract RB_TOTAL "$O")"
    if "$ARCHIVER" --config /tmp/journey-archiver.yaml >/tmp/journey-idem.log 2>&1; then
        assert_contains "archiver idempotent (re-run no-op)" "nothing to tier or expire" "$(cat /tmp/journey-idem.log)"
    else
        fail "archiver idempotent re-run errored"
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Story 11 — Coexistence: a second tiered table, no cross-talk.
# ───────────────────────────────────────────────────────────────────────────
story_coexist() {
    step "11. Multiple tiered tables coexist (no cross-talk)"
    assert_gt "registry holds multiple tiered views (events + typed)" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.tiered_views;")"
    # Both are independently queryable across their tiers.
    assert_gt "events readable (hot+cold)" "0" "$(q "$HOST" "SELECT count(*) FROM events;")"
    assert_gt "typed readable (hot+cold)"  "0" "$(q "$HOST" "SELECT count(*) FROM typed;")"
    # A cold write to events must NOT touch typed, and must land only in events.
    local typed_before; typed_before=$(q "$HOST" "SELECT count(*) FROM typed;")
    q "$HOST" "INSERT INTO events (ts,status,data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '8 days','coexist_probe','{}');" >/dev/null 2>&1
    assert_eq "write to events left typed unchanged (no cross-talk)" "$typed_before" "$(q "$HOST" "SELECT count(*) FROM typed;")"
    assert_eq "the events write landed in events"                    "1"             "$(q "$HOST" "SELECT count(*) FROM events WHERE status='coexist_probe';")"
    q "$HOST" "DELETE FROM events WHERE status='coexist_probe';" >/dev/null 2>&1
}

# Story 12 — mesh-only; built when the mesh cell is wired.
# ───────────────────────────────────────────────────────────────────────────
# Story 12 — Mesh-only (decoupled): cross-node visibility + the R-A bakery under
# real multi-node contention. Runs against the iceberg-only `iceonly` table the
# decoupled stories created on db1. The wrapper VIEW replicates to peers via
# Spock DDL; the decoupled topo does not add coldfront.tiered_views to the repset
# (that is tiered-only), so we re-register on each peer (create_iceberg_table is
# idempotent, and the registry is name-keyed so every node's row is identical) to
# arm the C hook there. Cold data itself is shared via Lakekeeper, not Spock.
# ───────────────────────────────────────────────────────────────────────────
story_mesh() {
    step "12. Mesh: cross-node visibility + R-A bakery (decoupled, multi-node)"
    if [ "$MODE" != "decoupled" ]; then
        note "story_mesh is the decoupled cross-node story; tiered cross-node is covered by story_mesh_tiered (ran earlier)"; return
    fi
    local PARR; read -ra PARR <<< "$PEERS"
    [ "${#PARR[@]}" -ge 1 ] || { fail "mesh: no --peers given"; return; }

    # Re-register the iceberg-only view on each peer (local registry row).
    local pc
    for pc in "${PARR[@]}"; do
        q_may "$pc" "SELECT coldfront.create_iceberg_table('public','iceonly','[{\"name\":\"id\",\"type\":\"bigint\"},{\"name\":\"ts\",\"type\":\"timestamptz\"},{\"name\":\"status\",\"type\":\"text\"},{\"name\":\"data\",\"type\":\"jsonb\"}]'::jsonb);" >/dev/null 2>&1
        assert_eq "iceberg-only registered on peer $pc" "1" "$(q "$pc" "SELECT count(*) FROM coldfront.tiered_views WHERE is_iceberg_only AND iceberg_table='ice.public.iceonly';")"
    done

    # Cross-node READ: every row db1 wrote to Iceberg is visible on each peer via
    # the shared Lakekeeper catalog (no Spock involved on the cold path).
    local d1; d1=$(q "$HOST" "SELECT count(*) FROM iceonly;")
    for pc in "${PARR[@]}"; do
        assert_eq "peer $pc sees db1's iceberg rows via shared Lakekeeper" "$d1" "$(q "$pc" "SELECT count(*) FROM iceonly;")"
    done

    # Cross-node WRITE: a write on a peer is visible on db1 (shared catalog).
    local p1="${PARR[0]}"
    q "$p1" "INSERT INTO iceonly VALUES (5001,date_trunc('month',now()) + interval '2 months' + interval '10 hours','from_peer','{}');" >/dev/null 2>&1
    assert_eq "write from peer $p1 visible on db1" "1" "$(q "$HOST" "SELECT count(*) FROM iceonly WHERE status='from_peer';")"

    # R-A bakery under multi-node contention: concurrent cold writers on db1 AND
    # a peer to the SAME Iceberg table must both land. Here v_armed is true
    # (snowflake.node + dblink_self set), so this exercises the Ricart-Agrawala
    # claim protocol across nodes — not the local advisory lock — to avoid 409.
    rm -f /tmp/journey-ra.* 2>/dev/null
    q "$HOST" "INSERT INTO iceonly VALUES (6001,date_trunc('month',now()) + interval '2 months' + interval '1 days' + interval '10 hours 0 minutes 0 seconds','ra','{}');" >/tmp/journey-ra.1 2>&1 &
    q "$p1"   "INSERT INTO iceonly VALUES (6002,date_trunc('month',now()) + interval '2 months' + interval '1 days' + interval '10 hours 0 minutes 1 seconds','ra','{}');" >/tmp/journey-ra.2 2>&1 &
    wait
    assert_eq "no cross-node cold writer errored (R-A bakery, no 409)" "0" \
        "$(cat /tmp/journey-ra.* 2>/dev/null | grep -cEi 'error|conflict|409')"
    assert_eq "concurrent cross-node cold writers both landed (R-A bakery, no 409)" "2" "$(q "$HOST" "SELECT count(*) FROM iceonly WHERE status='ra';")"
    rm -f /tmp/journey-ra.* 2>/dev/null
}

# ───────────────────────────────────────────────────────────────────────────
# Story 12b — MULTIPLE concurrent cold writers PER NODE, on >=2 nodes, to the
# SAME iceberg table. Unlike story_mesh (1 writer/node), this leaves >1
# same-node claim outstanding per node at once; the node-local advisory lock in
# _claim_iceberg_lock serializes them so the cross-node bakery sees one claim
# per node and no commit hits a Lakekeeper 409.
# ───────────────────────────────────────────────────────────────────────────
story_mesh_multiwriter() {
    step "12b. Mesh: multiple cold writers PER NODE, cross-node, same table"
    local PARR; read -ra PARR <<< "$PEERS"
    [ "${#PARR[@]}" -ge 1 ] || { fail "mesh: no --peers given"; return; }
    local p1="${PARR[0]}" N=5 k pids=() tbl
    [ "$MODE" = tiered ] && tbl=events || tbl=iceonly
    rm -f /tmp/journey-mw.* 2>/dev/null
    # Fire N writers on db1 AND N on the peer, all at once, all cold-routed to the
    # same table: decoupled writes straight to iceonly, tiered writes a cold-dated
    # row to events (ts before the cutoff, so it lands in the cold tier).
    for k in $(seq 1 "$N"); do
        local a b
        if [ "$MODE" = tiered ]; then
            a="INSERT INTO events (ts,status,data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '$k days','mw','{}');"
            b="INSERT INTO events (ts,status,data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '$k days 12 hours','mw','{}');"
        else
            a="INSERT INTO iceonly VALUES ($((7000+k)),date_trunc('month',now()) + interval '3 months' + interval '$k hours','mw','{}');"
            b="INSERT INTO iceonly VALUES ($((8000+k)),date_trunc('month',now()) + interval '3 months' + interval '$k hours 30 minutes','mw','{}');"
        fi
        q "$HOST" "$a" >"/tmp/journey-mw.a$k" 2>&1 &
        pids+=("$!")
        q "$p1"   "$b" >"/tmp/journey-mw.b$k" 2>&1 &
        pids+=("$!")
    done
    for k in "${pids[@]}"; do wait "$k"; done
    assert_eq "no multi-writer-per-node cross-node cold writer errored (no 409)" "0" \
        "$(cat /tmp/journey-mw.* 2>/dev/null | grep -cEi 'error|conflict|409')"
    assert_eq "all $((2 * N)) multi-writer-per-node cross-node cold writes landed" "$((2 * N))" \
        "$(q "$HOST" "SELECT count(*) FROM $tbl WHERE status='mw';")"
    rm -f /tmp/journey-mw.* 2>/dev/null
}

# ───────────────────────────────────────────────────────────────────────────
# Story (mesh + tiered) — cross-node tiered: a tiered table provisioned on db1
# is readable AND writable from peers. Hot rows arrive via Spock replication of
# the _events partitions; cold rows via the shared Lakekeeper catalog; the
# coldfront.tiered_views registry + archive_watermark are replicated via the
# Spock repset. Both are name-keyed (schema_name,relname / table_name), so each
# row is copied verbatim and correct on every node, which arms the C hook to
# recognise the view and route writes on peers. Runs right after
# provision while hot+cold coexist; its one cross-node write is cleaned up so
# the stories that follow still see the post-provision baseline.
# ───────────────────────────────────────────────────────────────────────────
story_mesh_tiered() {
    step "2c. Mesh: cross-node tiered (hot via Spock + cold via shared Lakekeeper)"
    local PARR; read -ra PARR <<< "$PEERS"
    [ "${#PARR[@]}" -ge 1 ] || { fail "mesh: no --peers given"; return; }
    local total; total=$(q "$HOST" "SELECT count(*) FROM events;")
    local pc
    for pc in "${PARR[@]}"; do
        # Registry present on the peer. The registry is name-keyed
        # (schema_name, relname), so the repset replicates the row verbatim and
        # it is correct on every node (a name is node-independent — no per-node
        # OID resolution). That is what arms the C hook for cross-node
        # UPDATE/DELETE + DDL-blocking on the peer.
        assert_eq "tiered registry present on $pc (name-keyed)" "1" \
            "$(q "$pc" "SELECT count(*) FROM coldfront.tiered_views WHERE schema_name = 'public' AND relname = 'events' AND NOT is_iceberg_only;")"
        # Cross-node READ: peer sees the same hot+cold total as db1.
        assert_eq "$pc reads same hot+cold total as db1" "$total" "$(q "$pc" "SELECT count(*) FROM events;")"
        # Hot rows present on the peer via Spock-replicated _events partitions.
        assert_gt "$pc sees hot rows via Spock" "0" "$(q "$pc" "SELECT count(*) FROM _events;")"
    done
    # Cross-node WRITE: a cold-dated INSERT on a peer routes through its hook to
    # the shared Iceberg table (R-A bakery) and is visible on db1. Then clean it
    # up so the row count returns to baseline for the stories that follow.
    local p1="${PARR[0]}"
    q "$p1" "INSERT INTO events (ts,status,data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '24 days' + interval '9 hours','xnode_cold','{}');" >/dev/null 2>&1
    assert_eq "cold write from peer $p1 visible on db1 (shared Lakekeeper)" "1" \
        "$(q "$HOST" "SELECT count(*) FROM events WHERE status='xnode_cold';")"
    q "$HOST" "DELETE FROM events WHERE status='xnode_cold';" >/dev/null 2>&1
    assert_eq "cross-node row cleaned up (post-provision baseline restored)" "$total" "$(q "$HOST" "SELECT count(*) FROM events;")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 13 — Standby reads: a read-only physical replica serves cross-tier reads
# (hot via physical replication, cold via iceberg_scan executed on the read-only
# backend) and rejects writes cleanly. The coldfront catalog (registry,
# watermark, storage-secret row) arrives through the base
# backup + WAL stream, so the replica is byte-identical to the primary (same
# OIDs) with zero extra setup. Gated by --standby <container>; the topology
# base-backed it before the journey, so it has streamed every story by now.
# Verified-safe: ci/probe-standby.sh is the standalone gate for this surface.
# ───────────────────────────────────────────────────────────────────────────
story_standby_reads() {
    step "13. Standby reads (read-only physical replica: $STANDBY)"
    assert_eq "standby is read-only (in recovery)" "t" "$(q "$STANDBY" "SELECT pg_is_in_recovery();")"

    # Wait until the replica has replayed up to the primary's current WAL
    # position so the read comparisons reflect the same committed state
    # (streaming replication is asynchronous).
    local tgt caught=0 i d
    tgt=$(q "$HOST" "SELECT pg_current_wal_lsn();")
    for i in $(seq 1 30); do
        d=$(q "$STANDBY" "SELECT pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '$tgt')::bigint;")
        if [ -n "$d" ] && [ "$d" -ge 0 ] 2>/dev/null; then caught=1; break; fi
        sleep 1
    done
    assert_eq "standby caught up to primary's WAL position" "1" "$caught"

    # Coldfront catalog arrived via physical replication — same content, same OIDs.
    # Pin the journey's primary view (tiered: events / decoupled: iceonly), NOT
    # LIMIT 1 — story_coexist adds a second registry row (typed) with a different
    # column shape, which must not be what the write probe below targets.
    local vn; [ "$MODE" = tiered ] && vn="public.events" || vn="public.iceonly"
    assert_eq "tiered_views registry replicated" "$(q "$HOST" "SELECT count(*) FROM coldfront.tiered_views;")" "$(q "$STANDBY" "SELECT count(*) FROM coldfront.tiered_views;")"
    assert_eq "storage_secret row replicated (physical)" "1" "$(q "$STANDBY" "SELECT count(*) FROM coldfront.storage_secret;")"
    assert_eq "registered view OID identical (physical replication)" \
        "$(q "$HOST" "SELECT '$vn'::regclass::oid;")" "$(q "$STANDBY" "SELECT '$vn'::regclass::oid;")"

    # The persistent-secret FILE lives outside PGDATA, so it does not ride the
    # base backup — materialize it on the replica from the (physically
    # replicated) storage_secret row. SELECT + a DuckDB file write, no PG write,
    # so it's allowed on a read-only standby.
    q "$STANDBY" "SELECT coldfront.materialize_storage_secret();" >/dev/null 2>&1

    # Reads MATCH the primary across tiers. The extension hook attaches 'ice'
    # lazily on the first tiered-view query in this read-only session;
    # iceberg_scan then executes read-only on the replica.
    assert_eq "standby cross-tier read == primary" "$(q "$HOST" "SELECT count(*) FROM $vn;")" "$(q "$STANDBY" "SELECT count(*) FROM $vn;")"
    assert_eq "standby cold-side read (iceberg_scan on replica) == primary" \
        "$(q "$HOST" "SELECT count(*) FROM $vn WHERE ts < date_trunc('month',now()) - interval '1 month';")" \
        "$(q "$STANDBY" "SELECT count(*) FROM $vn WHERE ts < date_trunc('month',now()) - interval '1 month';")"

    # tiered only: the watermark drives the hot/cold cutoff; it must replicate too.
    [ "$MODE" = tiered ] && assert_eq "archive_watermark replicated" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.archive_watermark;")" "$(q "$STANDBY" "SELECT count(*) FROM coldfront.archive_watermark;")"

    # A write through the view fails CLEANLY, not a coldfront crash. Use a COLD-
    # dated row so it routes through coldfront's cold chokepoint
    # (_exec_iceberg_with_claim) on BOTH modes, exercising the standby guard there
    # — a hot write would be rejected by PG natively, never reaching coldfront.
    local w; w=$(q_may "$STANDBY" "INSERT INTO $vn (ts,status,data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '19 days','x','{}'::jsonb);")
    assert_err "cold write through view on standby → clean read-only rejection" "read-only" "$w"

    # Mesh + tiered: the standby is a physical replica of db1 (HOST). A peer's HOT
    # write reaches db1 via Spock (logical) and then the standby via physical
    # replication — the property unique to a mesh-node read replica. Scoped to
    # tiered deliberately: decoupled has no PG data path (all rows live in shared
    # Lakekeeper, which the standby reads directly — already covered by the
    # cold-side read assertion above), and an Iceberg targeted-column INSERT is
    # unsupported, so there is no hot-tier peer write to route here anyway.
    if [ "$MESH" = 1 ] && [ "$MODE" = tiered ] && [ -n "${PEERS:-}" ]; then
        local PARR peer seen=0; read -ra PARR <<< "$PEERS"; peer="${PARR[0]}"
        q "$peer" "INSERT INTO $vn (ts,status,data) VALUES (date_trunc('month',now()) - interval '1 month' + interval '21 days' + interval '8 hours','sb_xnode','{}'::jsonb);" >/dev/null 2>&1
        for _ in $(seq 1 30); do
            [ "$(q "$STANDBY" "SELECT count(*) FROM $vn WHERE status='sb_xnode';")" = 1 ] && { seen=1; break; }
            sleep 1
        done
        assert_eq "mesh: standby of db1 sees peer-originated hot row (origin $peer, via Spock→physical)" "1" "$seen"
        q "$HOST" "DELETE FROM $vn WHERE status='sb_xnode';" >/dev/null 2>&1
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Story 1b — Mesh-only: the bakery substrate (coldfront.claims) must replicate
# in all N×(N-1) directions, or the R-A bakery can't serialise cross-node
# commits. story_mesh exercises only the two writers' directions; this probes
# the full mesh per the standing multi-writer rule — a sentinel claim on every
# node, read back from every node — then verifies the cleanup replicates too so
# no stale claim lingers. Mode-agnostic: claims/claim_acks are bakery substrate,
# armed by the topology on every node before the journey runs.
# ───────────────────────────────────────────────────────────────────────────
story_mesh_substrate() {
    step "1b. Mesh: bakery substrate (coldfront.claims) replicates in all directions"
    local PARR; read -ra PARR <<< "$PEERS"
    [ "${#PARR[@]}" -ge 1 ] || { fail "mesh: no --peers given"; return; }
    local nodes=("$HOST" "${PARR[@]}") want="$(( ${#PARR[@]} + 1 ))" n t=90
    q "$HOST" "DELETE FROM coldfront.claims WHERE iceberg_table='bakery_probe';" >/dev/null 2>&1
    for n in "${nodes[@]}"; do
        t=$((t + 1))
        q "$n" "INSERT INTO coldfront.claims (iceberg_table, ticket) VALUES ('bakery_probe', $t);" >/dev/null 2>&1
    done
    sleep 3
    for n in "${nodes[@]}"; do
        assert_eq "claims: $n sees all $want sentinels (every direction)" "$want" \
            "$(q "$n" "SELECT count(*) FROM coldfront.claims WHERE iceberg_table='bakery_probe';")"
    done
    q "$HOST" "DELETE FROM coldfront.claims WHERE iceberg_table='bakery_probe';" >/dev/null 2>&1
    sleep 2
    local stale=0
    for n in "${nodes[@]}"; do
        [ "$(q "$n" "SELECT count(*) FROM coldfront.claims WHERE iceberg_table='bakery_probe';")" = "0" ] || stale=$((stale + 1))
    done
    assert_eq "claims sentinels cleared on all nodes (release replicates)" "0" "$stale"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — mesh: coldfront.partition_config replicates by value in all directions.
# This is the auto-sync that motivates config-as-data: register on any node and
# every peer reads the same lifecycle. N×(N-1) probe — a sentinel row per node,
# seen everywhere; then cleared. Sentinels point at no real table (schema
# 'cfprobe') and are removed here, so no reconcile ever processes them.
# ───────────────────────────────────────────────────────────────────────────
story_mesh_partition_config() {
    step "1c. Mesh: coldfront.partition_config replicates in all directions"
    local PARR; read -ra PARR <<< "$PEERS"
    [ "${#PARR[@]}" -ge 1 ] || { fail "mesh: no --peers given"; return; }
    local nodes=("$HOST" "${PARR[@]}") want="$(( ${#PARR[@]} + 1 ))" n i=0
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE schema_name='cfprobe';" >/dev/null 2>&1
    sleep 2
    for n in "${nodes[@]}"; do
        i=$((i + 1))
        q "$n" "INSERT INTO coldfront.partition_config (schema_name, table_name, partition_period, retention_period) VALUES ('cfprobe', 'n${i}', 'monthly', '1 day');" >/dev/null 2>&1
    done
    sleep 3
    for n in "${nodes[@]}"; do
        assert_eq "partition_config: $n sees all $want rows (every direction)" "$want" \
            "$(q "$n" "SELECT count(*) FROM coldfront.partition_config WHERE schema_name='cfprobe';")"
    done
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE schema_name='cfprobe';" >/dev/null 2>&1
    sleep 2
    local stale=0
    for n in "${nodes[@]}"; do
        [ "$(q "$n" "SELECT count(*) FROM coldfront.partition_config WHERE schema_name='cfprobe';")" = "0" ] || stale=$((stale + 1))
    done
    assert_eq "partition_config sentinels cleared on all nodes (delete replicates)" "0" "$stale"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — mesh: the partitioner's STRUCTURAL partition DDL replicates in every
# direction. partition_config is data (probed above by value); the partition
# lifecycle is DDL — Spock must carry it via spock.enable_ddl_replication, or the
# partitioned shape diverges across nodes and cross-node reads/writes break.
# Verify-before-bench: exercise the EXACT three shapes the manager emits
# (internal/partition/partition.go) and assert each lands on every node:
#   CREATE TABLE … PARTITION OF … FOR VALUES FROM … TO …   (:167, premake)
#   ALTER TABLE … DETACH PARTITION … CONCURRENTLY          (:227, expire — the
#       risky one: runs top-level, NOT in a txn)
#   DROP TABLE IF EXISTS …                                 (:238, expire/drop)
# Children are parent-prefixed (mddlprobe_pN), so no flat-name collision; the
# parent lives in public (present on every node) so no CREATE SCHEMA confounder.
# ───────────────────────────────────────────────────────────────────────────
story_mesh_partition_ddl() {
    step "1d. Mesh: partition lifecycle DDL (CREATE / DETACH CONCURRENTLY / DROP) replicates in all directions"
    local PARR; read -ra PARR <<< "$PEERS"
    [ "${#PARR[@]}" -ge 1 ] || { fail "mesh: no --peers given"; return; }
    local nodes=("$HOST" "${PARR[@]}") want="$(( ${#PARR[@]} + 1 ))" n i=0

    # Fresh RANGE(id) parent on HOST; the partitioned parent itself must replicate.
    q "$HOST" "DROP TABLE IF EXISTS public.mddlprobe CASCADE; CREATE TABLE public.mddlprobe (id bigint NOT NULL, PRIMARY KEY (id)) PARTITION BY RANGE (id);" >/dev/null 2>&1
    sleep 3
    local pmiss=0
    for n in "${nodes[@]}"; do
        [ "$(q "$n" "SELECT count(*) FROM pg_class WHERE relname='mddlprobe' AND relkind='p';")" = "1" ] || pmiss=$((pmiss + 1))
    done
    assert_eq "parent partitioned table replicated to all $want nodes" "0" "$pmiss"

    # (a) CREATE PARTITION from EACH node (every direction), disjoint id ranges.
    for n in "${nodes[@]}"; do
        q "$n" "CREATE TABLE IF NOT EXISTS public.mddlprobe_p$i PARTITION OF public.mddlprobe FOR VALUES FROM ($((i * 1000))) TO ($(((i + 1) * 1000)));" >/dev/null 2>&1
        i=$((i + 1))
    done
    sleep 3
    for n in "${nodes[@]}"; do
        assert_eq "CREATE PARTITION: $n sees all $want children (every direction)" "$want" \
            "$(q "$n" "SELECT count(*) FROM pg_inherits WHERE inhparent='public.mddlprobe'::regclass;")"
    done

    # (b) DETACH the partition the way the partition manager does on a mesh
    #     (internal/partition Manager.Detach): a local top-level CONCURRENTLY detach,
    #     then the SAME concurrent detach on every peer — Spock cannot replicate
    #     DETACH … CONCURRENTLY (non-txn), so a bare detach would leave p0 attached
    #     on peers. The manager fans this out itself now (per peer, over its own
    #     connection, skipping any node where it is already detached); this probe
    #     drives the identical per-node detach to verify the resulting property.
    #     The detached table is kept.
    for n in "${nodes[@]}"; do
        if [ "$(q "$n" "SELECT count(*) FROM pg_inherits WHERE inhparent='public.mddlprobe'::regclass AND inhrelid=to_regclass('public.mddlprobe_p0');")" != "0" ]; then
            q "$n" "ALTER TABLE public.mddlprobe DETACH PARTITION public.mddlprobe_p0 CONCURRENTLY;" >/dev/null 2>&1
        fi
    done
    sleep 2
    local det=0
    for n in "${nodes[@]}"; do
        [ "$(q "$n" "SELECT count(*) FROM pg_inherits WHERE inhparent='public.mddlprobe'::regclass AND inhrelid='public.mddlprobe_p0'::regclass;")" = "0" ] || det=$((det + 1))
    done
    assert_eq "DETACH PARTITION CONCURRENTLY on every node (manager-style per-node fan-out)" "0" "$det"

    # (c) DROP the detached standalone table from HOST; assert gone on EVERY node.
    q "$HOST" "DROP TABLE IF EXISTS public.mddlprobe_p0;" >/dev/null 2>&1
    sleep 3
    local drp=0
    for n in "${nodes[@]}"; do
        [ "$(q "$n" "SELECT count(*) FROM pg_class WHERE relname='mddlprobe_p0';")" = "0" ] || drp=$((drp + 1))
    done
    assert_eq "DROP TABLE replicated to all nodes (detached p0 gone everywhere)" "0" "$drp"

    q "$HOST" "DROP TABLE IF EXISTS public.mddlprobe CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — 2-level (LIST region → RANGE ts) tiering: the "upgrade a sub-partitioned
# table to tiered" path. A region-agnostic single Iceberg table; leaves tier per
# ts period across ALL regions before the shared cutoff advances. Uses its own
# `regional` table, independent of the single-level `events` above.
# ───────────────────────────────────────────────────────────────────────────
story_tiered_twolevel() {
    step "2-level tiering: LIST(region)→RANGE(ts) hot→cold across regions"
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS regional (
    id     bigint GENERATED ALWAYS AS IDENTITY,
    region text NOT NULL,
    ts     timestamptz NOT NULL,
    status text,
    data   jsonb,
    PRIMARY KEY (id, region, ts)
) PARTITION BY LIST (region);
CREATE TABLE IF NOT EXISTS regional_eu PARTITION OF regional FOR VALUES IN ('eu') PARTITION BY RANGE (ts);
CREATE TABLE IF NOT EXISTS regional_us PARTITION OF regional FOR VALUES IN ('us') PARTITION BY RANGE (ts);
-- RANGE leaves for the m4 m3 m2 (cold) and m1 (hot) months, table-scoped names
-- derived from now()-relative months, per LIST child (eu, us). Never invented
-- calendar literals so the hot/cold split holds under any wall clock.
DO $do$
DECLARE child text; m date; off int;
BEGIN
  FOREACH child IN ARRAY ARRAY['regional_eu','regional_us'] LOOP
    FOR off IN 1..4 LOOP                                   -- now-4mo .. now-1mo
      m := (date_trunc('month', now()) - make_interval(months => 5 - off))::date;
      EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                     child || '_p_' || to_char(m, 'YYYY_MM'), child, m, (m + interval '1 month'));
    END LOOP;
  END LOOP;
END $do$;
INSERT INTO regional (region, ts, status, data) SELECT 'eu', date_trunc('month',now()) - interval '4 months' + interval '14 days' + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,100) i;
INSERT INTO regional (region, ts, status, data) SELECT 'eu', date_trunc('month',now()) - interval '3 months' + interval '9 days'  + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,80) i;
INSERT INTO regional (region, ts, status, data) SELECT 'eu', date_trunc('month',now()) - interval '2 months' + interval '4 days'  + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,60) i;
INSERT INTO regional (region, ts, status, data) SELECT 'eu', date_trunc('month',now()) - interval '1 month'                       + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,40) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', date_trunc('month',now()) - interval '4 months' + interval '19 days' + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,50) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', date_trunc('month',now()) - interval '3 months' + interval '11 days' + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,40) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', date_trunc('month',now()) - interval '2 months' + interval '7 days'  + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,30) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', date_trunc('month',now()) - interval '1 month'  + interval '1 days'  + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,20) i;
EOSQL
    assert_eq "2-level seeded 420 rows" "420" "$(q "$HOST" "SELECT count(*) FROM public.regional;")"

    local ret_days; ret_days=$(( ( $(date -u +%s) - $(date -u -d "$(date -u +%Y-%m-01) -1 month" +%s) ) / 86400 ))  # cutoff = start of now-1mo
    cat > /tmp/journey-tl.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog" }
$(storage_yaml)
archiver:
  tables:
    - source_table: regional
      partition_column: ts
      partition_period: monthly
      hot_period: "${ret_days} days"
      sub_partition: { values_source: "SELECT region FROM (VALUES ('eu'),('us')) r(region)" }
EOF
    if ! "$ARCHIVER" import --config /tmp/journey-tl.yaml >/tmp/journey-tl.log 2>&1; then
        fail "import regional (2-level) into partition_config — see /tmp/journey-tl.log"; tail -8 /tmp/journey-tl.log; return
    fi
    if "$ARCHIVER" --config /tmp/journey-tl.yaml >>/tmp/journey-tl.log 2>&1; then
        pass "2-level archiver run completed (no flat-partitioning Fatal)"
    else
        fail "2-level archiver run — see /tmp/journey-tl.log"; tail -8 /tmp/journey-tl.log; return
    fi

    # Shape: the top becomes a view; the renamed hot table stays LIST-partitioned.
    assert_eq "regional is now a view" "v" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='regional';")"
    assert_eq "_regional is the LIST hot table" "p" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='_regional';")"

    # Past-hot leaves (m4-m2) tiered away for BOTH regions; m1 leaves remain hot.
    assert_eq "eu m4 leaf gone from hot"  "0" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname = 'regional_eu_p_' || to_char(date_trunc('month',now()) - interval '4 months','YYYY_MM');")"
    assert_eq "us m2 leaf gone from hot"  "0" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname = 'regional_us_p_' || to_char(date_trunc('month',now()) - interval '2 months','YYYY_MM');")"
    assert_eq "eu m1 leaf still hot"      "1" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname = 'regional_eu_p_' || to_char(date_trunc('month',now()) - interval '1 month','YYYY_MM');")"
    assert_eq "us m1 leaf still hot"      "1" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname = 'regional_us_p_' || to_char(date_trunc('month',now()) - interval '1 month','YYYY_MM');")"

    # Read correctness across the boundary (the view UNIONs hot + cold).
    assert_eq "2-level total readable (hot+cold)" "420" "$(q "$HOST" "SELECT count(*) FROM regional;")"
    assert_eq "eu total (240 cold + 40 hot)"      "280" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu';")"
    assert_eq "us total (120 cold + 20 hot)"      "140" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='us';")"
    # Cold side is region-usable: a region-filtered cold read returns that region only.
    assert_eq "eu cold rows (m4-m2) present"      "240" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu' AND ts < date_trunc('month',now()) - interval '1 month';")"
    assert_eq "old eu m4 leaf rows live in cold"  "100" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu' AND ts >= date_trunc('month',now()) - interval '4 months' AND ts < date_trunc('month',now()) - interval '3 months';")"

    # Idempotency / cross-region wipe guard: a second run must NOT lose cold rows
    # (a region-blind Phase-0 wipe would under-count here).
    "$ARCHIVER" --config /tmp/journey-tl.yaml >/tmp/journey-tl2.log 2>&1
    assert_eq "re-run keeps all cold rows (region-scoped wipe)" "420" "$(q "$HOST" "SELECT count(*) FROM regional;")"
    assert_eq "re-run keeps eu cold rows" "240" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu' AND ts < date_trunc('month',now()) - interval '1 month';")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story - FK: foreign key on a tiered partitioned table. Asserts:
#   1. The archiver registers and archives a table that has a FK constraint.
#   2. PostgreSQL enforces the FK on the hot tier before and after the view
#      swap, outbound (fk_events references another table) and inbound (a
#      table references fk_events).
#   3. FK enforcement is a PostgreSQL feature that lives only on the hot tier.
#      Iceberg has no foreign keys, so a row in the cold tier is outside FK
#      enforcement by construction: a cold INSERT is not FK-checked, and an
#      inbound FK reference to an archived row is rejected (the row has left
#      _fk_events). See docs/usage.md "Inbound foreign keys". Not a defect to be
#      "fixed" - a consequence of the storage model, asserted so a change in
#      behavior is caught.
# ───────────────────────────────────────────────────────────────────────────
story_fk_constraint() {
    step "FK: PostgreSQL enforces on the hot tier; the cold tier has no FKs"

    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    local ret_days; ret_days=$(( ( $(date -u +%s) - $(date -u -d "$(date -u +%Y-%m-01) -1 month" +%s) ) / 86400 ))

    # Reference table + a partitioned table whose PK is (id, ts) (the partition
    # column must be in the PK) plus an outbound FK on category_id. The FK is
    # added after the partitions exist so PK propagation is unambiguous.
    # SET search_path = public so the unqualified partition names in the DO
    # block land in public (the archiver resolves partitions in the parent's
    # schema); without it they land in the coldfront schema, since the session
    # user is "coldfront" and a coldfront schema exists.
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS public.fk_categories (id int PRIMARY KEY, name text NOT NULL);
INSERT INTO public.fk_categories VALUES (1,'alpha'),(2,'beta') ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS public.fk_events (
    id          bigint GENERATED ALWAYS AS IDENTITY,
    ts          timestamptz NOT NULL,
    category_id int NOT NULL,
    label       text,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
DO $do$
DECLARE m date;
BEGIN
  FOR i IN 1..4 LOOP
    m := (date_trunc('month', now()) - make_interval(months => 5 - i))::date;
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF fk_events FOR VALUES FROM (%L) TO (%L)',
      'fk_events_p_' || to_char(m,'YYYY_MM'), m, m + interval '1 month');
  END LOOP;
END $do$;
ALTER TABLE public.fk_events ADD CONSTRAINT fk_events_category
    FOREIGN KEY (category_id) REFERENCES public.fk_categories(id);
EOSQL

    # Seed one cold (4 months old) + one hot (1 month old) row, both valid.
    q "$HOST" "INSERT INTO fk_events (ts,category_id,label) VALUES (date_trunc('month',now()) - interval '4 months' + interval '1 day', 1, 'cold-valid');" >/dev/null
    q "$HOST" "INSERT INTO fk_events (ts,category_id,label) VALUES (date_trunc('month',now()) - interval '1 month'  + interval '1 day', 2, 'hot-valid');"  >/dev/null

    # Outbound FK, before archiving: PG enforces on the raw partitioned table.
    local pre_err
    pre_err=$(q "$HOST" "INSERT INTO fk_events (ts,category_id,label) VALUES (date_trunc('month',now()) - interval '1 month' + interval '2 days', 999, 'pre-bad-fk');" 2>&1 || true)
    assert_contains "hot INSERT with invalid FK rejected before archiving" "foreign key" "$pre_err"
    assert_eq "no row written for the rejected pre-archive INSERT" "0" \
        "$(q "$HOST" "SELECT count(*) FROM fk_events WHERE label='pre-bad-fk';")"

    # Inbound FK, before archiving: fk_event_details references fk_events(id, ts).
    qf "$HOST" <<'EOSQL' >/dev/null
CREATE TABLE IF NOT EXISTS public.fk_event_details (
    event_id bigint, event_ts timestamptz, note text,
    FOREIGN KEY (event_id, event_ts) REFERENCES public.fk_events(id, ts));
INSERT INTO public.fk_event_details SELECT id, ts, 'pre-inbound-valid' FROM public.fk_events WHERE label='hot-valid';
EOSQL
    assert_eq "inbound FK: valid referencing row accepted before archiving" "1" \
        "$(q "$HOST" "SELECT count(*) FROM fk_event_details WHERE note='pre-inbound-valid';")"
    local pre_inbound_err
    pre_inbound_err=$(q "$HOST" "INSERT INTO fk_event_details VALUES (99999, now(), 'pre-inbound-bad');" 2>&1 || true)
    assert_contains "inbound FK: invalid referencing row rejected before archiving" "foreign key" "$pre_inbound_err"

    # Register + archive. Both must succeed: the (id, ts) PK is valid, so an
    # outbound FK must NOT defeat PK detection / delta capture. A regression
    # there (archiver bailing with "no primary key") fails this story loudly.
    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table fk_events \
            --period monthly --hot-period "${ret_days} days" >/tmp/journey-fk-reg.log 2>&1; then
        pass "fk_events registered (FK does not block registration)"
    else
        fail "fk_events register failed"; tail -5 /tmp/journey-fk-reg.log
    fi
    assert_eq "partition_config row written for fk_events" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE table_name='fk_events';")"

    cat > /tmp/journey-fk.yaml <<EOF
postgres: { dsn: "${dsn}" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog" }
$(storage_yaml)
EOF
    if "$ARCHIVER" --config /tmp/journey-fk.yaml >/tmp/journey-fk-arch.log 2>&1; then
        pass "archiver completed on FK-constrained table"
    else
        fail "archiver failed on FK-constrained table"; tail -8 /tmp/journey-fk-arch.log
    fi

    # View swap happened and the cold row genuinely moved to Iceberg (gone from
    # _fk_events, still visible through the unified view).
    assert_eq "fk_events is a view after archival" "v" \
        "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='fk_events' AND relnamespace='public'::regnamespace;")"
    assert_eq "cold row archived out of _fk_events (the hot PG table)" "0" \
        "$(q "$HOST" "SELECT count(*) FROM _fk_events WHERE label='cold-valid';")"
    assert_eq "cold row still visible via the unified view" "1" \
        "$(q "$HOST" "SELECT count(*) FROM fk_events WHERE label='cold-valid';")"

    # Outbound FK still enforced on the hot tier after the swap.
    local post_err
    post_err=$(q "$HOST" "INSERT INTO fk_events (ts,category_id,label) VALUES (now(), 999, 'post-bad-fk');" 2>&1 || true)
    assert_contains "hot INSERT with invalid FK still rejected after view swap" "foreign key" "$post_err"
    assert_eq "no row written for the rejected post-swap INSERT" "0" \
        "$(q "$HOST" "SELECT count(*) FROM fk_events WHERE label='post-bad-fk';")"
    q "$HOST" "INSERT INTO fk_events (ts,category_id,label) VALUES (now(), 1, 'post-valid');" >/dev/null
    assert_eq "valid hot INSERT works after view swap" "1" \
        "$(q "$HOST" "SELECT count(*) FROM fk_events WHERE label='post-valid';")"

    # Inbound FK after the swap: enforces against hot rows (the FK tracks the
    # renamed _fk_events, same OID). Read the hot (id, ts) straight from
    # _fk_events; reading it from the view and INSERT..SELECT-ing would route
    # the whole statement through pg_duckdb, which cannot write a PG table.
    q "$HOST" "INSERT INTO fk_event_details SELECT id, ts, 'post-inbound-hot' FROM _fk_events WHERE label='post-valid';" >/dev/null
    assert_eq "inbound FK: valid referencing row (hot) works after view swap" "1" \
        "$(q "$HOST" "SELECT count(*) FROM fk_event_details WHERE note='post-inbound-hot';")"
    local post_inbound_bad
    post_inbound_bad=$(q "$HOST" "INSERT INTO fk_event_details VALUES (99999, now(), 'post-inbound-bad');" 2>&1 || true)
    assert_contains "inbound FK: invalid referencing row still rejected after view swap" "foreign key" "$post_inbound_bad"

    # An inbound FK references _fk_events (the hot PG table). Once a row is
    # archived it leaves _fk_events, so PostgreSQL rejects a referencing row
    # that points at an archived (cold) row - the FK domain is the hot tier
    # only. Inherent to tiering (see docs/usage.md "Inbound foreign keys"),
    # asserted so a change in behavior is caught. The cold (id, ts) is read
    # once (plain SELECT), then referenced as literals so the INSERT is a plain
    # PG write and the FK check (not a pg_duckdb takeover) is what rejects it.
    local cold_id cold_inbound_err
    cold_id=$(q "$HOST" "SELECT id FROM fk_events WHERE label='cold-valid';")
    cold_inbound_err=$(q "$HOST" "INSERT INTO fk_event_details VALUES (${cold_id}, date_trunc('month',now()) - interval '4 months' + interval '1 day', 'cold-inbound');" 2>&1 || true)
    assert_contains "inbound FK reference to an archived (cold) row is rejected (cold rows are outside PG FK enforcement)" "foreign key" "$cold_inbound_err"
    q "$HOST" "DELETE FROM fk_event_details WHERE note='cold-inbound';" >/dev/null 2>&1

    # A cold INSERT is written to Iceberg, which has no foreign keys, so it is
    # not FK-checked and an invalid category_id is accepted. This is by
    # construction, not a bypassed check: FK enforcement exists only on the hot
    # tier. Asserted so a change in behavior is caught.
    q "$HOST" "INSERT INTO fk_events (ts,category_id,label) VALUES (date_trunc('month',now()) - interval '4 months' + interval '2 days', 999, 'cold-bad-fk');" >/dev/null 2>&1 || true
    assert_eq "cold INSERT is not FK-checked (Iceberg has no foreign keys)" "1" \
        "$(q "$HOST" "SELECT count(*) FROM fk_events WHERE label='cold-bad-fk';")"

    # Cleanup.
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE table_name='fk_events';" >/dev/null 2>&1
    q "$HOST" "DROP TABLE IF EXISTS public.fk_event_details;" >/dev/null 2>&1
    q "$HOST" "DROP VIEW  IF EXISTS public.fk_events CASCADE;" >/dev/null 2>&1
    q "$HOST" "DROP TABLE IF EXISTS public._fk_events CASCADE;" >/dev/null 2>&1
    q "$HOST" "DROP TABLE IF EXISTS public.fk_categories CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — archiver mid-archive crash rollback: kill the archiver during the
# post-Phase-2 debug window and verify that on re-run Phase 0 wipes the
# partial Iceberg data and the archive completes cleanly. Asserts no data is
# lost from PostgreSQL during a crash.
# ───────────────────────────────────────────────────────────────────────────
story_archiver_rollback() {
    step "Archiver rollback: mid-archive crash → Phase 0 self-heals on re-run"

    # Tear down the temp table + its config/watermark rows on EVERY exit path,
    # including the early failure returns below, so a failed run cannot leak
    # rb_events (or its partition_config row) into later config-driven stories.
    _rb_cleanup() {
        q "$HOST" "DELETE FROM coldfront.partition_config WHERE table_name='rb_events';" >/dev/null 2>&1
        q "$HOST" "DELETE FROM coldfront.archive_watermark WHERE table_name='rb_events';" >/dev/null 2>&1
        q "$HOST" "DROP VIEW  IF EXISTS public.rb_events CASCADE;" >/dev/null 2>&1
        q "$HOST" "DROP TABLE IF EXISTS public._rb_events CASCADE;" >/dev/null 2>&1
        q "$HOST" "DROP TABLE IF EXISTS public.rb_events CASCADE;" >/dev/null 2>&1
    }
    trap _rb_cleanup RETURN

    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    local ret_days; ret_days=$(( ( $(date -u +%s) - $(date -u -d "$(date -u +%Y-%m-01) -1 month" +%s) ) / 86400 ))

    # Partitioned table with one cold partition (3 months ago) and one hot partition (current month).
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS public.rb_events (
    id     bigint GENERATED ALWAYS AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
DO $do$
DECLARE m date;
BEGIN
  m := date_trunc('month', now()) - interval '3 months';
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF rb_events FOR VALUES FROM (%L) TO (%L)',
    'rb_events_p_cold', m, m + interval '1 month');
  m := date_trunc('month', now());
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF rb_events FOR VALUES FROM (%L) TO (%L)',
    'rb_events_p_hot', m, m + interval '1 month');
END $do$;
EOSQL

    q "$HOST" "INSERT INTO public.rb_events (ts, status) VALUES (date_trunc('month',now()) - interval '3 months' + interval '1 day', 'crash-row'), (now(), 'hot-row');" >/dev/null

    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table rb_events \
            --period monthly --hot-period "${ret_days} days" >/tmp/journey-rb-reg.log 2>&1; then
        pass "rb_events registered"
    else
        fail "rb_events register failed"; tail -5 /tmp/journey-rb-reg.log; return
    fi

    cat > /tmp/journey-rb.yaml <<EOF
postgres: { dsn: "${dsn}" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog" }
$(storage_yaml)
EOF

    # Hold the window open AFTER Phase 2 (bulk export+commit) and BEFORE Phase 3
    # (replay+cutover). Wait for the archiver to actually reach that hold (its log
    # marker) before killing, so the crash lands with cold rows already in Iceberg
    # but the partition not yet cut over -- the partial state Phase 0 must
    # self-heal. Fail loudly if it never gets there (else the test proves nothing).
    "$ARCHIVER" --config /tmp/journey-rb.yaml --debug-export-delay 60s >/tmp/journey-rb-crash.log 2>&1 &
    local arch_pid=$!
    local reached=0
    for _ in $(seq 1 60); do
        grep -q "debug-export-delay" /tmp/journey-rb-crash.log 2>/dev/null && { reached=1; break; }
        kill -0 "$arch_pid" 2>/dev/null || break   # archiver exited early (error)
        sleep 1
    done
    if [ "$reached" != 1 ]; then
        fail "archiver never reached the post-Phase-2 hold (nothing to crash-test)"
        tail -8 /tmp/journey-rb-crash.log
        kill "$arch_pid" 2>/dev/null || true; wait "$arch_pid" 2>/dev/null || true
        return
    fi
    kill "$arch_pid" 2>/dev/null || true
    wait "$arch_pid" 2>/dev/null || true

    # Data must still be in PG — not lost.
    assert_eq "crash-row still in PG after mid-archive crash" "1" \
        "$(q "$HOST" "SELECT count(*) FROM public.rb_events WHERE status='crash-row';")"

    # Re-run: Phase 0 wipes partial Iceberg data; full archive must complete.
    if "$ARCHIVER" --config /tmp/journey-rb.yaml >/tmp/journey-rb-rerun.log 2>&1; then
        pass "archiver self-healed on re-run (Phase 0 wiped partial Iceberg data)"
    else
        fail "archiver re-run failed after crash"; tail -8 /tmp/journey-rb-rerun.log; return
    fi

    assert_eq "watermark written after successful re-run" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.archive_watermark WHERE table_name='rb_events';")"
    assert_eq "both rows visible via unified view after re-run" "2" \
        "$(q "$HOST" "SELECT count(*) FROM public.rb_events;")"
    # cleanup is handled by the RETURN trap set at the top (covers early returns)
}

# ───────────────────────────────────────────────────────────────────────────
# Story — partitioner inbound FK blocks expired partition drop: asserts the
# partitioner fails fast (SQLSTATE 23503, no retry), the partition remains
# attached, and on re-run after the FK reference is removed the partition is
# dropped cleanly.
# ───────────────────────────────────────────────────────────────────────────
story_partitioner_fk_drop() {
    step "Partitioner rollback: inbound FK blocks expired partition drop → self-heals after FK removed"

    # Mesh topology propagates partition detach to peers; peer DNS is not
    # available in the single-node journey config, so skip in mesh mode.
    if [ "$MESH" = 1 ]; then
        note "skipping partitioner FK drop rollback in mesh mode (peer propagation requires mesh config)"
        return
    fi

    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    printf 'postgres: { dsn: "%s" }\n' "$dsn" > /tmp/journey-pfk.yaml

    # Partitioned table with one expired partition (3 months old) and one current partition.
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS public.pfk_logs (
    id  bigint GENERATED ALWAYS AS IDENTITY,
    ts  timestamptz NOT NULL,
    msg text,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
DO $do$
DECLARE m date;
BEGIN
  m := date_trunc('month', now()) - interval '3 months';
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF pfk_logs FOR VALUES FROM (%L) TO (%L)',
    'pfk_logs_p_expired', m, m + interval '1 month');
  m := date_trunc('month', now());
  EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF pfk_logs FOR VALUES FROM (%L) TO (%L)',
    'pfk_logs_p_current', m, m + interval '1 month');
END $do$;
EOSQL

    q "$HOST" "INSERT INTO public.pfk_logs (ts, msg) VALUES (date_trunc('month',now()) - interval '3 months' + interval '1 day', 'old-row'), (now(), 'hot-row');" >/dev/null

    # Inbound FK from pfk_log_refs → pfk_logs(id, ts) references the expired row.
    qf "$HOST" <<'EOSQL' >/dev/null
CREATE TABLE IF NOT EXISTS public.pfk_log_refs (
    ref_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    log_id bigint NOT NULL,
    log_ts timestamptz NOT NULL,
    FOREIGN KEY (log_id, log_ts) REFERENCES public.pfk_logs(id, ts)
);
INSERT INTO public.pfk_log_refs (log_id, log_ts)
    SELECT id, ts FROM public.pfk_logs WHERE msg = 'old-row';
EOSQL

    if "$PARTITIONER" register --dsn "$dsn" --schema public --table pfk_logs \
            --period monthly --retention "1 month" >/tmp/journey-pfk-reg.log 2>&1; then
        pass "pfk_logs registered as partition-only"
    else
        fail "pfk_logs register failed"; tail -5 /tmp/journey-pfk-reg.log; return
    fi

    # Run partitioner — inbound FK must block the expired partition drop and fail fast.
    local pfk_out
    pfk_out=$("$PARTITIONER" --config /tmp/journey-pfk.yaml 2>&1 || true)
    assert_contains "partitioner fails fast on inbound FK (SQLSTATE 23503)" "23503" "$pfk_out"

    # Expired partition must still be attached — data safe in PG.
    assert_eq "expired partition still attached after FK-blocked drop" "1" \
        "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='pfk_logs_p_expired';")"

    # Fix: remove the referencing row then re-run.
    q "$HOST" "DELETE FROM public.pfk_log_refs WHERE log_ts < date_trunc('month',now()) - interval '2 months';" >/dev/null

    if "$PARTITIONER" --config /tmp/journey-pfk.yaml >/tmp/journey-pfk-rerun.log 2>&1; then
        pass "partitioner self-healed after FK reference removed"
    else
        fail "partitioner re-run failed after FK removed"; tail -8 /tmp/journey-pfk-rerun.log; return
    fi

    assert_eq "expired partition dropped after FK removed" "0" \
        "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='pfk_logs_p_expired';")"

    # Cleanup.
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE table_name='pfk_logs';" >/dev/null 2>&1
    q "$HOST" "DROP TABLE IF EXISTS public.pfk_log_refs CASCADE;" >/dev/null 2>&1
    q "$HOST" "DROP TABLE IF EXISTS public.pfk_logs CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — management CLI end-to-end: register a table via the subcommand (PK
# validation), list it, reject a PK-less table, then run the archiver with NO
# YAML tables so it drives entirely off coldfront.partition_config, and export.
# ───────────────────────────────────────────────────────────────────────────
story_register_cli() {
    step "Management CLI: register / list / run-off-partition_config / export"
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS cli_events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL,
    v  int,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
-- RANGE leaves for the m3 (cold) and m1 (hot) months, table-scoped names derived
-- from now()-relative months (never invented calendar literals).
DO $do$
DECLARE m date;
BEGIN
  FOREACH m IN ARRAY ARRAY[(date_trunc('month',now()) - interval '3 months')::date,
                           (date_trunc('month',now()) - interval '1 month')::date] LOOP
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF cli_events FOR VALUES FROM (%L) TO (%L)',
                   'cli_events_p_' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month'));
  END LOOP;
END $do$;
INSERT INTO cli_events (ts, v) SELECT date_trunc('month',now()) - interval '3 months' + interval '9 days' + (i*interval '1 hour'), i FROM generate_series(1,50) i;
INSERT INTO cli_events (ts, v) SELECT date_trunc('month',now()) - interval '1 month'  + interval '4 days' + (i*interval '1 hour'), i FROM generate_series(1,30) i;
-- A partitioned table with NO primary key: register must reject it (the cutover
-- keys delta capture by the source PK). (PG itself forbids a PK that omits the
-- partition key, so "PK doesn't cover the key" is impossible to construct.)
CREATE TABLE IF NOT EXISTS cli_nopk (id bigint, ts timestamptz NOT NULL) PARTITION BY RANGE (ts);
EOSQL
    local ret_days; ret_days=$(( ( $(date -u +%s) - $(date -u -d "$(date -u +%Y-%m-01) -1 month" +%s) ) / 86400 ))  # tier m3, keep m1

    # register (tiered) — validates the PK, INSERTs the row.
    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table cli_events \
            --period monthly --hot-period "${ret_days} days" >/tmp/journey-reg.log 2>&1; then
        pass "register cli_events (PK validated, row written)"
    else
        fail "register cli_events — see /tmp/journey-reg.log"; tail -5 /tmp/journey-reg.log
    fi
    assert_eq "partition_config row created" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE table_name='cli_events';")"

    # list shows it.
    "$ARCHIVER" list --config /tmp/journey-archiver.yaml >/tmp/journey-list.log 2>&1
    if grep -q "cli_events" /tmp/journey-list.log; then pass "list shows cli_events"; else fail "list missing cli_events"; cat /tmp/journey-list.log; fi

    # register must reject the PK-less table (loud, before any row is written).
    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table cli_nopk \
            --period monthly --hot-period "1 month" >/tmp/journey-nopk.log 2>&1; then
        fail "register cli_nopk should have failed (no primary key)"
    else
        if grep -qi "primary key" /tmp/journey-nopk.log; then pass "register rejects the PK-less table"; else fail "wrong rejection reason"; tail -3 /tmp/journey-nopk.log; fi
    fi
    assert_eq "no row written for the rejected table" "0" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE table_name='cli_nopk';")"

    # Parity: import must reject the SAME PK-less table register rejects — every
    # write to partition_config goes through one validation gate.
    # Partition-only (retention, no hot_period) so the config needs no cold backend;
    # the PK-superset check still fires and must reject the PK-less table.
    cat > /tmp/journey-nopk.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
archiver: { tables: [ { source_table: cli_nopk, partition_period: monthly, retention_period: "60 months" } ] }
EOF
    if "$ARCHIVER" import --config /tmp/journey-nopk.yaml >/tmp/journey-nopk-imp.log 2>&1; then
        fail "import cli_nopk should have failed (no primary key)"
    else
        if grep -qi "primary key" /tmp/journey-nopk-imp.log; then pass "import rejects the PK-less table (parity with register)"; else fail "wrong import rejection reason"; tail -3 /tmp/journey-nopk-imp.log; fi
    fi
    assert_eq "import wrote no row for the rejected table" "0" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE table_name='cli_nopk';")"

    # retention must exceed hot-period — caught at register time, before any write.
    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table cli_events \
            --period monthly --hot-period "3 months" --retention "1 month" >/tmp/journey-rethot.log 2>&1; then
        fail "register should reject retention <= hot-period"
    else
        if grep -qi "must exceed" /tmp/journey-rethot.log; then pass "register rejects retention <= hot-period"; else fail "wrong reason"; tail -3 /tmp/journey-rethot.log; fi
    fi

    # Periods are native PG intervals: a compound form the old "N unit" parser
    # could never accept now validates (proves the textual parser is gone). --dry-run
    # runs the full conn-backed validation (interval cast) but writes no row.
    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table cli_events \
            --period monthly --retention "1 year 2 mons" --dry-run >/tmp/journey-iv.log 2>&1; then
        pass "register accepts a native PG interval (\"1 year 2 mons\")"
    else
        fail "register rejected a valid PG interval"; tail -3 /tmp/journey-iv.log
    fi
    # A non-interval value is rejected by the interval validation (the column type
    # is the write-time backstop; ValidatePeriods gives the clean error first).
    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table cli_events \
            --period monthly --retention "banana" --dry-run >/tmp/journey-badiv.log 2>&1; then
        fail "register should reject a non-interval retention"
    else
        if grep -qi "interval" /tmp/journey-badiv.log; then pass "register rejects a non-interval period"; else fail "wrong reason"; tail -3 /tmp/journey-badiv.log; fi
    fi

    # Run the archiver with a connection-only YAML (NO archiver.tables): it must
    # drive entirely off coldfront.partition_config.
    cat > /tmp/journey-conn.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog" }
$(storage_yaml)
EOF
    if "$ARCHIVER" --config /tmp/journey-conn.yaml >/tmp/journey-dbrun.log 2>&1; then
        pass "archiver ran with no YAML tables"
    else
        fail "archiver DB-driven run — see /tmp/journey-dbrun.log"; tail -8 /tmp/journey-dbrun.log
    fi
    if grep -q "from coldfront.partition_config" /tmp/journey-dbrun.log; then pass "archiver drove off partition_config (not YAML)"; else fail "did not load from partition_config"; tail -3 /tmp/journey-dbrun.log; fi
    assert_eq "cli_events tiered via DB config (now a view)" "v" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='cli_events';")"
    assert_eq "cli_events readable hot+cold after DB-driven tiering" "80" "$(q "$HOST" "SELECT count(*) FROM cli_events;")"

    # export round-trips the managed set to reviewable YAML.
    "$ARCHIVER" export --config /tmp/journey-conn.yaml >/tmp/journey-export.log 2>&1
    if grep -q "source_table: cli_events" /tmp/journey-export.log; then pass "export emits cli_events as YAML"; else fail "export missing cli_events"; tail -5 /tmp/journey-export.log; fi

    # TC-118: archiver.tables in YAML is ignored at runtime — the archiver always
    # resolves its table set from coldfront.partition_config regardless of what
    # archiver.tables says in the config file.
    cat > /tmp/journey-yaml-tables.yaml <<EOYAML
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog", namespace: "default" }
$(storage_yaml)
archiver:
  tables:
    - source_table: bogus_table_yaml
      partition_period: monthly
      hot_period: "1 month"
      retention_period: "2 years"
EOYAML
    if "$ARCHIVER" --config /tmp/journey-yaml-tables.yaml >/tmp/journey-yaml-tables.log 2>&1; then
        pass "TC-118: archiver ran with stale archiver.tables block in YAML"
    else
        fail "TC-118: archiver failed — see /tmp/journey-yaml-tables.log"; tail -8 /tmp/journey-yaml-tables.log
    fi
    if grep -q "from coldfront.partition_config" /tmp/journey-yaml-tables.log; then
        pass "TC-118: archiver drove off partition_config (YAML archiver.tables ignored)"
    else
        fail "TC-118: archiver did not load from partition_config"; tail -5 /tmp/journey-yaml-tables.log
    fi
    if grep -qi "bogus_table_yaml" /tmp/journey-yaml-tables.log; then
        fail "TC-118: archiver processed the YAML-only table (should be ignored)"
    else
        pass "TC-118: YAML archiver.tables block was not processed"
    fi

    # TC-119: export → delete row → import restores the partition_config entry.
    # export emits ALL enabled tables; importing that full set would hit unique-key
    # conflicts on rows still in partition_config. Verify export is correct
    # separately, then import only cli_events via a targeted YAML.
    "$ARCHIVER" export --config /tmp/journey-conn.yaml >/tmp/journey-export.log 2>&1
    if grep -q "source_table: cli_events" /tmp/journey-export.log; then
        pass "TC-119: export produced YAML with cli_events"
    else
        fail "TC-119: export missing cli_events"; tail -3 /tmp/journey-export.log
    fi
    cat > /tmp/journey-roundtrip.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog", namespace: "default" }
$(storage_yaml)
archiver:
  tables:
    - source_table: cli_events
      partition_period: monthly
      hot_period: "${ret_days} days"
EOF
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE schema_name='public' AND table_name='cli_events';" >/dev/null
    assert_eq "TC-119: cli_events deleted from partition_config" "0" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE table_name='cli_events';")"
    if "$ARCHIVER" import --config /tmp/journey-roundtrip.yaml >/tmp/journey-roundtrip.log 2>&1; then
        pass "TC-119: import from YAML succeeded"
    else
        fail "TC-119: import failed — see /tmp/journey-roundtrip.log"; tail -5 /tmp/journey-roundtrip.log
    fi
    assert_eq "TC-119: cli_events row restored in partition_config" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE table_name='cli_events';")"

    # TC-120: set writes to partition_config only — the YAML config file is never
    # touched. Capture a checksum before, run set, then verify both the DB
    # change and the unchanged file.
    local yaml_cksum; yaml_cksum=$(md5sum /tmp/journey-conn.yaml | awk '{print $1}')
    if "$ARCHIVER" set --config /tmp/journey-conn.yaml --table cli_events --hot-period "45 days" >/tmp/journey-setf.log 2>&1; then
        pass "TC-120: set --hot-period succeeded"
    else
        fail "TC-120: set failed — see /tmp/journey-setf.log"; tail -3 /tmp/journey-setf.log
    fi
    local hot_val; hot_val=$(q "$HOST" "SELECT hot_period FROM coldfront.partition_config WHERE schema_name='public' AND table_name='cli_events';")
    if echo "$hot_val" | grep -qi "45"; then
        pass "TC-120: partition_config.hot_period updated to 45 days"
    else
        fail "TC-120: partition_config.hot_period not updated (got: $hot_val)"
    fi
    if [ "$(md5sum /tmp/journey-conn.yaml | awk '{print $1}')" = "$yaml_cksum" ]; then
        pass "TC-120: YAML file unchanged by set"
    else
        fail "TC-120: set modified the YAML file (it must not)"
    fi
}

# idmode_check <label> <table> <coltype> <id-default> <id-scheme> — provision a
# partition-only RANGE(id) table, register it id-mode, run the partitioner, then
# assert it premade id-partitions and a freshly-generated id lands in a live one.
idmode_check() {
    local label="$1" tbl="$2" coltype="$3" iddef="$4" scheme="$5"
    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    printf 'postgres: { dsn: "%s" }\n' "$dsn" > /tmp/journey-part.yaml
    # Dedicated schema: the partitioner names flat partitions p_YYYY_MM (not
    # table-scoped), so an id-mode table in public would collide with the events
    # table's archiver-premade public.p_YYYY_MM (CREATE ... IF NOT EXISTS then
    # silently skips → 0 children). A private schema keeps idmode.p_YYYY_MM distinct.
    q "$HOST" "CREATE SCHEMA IF NOT EXISTS idmode; CREATE TABLE IF NOT EXISTS idmode.$tbl (id $coltype NOT NULL DEFAULT $iddef, payload text, PRIMARY KEY (id)) PARTITION BY RANGE (id);" >/dev/null
    if ! "$PARTITIONER" register --dsn "$dsn" --schema idmode --table "$tbl" --period monthly \
            --part-mode id --id-scheme "$scheme" --retention "60 months" >"/tmp/journey-$tbl-reg.log" 2>&1; then
        fail "$label id-mode: register failed"; tail -5 "/tmp/journey-$tbl-reg.log"; return
    fi
    if ! "$PARTITIONER" --config /tmp/journey-part.yaml >"/tmp/journey-$tbl-run.log" 2>&1; then
        fail "$label id-mode: partitioner run failed"; tail -8 "/tmp/journey-$tbl-run.log"; return
    fi
    assert_gt "$label id-mode: partitioner premade RANGE(id) partitions" "1" \
        "$(q "$HOST" "SELECT count(*) FROM pg_inherits WHERE inhparent='idmode.$tbl'::regclass;")"
    q "$HOST" "INSERT INTO idmode.$tbl (payload) VALUES ('live');" >/dev/null 2>&1
    assert_eq "$label id-mode: a freshly-generated id landed in a live partition" "1" \
        "$(q "$HOST" "SELECT count(*) FROM idmode.$tbl WHERE payload='live';")"
    # Clean up so the SHARED coldfront.partition_config (the partitioner's all-rows
    # load) stays clean for later stories.
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE schema_name='idmode' AND table_name='$tbl'; DROP TABLE IF EXISTS idmode.$tbl CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — partitioner id-mode (partition-only): RANGE on a time-ordered id.
# uuidv7() is a PG18 built-in (absent on PG16/17), so the uuidv7 leg runs only
# where the function exists; snowflake needs the snowflake extension, so it runs
# only on mesh cells. The partitioner's id-decode is the same Go on every PG
# version, so the two legs together cover it (PG16/17 vanilla has neither
# generator and is left uncovered — noted, not silent). probe-snowflake.sh
# separately cross-checks the snowflake id↔epoch math against the live extension.
# ───────────────────────────────────────────────────────────────────────────
story_partitioner_idmode() {
    local have_uuidv7 schemes=""
    have_uuidv7=$(q "$HOST" "SELECT count(*) FROM pg_proc WHERE proname='uuidv7' AND pronargs=0;")
    [ "$have_uuidv7" = 1 ] && schemes="uuidv7"
    [ "$MESH" = 1 ] && schemes="${schemes:+$schemes + }snowflake"
    step "Partitioner id-mode: premake RANGE(id), fresh id lands (${schemes:-none on this cell})"
    if [ "$have_uuidv7" = 1 ]; then
        idmode_check "uuidv7"    idv7 uuid   "uuidv7()"            uuidv7
    else
        note "uuidv7 id-mode: skipped — uuidv7() is a PG18 built-in, absent on this server"
    fi
    [ "$MESH" = 1 ] && idmode_check "snowflake" idsf bigint "snowflake.nextval()" snowflake
}

# ───────────────────────────────────────────────────────────────────────────
# Story — partitioner: TWO independent flat tables in the SAME schema (the real-
# world case). Before the table-scoped-naming fix both tables
# generated the same leaf names (p_YYYY_MM); the second's CREATE … IF NOT EXISTS
# silently no-op'd, leaving it partition-less while the run still reported
# success. Assert BOTH tables get their own (table-scoped) partitions, the leaf
# names are prefixed per table, and a fresh row lands in each.
# ───────────────────────────────────────────────────────────────────────────
story_partitioner_multitable() {
    step "Partitioner multi-table: two flat tables, one schema, both partitioned"
    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    printf 'postgres: { dsn: "%s" }\n' "$dsn" > /tmp/journey-mt.yaml
    q "$HOST" "CREATE SCHEMA IF NOT EXISTS mt;
               CREATE TABLE IF NOT EXISTS mt.orders    (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL, PRIMARY KEY (id, ts)) PARTITION BY RANGE (ts);
               CREATE TABLE IF NOT EXISTS mt.shipments (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL, PRIMARY KEY (id, ts)) PARTITION BY RANGE (ts);" >/dev/null
    local t
    for t in orders shipments; do
        if ! "$PARTITIONER" register --dsn "$dsn" --schema mt --table "$t" --period monthly --retention "60 months" >"/tmp/journey-mt-$t-reg.log" 2>&1; then
            fail "multi-table: register mt.$t failed"; tail -5 "/tmp/journey-mt-$t-reg.log"; return
        fi
    done
    if ! "$PARTITIONER" --config /tmp/journey-mt.yaml >/tmp/journey-mt-run.log 2>&1; then
        fail "multi-table: partitioner run failed"; tail -8 /tmp/journey-mt-run.log; return
    fi
    # BOTH tables get partitions — the collision bug left the second with zero.
    assert_gt "multi-table: mt.orders has partitions"    "1" "$(q "$HOST" "SELECT count(*) FROM pg_inherits WHERE inhparent='mt.orders'::regclass;")"
    assert_gt "multi-table: mt.shipments has partitions" "1" "$(q "$HOST" "SELECT count(*) FROM pg_inherits WHERE inhparent='mt.shipments'::regclass;")"
    # Leaf names are table-scoped (orders_p_… / shipments_p_…), so they never collide.
    assert_gt "multi-table: orders leaves are table-scoped" "0" \
        "$(q "$HOST" "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='mt.orders'::regclass AND starts_with(c.relname,'orders_p_');")"
    # A fresh row lands in each (a live partition covers now in BOTH tables).
    q "$HOST" "INSERT INTO mt.orders (ts) VALUES (now()); INSERT INTO mt.shipments (ts) VALUES (now());" >/dev/null 2>&1
    assert_eq "multi-table: row landed in mt.orders"    "1" "$(q "$HOST" "SELECT count(*) FROM mt.orders;")"
    assert_eq "multi-table: row landed in mt.shipments" "1" "$(q "$HOST" "SELECT count(*) FROM mt.shipments;")"
    # Clean up so the SHARED coldfront.partition_config stays clean for later stories.
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE schema_name='mt'; DROP SCHEMA mt CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — after the archiver's first-run swap (events → _events, with
# a unified view left in events' place) the standalone partitioner must premake
# against the real partitioned table (_events), not the view. The configured /
# registered source name is still "events"; reconcileTable resolves it to the
# "_"+name partitioned relation before building the spec, so it premakes the
# forward window straight onto _events and never touches the view (which would
# trip the verify-attach guard: "not attached … different parent").
# ───────────────────────────────────────────────────────────────────────────
story_partitioner_after_swap() {
    step "Partitioner after first-run swap: premakes onto _events, not the view"
    # Precondition (set up by story_provision_tiered): events is a VIEW now and
    # _events is the partitioned hot table.
    assert_eq "precondition — events is a view"       "v" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='events'  AND relnamespace='public'::regnamespace;")"
    assert_eq "precondition — _events is partitioned" "p" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='_events' AND relnamespace='public'::regnamespace;")"
    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    printf 'postgres: { dsn: "%s" }\n' "$dsn" > /tmp/journey-partitioner.yaml
    # events is archiver-owned (tiered). Temporarily make it partition-only so the
    # standalone partitioner manages it and premakes a wide future window (6, vs the
    # archiver's 3) — proving it resolves the events VIEW to the real _events table
    # — then restore the tiered config for later stories. retention 60mo drops nothing.
    local prev_hot prev_ret prev_pre
    prev_hot=$(q "$HOST" "SELECT hot_period::text       FROM coldfront.partition_config WHERE schema_name='public' AND table_name='events';")
    prev_ret=$(q "$HOST" "SELECT retention_period::text FROM coldfront.partition_config WHERE schema_name='public' AND table_name='events';")
    prev_pre=$(q "$HOST" "SELECT future_partitions      FROM coldfront.partition_config WHERE schema_name='public' AND table_name='events';")
    if ! "$PARTITIONER" set --config /tmp/journey-partitioner.yaml --table events --hot-period "" --retention "60 months" --premake 6 >/tmp/journey-partitioner.log 2>&1; then
        fail "set events partition-only — see /tmp/journey-partitioner.log"; tail -5 /tmp/journey-partitioner.log; return
    fi
    if "$PARTITIONER" --config /tmp/journey-partitioner.yaml >>/tmp/journey-partitioner.log 2>&1; then
        pass "partitioner ran off partition_config (events temporarily partition-only)"
    else
        fail "partitioner run failed"; tail -8 /tmp/journey-partitioner.log
    fi
    # The partitioner resolves events → _events, so the reconcile is logged against _events.
    if grep -q "\[_events\] reconciled" /tmp/journey-partitioner.log; then
        pass "partitioner reconciled _events (resolved past the view)"
    else
        fail "reconcile did not target _events"; tail -8 /tmp/journey-partitioner.log
    fi
    # And it never trips the verify-attach guard that targeting the view would hit.
    if grep -q "different parent" /tmp/journey-partitioner.log; then
        fail "partitioner tripped the verify-attach guard (still targeting the view)"; tail -8 /tmp/journey-partitioner.log
    else
        pass "no verify-attach error (did not touch the view)"
    fi
    # Behavioral proof: the +5-month leaf (beyond the archiver's premake window) is
    # attached to _events, the real partitioned table — not orphaned or erroring.
    local fut; fut="events_p_$(date -u -d "$(date -u +%Y-%m-01) +5 months" +%Y_%m)"
    assert_eq "+5mo leaf $fut premade onto _events" "1" \
        "$(q "$HOST" "SELECT count(*) FROM pg_inherits i JOIN pg_class c ON c.oid=i.inhrelid WHERE i.inhparent='public._events'::regclass AND c.relname='$fut';")"
    # Restore events' tiered config so later stories see it as the archiver owns it;
    # a failed restore would corrupt them, so fail loud.
    "$ARCHIVER" set --config /tmp/journey-partitioner.yaml --table events --hot-period "$prev_hot" --retention "$prev_ret" --premake "$prev_pre" >/dev/null 2>&1 \
        || fail "restore events tiered config after partitioner-after-swap test"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — coldfront.partition_config is ONE shared table holding both
# archiver-owned (tiered: hot_period set) and partitioner-owned (partition-only:
# hot_period NULL) rows. Each binary must load only the rows it owns, scoped in
# SQL by hot_period. Pre-fix the shared loader took every enabled row, so the
# archiver choked on the partition-only row ("hot_period is required in tiered
# mode") and the partitioner on the tiered row ("only valid in tiered mode").
# Mirrors the issue's repro: one of each in a private schema, run each binary,
# assert it logs "loaded 1 table(s)" and the validation errors are absent. A
# private schema keeps the p_YYYY_MM leaves clear of public.events (see
# idmode_check) and the cleanup keeps the shared config clean for later stories.
# ───────────────────────────────────────────────────────────────────────────
story_partition_config_ownership() {
    step "Shared partition_config: each binary loads only the rows it owns"
    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    q "$HOST" "CREATE SCHEMA IF NOT EXISTS own;
               CREATE TABLE IF NOT EXISTS own.po  (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL, PRIMARY KEY (id, ts)) PARTITION BY RANGE (ts);
               CREATE TABLE IF NOT EXISTS own.tier(id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL, PRIMARY KEY (id, ts)) PARTITION BY RANGE (ts);" >/dev/null

    # own.po → partition-only (partitioner, hot_period NULL); own.tier → tiered
    # (archiver, hot_period set). Both land in the one shared partition_config
    # (which also still holds earlier stories' tiered rows: events, cli_events —
    # so we assert per-table ownership, NOT an absolute "loaded N" count).
    "$PARTITIONER" register --dsn "$dsn" --schema own --table po   --period monthly --retention "60 months" >/tmp/journey-own-po-reg.log   2>&1
    "$ARCHIVER"    register --dsn "$dsn" --schema own --table tier --period monthly --hot-period "1 month" --retention "60 months" >/tmp/journey-own-tier-reg.log 2>&1
    assert_eq "partition-only row owned by partitioner (hot_period NULL)" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE schema_name='own' AND table_name='po'   AND hot_period IS NULL;")"
    assert_eq "tiered row owned by archiver (hot_period set)"             "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE schema_name='own' AND table_name='tier' AND hot_period IS NOT NULL;")"

    # Archiver run: processes its tiered row (own.tier), never the partitioner's
    # partition-only row (own.po), and no longer aborts on a foreign row.
    "$ARCHIVER" --config /tmp/journey-archiver.yaml >/tmp/journey-own-arch.log 2>&1 || true
    if grep -q "hot_period is required in tiered mode" /tmp/journey-own-arch.log; then
        fail "archiver still choked on the partition-only row"; tail -5 /tmp/journey-own-arch.log
    else
        pass "archiver did not choke on the partition-only row"
    fi
    # Per-table logs use the bare source-table name ([tier] / [po]); own.tier and
    # own.po are unique here so the substrings are unambiguous.
    assert_contains "archiver processed its own tiered table" "[tier]" "$(cat /tmp/journey-own-arch.log)"
    if grep -q "\[po\]" /tmp/journey-own-arch.log; then
        fail "archiver touched the partitioner's row (po)"; tail -5 /tmp/journey-own-arch.log
    else
        pass "archiver ignored the partitioner's row (po)"
    fi

    # Partitioner run: reconciles its partition-only row (own.po), never the
    # archiver's tiered row (own.tier), and no longer aborts on a foreign row.
    printf 'postgres: { dsn: "%s" }\n' "$dsn" > /tmp/journey-own-part.yaml
    "$PARTITIONER" --config /tmp/journey-own-part.yaml >/tmp/journey-own-part.log 2>&1 || true
    if grep -q "only valid in tiered mode" /tmp/journey-own-part.log; then
        fail "partitioner still choked on the tiered row"; tail -5 /tmp/journey-own-part.log
    else
        pass "partitioner did not choke on the tiered row"
    fi
    assert_contains "partitioner reconciled its own partition-only table" "[po] reconciled" "$(cat /tmp/journey-own-part.log)"
    if grep -q "\[tier\]" /tmp/journey-own-part.log; then
        fail "partitioner touched the archiver's row (tier)"; tail -5 /tmp/journey-own-part.log
    else
        pass "partitioner ignored the archiver's row (tier)"
    fi

    # Clean up so the SHARED coldfront.partition_config stays clean for later stories.
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE schema_name='own'; DROP SCHEMA own CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — Enterprise privilege model: a NON-superuser app role, onboarded with a
# single coldfront.grant_app_access() call, reads AND writes the tiered view
# transparently — no superuser, no pg_*_server_files, no per-session setup.
# Vanilla exercises the hot-heap + identity-sequence grants (pg_duckdb checks the
# INVOKER's privilege on the hot heap) and the advisory-lock cold write. --mesh
# adds cross-node read + a cold write driven through the SECURITY DEFINER R-A
# bakery FROM A PEER — the role and its grants replicate via Spock DDL, so
# onboarding runs ONCE on one node and the whole mesh inherits it.
# ───────────────────────────────────────────────────────────────────────────
story_app_privilege() {
    step "App privilege: non-superuser cold I/O via one-call grant_app_access"
    local total; total=$(q "$HOST" "SELECT count(*) FROM events;")
    q "$HOST" "CREATE ROLE japp NOSUPERUSER LOGIN PASSWORD 'x';" >/dev/null 2>&1
    local onboard; onboard=$(q_may "$HOST" "SELECT coldfront.grant_app_access('japp');")
    assert_eq "grant_app_access('japp') succeeds (one call)" "" "$(echo "$onboard" | grep -iE 'error' || true)"
    assert_eq "app role is NOT a superuser"           "off" "$(q "$HOST" "SET ROLE japp; SELECT current_setting('is_superuser');" | tail -1)"
    assert_eq "app role lacks pg_read_server_files"   "f"   "$(q "$HOST" "SELECT pg_has_role('japp','pg_read_server_files','MEMBER');")"
    assert_eq "app role reads tiered hot+cold (== superuser)" "$total" "$(q "$HOST" "SET ROLE japp; SELECT count(*) FROM events;" | tail -1)"
    q "$HOST" "SET ROLE japp; INSERT INTO events (ts,status,data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '17 days' + interval '9 hours','japp_priv','{}');" >/dev/null 2>&1
    assert_eq "app role cold write landed (read-your-write)" "1" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='japp_priv';")"
    q "$HOST" "DELETE FROM events WHERE status='japp_priv';" >/dev/null 2>&1

    if [ "$MESH" = 1 ] && [ -n "${PEERS:-}" ]; then
        local PARR p1; read -ra PARR <<< "$PEERS"; p1="${PARR[0]}"
        assert_eq "app role + grants replicated to peer $p1 (Spock DDL, onboarded once)" "t" \
            "$(q "$p1" "SELECT (rolname IS NOT NULL AND pg_has_role('japp','coldfront_duckdb','MEMBER')) FROM pg_roles WHERE rolname='japp';" | tail -1)"
        assert_eq "peer $p1: non-superuser reads tiered hot+cold cross-node" "$total" "$(q "$p1" "SET ROLE japp; SELECT count(*) FROM events;" | tail -1)"
        q "$p1" "SET ROLE japp; INSERT INTO events (ts,status,data) VALUES (date_trunc('month',now()) - interval '4 months' + interval '18 days' + interval '9 hours','japp_mesh','{}');" >/dev/null 2>&1
        assert_eq "peer $p1: non-superuser mesh cold write (SECURITY DEFINER R-A bakery) visible on db1" "1" \
            "$(q "$HOST" "SELECT count(*) FROM events WHERE status='japp_mesh';")"
        q "$HOST" "DELETE FROM events WHERE status='japp_mesh';" >/dev/null 2>&1
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Story — TC-022: a deliberately wrong S3 endpoint causes Phase 2 to fail.
# The archiver connects to Postgres and Lakekeeper fine (phases 0-1) but the
# bulk-export (phase 2) can't reach the object store and exits non-zero with
# a connection error naming the bad host. Skipped for non-s3 backends where
# the static-endpoint knob isn't meaningful.
# ───────────────────────────────────────────────────────────────────────────
story_wrong_s3_endpoint() {
    step "TC-022: wrong S3 endpoint → archiver Phase 2 fails with connection error"
    if [ "$BACKEND" != s3 ]; then
        note "TC-022: requires s3 backend (current: $BACKEND) — skipped"; return
    fi
    qf "$HOST" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS wrong_ep_tbl (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);
DO $do$
DECLARE m date;
BEGIN
    m := (date_trunc('month', now()) - interval '2 months')::date;
    EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF wrong_ep_tbl FOR VALUES FROM (%L) TO (%L)',
                   'wrong_ep_tbl_p_' || to_char(m, 'YYYY_MM'), m, (m + interval '1 month'));
END $do$;
INSERT INTO wrong_ep_tbl (ts)
    SELECT date_trunc('month', now()) - interval '2 months' + interval '7 days' + (i * interval '1 hour')
    FROM generate_series(1, 10) i;
EOSQL
    local ret_days; ret_days=$(( ( $(date -u +%s) - $(date -u -d "$(date -u +%Y-%m-01) -1 month" +%s) ) / 86400 ))
    if ! "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table wrong_ep_tbl \
            --period monthly --hot-period "${ret_days} days" >/tmp/journey-wrong-ep.log 2>&1; then
        fail "TC-022: register wrong_ep_tbl — see /tmp/journey-wrong-ep.log"; tail -5 /tmp/journey-wrong-ep.log; return
    fi
    cat > /tmp/journey-wrong-ep.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "${WAREHOUSE}"
  lakekeeper_endpoint: "http://${LK_IP}:8181/catalog"
  namespace: "default"
s3:
  endpoint: "wronghost:8333"
  region: "us-east-1"
  access_key: "admin"
  secret_key: "adminsecret"
EOF
    if "$ARCHIVER" --config /tmp/journey-wrong-ep.yaml >>/tmp/journey-wrong-ep.log 2>&1; then
        fail "TC-022: archiver should have failed with a bad S3 endpoint"
    else
        if grep -qi "wronghost" /tmp/journey-wrong-ep.log; then
            pass "TC-022: archiver exited non-zero; Phase 2 failed (named bad host: wronghost)"
        else
            fail "TC-022: archiver failed but expected 'wronghost' in error"; tail -5 /tmp/journey-wrong-ep.log
        fi
    fi
    # Clean up regardless of pass/fail so partition_config stays tidy for later stories.
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE table_name='wrong_ep_tbl';" >/dev/null 2>&1
    q "$HOST" "DROP TABLE IF EXISTS public.wrong_ep_tbl CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — TC-024: an empty (0-row) partition archives cleanly through all six
# phases (0–5). The partition must be created in the PUBLIC schema with an
# explicit prefix — the coldfront user's search_path defaults to
# coldfront,public, so a bare CREATE TABLE lands in the coldfront schema and
# the PK check (nspname='public') would find 0 primary-key columns.
# ───────────────────────────────────────────────────────────────────────────
story_empty_partition() {
    step "TC-024: 0-row partition archives cleanly (all 6 phases, exit 0)"
    # In mesh mode cleanupAlreadyArchived fans out DETACH CONCURRENTLY to Spock
    # peers via their interface DSN; those hostnames are not resolvable from the
    # archiver host in the journey config. Skip here — same reason as
    # story_partitioner_fk_drop.
    if [ "$MESH" = 1 ]; then
        note "TC-024: skipping in mesh mode (cleanupAlreadyArchived peer detach requires resolvable peer DSNs)"
        return
    fi
    # Create an empty partition for now-12mo in public schema. That month is well
    # past the hot_period cutoff so the archiver picks it up as a cold partition.
    local m12; m12=$(date -u -d "$(date -u +%Y-%m-01) -12 months" +%Y-%m-%d)
    local m12_end; m12_end=$(date -u -d "$m12 +1 month" +%Y-%m-%d)
    local pname; pname="events_p_$(date -u -d "$m12" +%Y_%m)"
    q "$HOST" "CREATE TABLE IF NOT EXISTS public.${pname} PARTITION OF public._events FOR VALUES FROM ('${m12}') TO ('${m12_end}');" >/dev/null
    assert_eq "TC-024: empty partition created (0 rows)" "0" \
        "$(q "$HOST" "SELECT count(*) FROM public.${pname};")"
    if "$ARCHIVER" --config /tmp/journey-archiver.yaml >/tmp/journey-empty-part.log 2>&1; then
        pass "TC-024: archiver completed with empty partition (exit 0)"
    else
        fail "TC-024: archiver failed on empty partition — see /tmp/journey-empty-part.log"; tail -8 /tmp/journey-empty-part.log
    fi
    # Phase 5 drops the partition from PG after cutover.
    assert_eq "TC-024: empty partition archived and dropped from PG" "0" \
        "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='${pname}' AND relnamespace='public'::regnamespace;")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — TC-040: renaming the hot table (_events → _events_renamed) triggers
# the coldfront DDL hook, which updates coldfront.tiered_views.hot_table and
# rebuilds the transparent UNION-ALL view. DML via the view must route to the
# renamed table without error, and the table rename back to _events restores
# the registry. Leaves the table and registry in the original state.
# ───────────────────────────────────────────────────────────────────────────
story_rename_hot_table() {
    step "TC-040: rename hot table updates registry; DML via view works after rename"
    assert_eq "precondition: events is a view" "v" \
        "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='events' AND relnamespace='public'::regnamespace;")"
    assert_eq "precondition: _events is partitioned" "p" \
        "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='_events' AND relnamespace='public'::regnamespace;")"

    q "$HOST" "ALTER TABLE public._events RENAME TO _events_renamed;" >/dev/null
    local hot_renamed; hot_renamed=$(q "$HOST" "SELECT hot_table FROM coldfront.tiered_views WHERE schema_name='public' AND relname='events';")
    assert_contains "TC-040: tiered_views.hot_table updated to _events_renamed" "_events_renamed" "$hot_renamed"

    # INSERT via the view must route to the renamed hot table. Use a timestamp
    # in the CURRENT month (5 days in) — this partition was premade by
    # story_partitioner_after_swap and is unambiguously above any cutoff.
    q "$HOST" "INSERT INTO events (ts, status, data) VALUES (date_trunc('month',now()) + interval '5 days', 'rename_chk', '{}');" >/dev/null
    assert_eq "TC-040: row landed in _events_renamed after hot table rename" "1" \
        "$(q "$HOST" "SELECT count(*) FROM public._events_renamed WHERE status='rename_chk';")"
    q "$HOST" "DELETE FROM public._events_renamed WHERE status='rename_chk';" >/dev/null

    # Rename back so later stories find _events as expected.
    q "$HOST" "ALTER TABLE public._events_renamed RENAME TO _events;" >/dev/null
    local hot_restored; hot_restored=$(q "$HOST" "SELECT hot_table FROM coldfront.tiered_views WHERE schema_name='public' AND relname='events';")
    assert_eq "TC-040: tiered_views.hot_table restored to _events" "public._events" "$hot_restored"
    pass "TC-040: hot table renamed and restored, registry updated both ways"
}

# ───────────────────────────────────────────────────────────────────────────
# Story — TC-052: partitioner set --retention updates the retention_period
# field in partition_config. Uses an isolated schema so the shared events row
# is not disturbed.
# ───────────────────────────────────────────────────────────────────────────
story_partitioner_set_retention() {
    step "TC-052: partitioner set --retention updates partition_config"
    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    q "$HOST" "CREATE SCHEMA IF NOT EXISTS setret;
               CREATE TABLE IF NOT EXISTS setret.logs (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL, PRIMARY KEY (id, ts)) PARTITION BY RANGE (ts);" >/dev/null
    if ! "$PARTITIONER" register --dsn "$dsn" --schema setret --table logs \
            --period monthly --retention "12 months" >/tmp/journey-setret.log 2>&1; then
        fail "TC-052: register setret.logs — see /tmp/journey-setret.log"; tail -5 /tmp/journey-setret.log
        q "$HOST" "DROP SCHEMA setret CASCADE;" >/dev/null 2>&1; return
    fi
    assert_eq "TC-052: initial retention is 1 year" "1 year" \
        "$(q "$HOST" "SELECT retention_period::text FROM coldfront.partition_config WHERE schema_name='setret' AND table_name='logs';")"
    if "$PARTITIONER" set --dsn "$dsn" --schema setret --table logs \
            --retention "24 months" >>/tmp/journey-setret.log 2>&1; then
        pass "TC-052: partitioner set --retention succeeded"
    else
        fail "TC-052: partitioner set --retention failed — see /tmp/journey-setret.log"; tail -5 /tmp/journey-setret.log
    fi
    assert_eq "TC-052: retention updated to 2 years" "2 years" \
        "$(q "$HOST" "SELECT retention_period::text FROM coldfront.partition_config WHERE schema_name='setret' AND table_name='logs';")"
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE schema_name='setret'; DROP SCHEMA setret CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — TC-053: disabling a table in partition_config silently excludes it
# from the archiver run (no [events] in the log, no "skipping" message). Re-
# enabling it restores normal processing. The events table is used since it is
# already tiered and its [events] log token is unambiguous.
# ───────────────────────────────────────────────────────────────────────────
story_partitioner_disable_enable() {
    step "TC-053: disable silently excludes from archiver; enable restores it"
    cat > /tmp/journey-disen.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "${WAREHOUSE}"
  lakekeeper_endpoint: "http://${LK_IP}:8181/catalog"
  namespace: "default"
$(storage_yaml)
EOF
    if "$ARCHIVER" set --config /tmp/journey-disen.yaml --table events --disable >/tmp/journey-disen.log 2>&1; then
        pass "TC-053: archiver set --disable succeeded"
    else
        fail "TC-053: archiver set --disable failed — see /tmp/journey-disen.log"; tail -5 /tmp/journey-disen.log
    fi
    assert_eq "TC-053: events disabled in partition_config" "f" \
        "$(q "$HOST" "SELECT enabled FROM coldfront.partition_config WHERE schema_name='public' AND table_name='events';")"
    "$ARCHIVER" --config /tmp/journey-disen.yaml >>/tmp/journey-disen.log 2>&1 || true
    if grep -q "\[events\]" /tmp/journey-disen.log; then
        fail "TC-053: [events] appeared in archiver log while disabled (should be silently excluded)"
    else
        pass "TC-053: [events] absent from archiver log (silently excluded via WHERE enabled)"
    fi

    if "$ARCHIVER" set --config /tmp/journey-disen.yaml --table events --enable >>/tmp/journey-disen.log 2>&1; then
        pass "TC-053: archiver set --enable succeeded"
    else
        fail "TC-053: archiver set --enable failed — see /tmp/journey-disen.log"; tail -5 /tmp/journey-disen.log
    fi
    assert_eq "TC-053: events re-enabled in partition_config" "t" \
        "$(q "$HOST" "SELECT enabled FROM coldfront.partition_config WHERE schema_name='public' AND table_name='events';")"
    "$ARCHIVER" --config /tmp/journey-disen.yaml >>/tmp/journey-disen.log 2>&1 || true
    if grep -q "\[events\]" /tmp/journey-disen.log; then
        pass "TC-053: [events] present in archiver log after re-enable"
    else
        fail "TC-053: [events] absent from archiver log even after re-enable"; tail -8 /tmp/journey-disen.log
    fi
    # Ensure events is enabled regardless of test outcome (safety net for later stories).
    "$ARCHIVER" set --config /tmp/journey-disen.yaml --table events --enable >/dev/null 2>&1 || true
}

# ───────────────────────────────────────────────────────────────────────────
# Story — TC-054: remove unregisters a table (deletes its partition_config row)
# while leaving the table itself intact. Uses an isolated schema so the shared
# partition_config is not permanently modified.
# ───────────────────────────────────────────────────────────────────────────
story_partitioner_remove() {
    step "TC-054: remove unregisters a table; the table itself is left intact"
    local dsn="host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
    q "$HOST" "CREATE SCHEMA IF NOT EXISTS rmtest;
               CREATE TABLE IF NOT EXISTS rmtest.logs (id bigint GENERATED ALWAYS AS IDENTITY, ts timestamptz NOT NULL, PRIMARY KEY (id, ts)) PARTITION BY RANGE (ts);" >/dev/null
    if ! "$PARTITIONER" register --dsn "$dsn" --schema rmtest --table logs \
            --period monthly --retention "12 months" >/tmp/journey-rmtest.log 2>&1; then
        fail "TC-054: register rmtest.logs — see /tmp/journey-rmtest.log"; tail -5 /tmp/journey-rmtest.log
        q "$HOST" "DROP SCHEMA rmtest CASCADE;" >/dev/null 2>&1; return
    fi
    assert_eq "TC-054: row present before remove" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE schema_name='rmtest' AND table_name='logs';")"
    if "$PARTITIONER" remove --dsn "$dsn" --schema rmtest --table logs >>/tmp/journey-rmtest.log 2>&1; then
        pass "TC-054: remove succeeded"
    else
        fail "TC-054: remove failed — see /tmp/journey-rmtest.log"; tail -5 /tmp/journey-rmtest.log
    fi
    assert_eq "TC-054: partition_config row gone after remove" "0" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE schema_name='rmtest' AND table_name='logs';")"
    assert_eq "TC-054: table still exists after remove" "p" \
        "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='logs' AND relnamespace='rmtest'::regnamespace;")"
    q "$HOST" "DROP SCHEMA rmtest CASCADE;" >/dev/null 2>&1
}

# ───────────────────────────────────────────────────────────────────────────
# Story — TC-071: a PARTITION BY RANGE (col1, col2) table is rejected at
# archive time with a clear error. The PK check at register time passes (the
# PK covers every partition-key column), but the archiver's single scalar
# watermark cannot express independent per-dimension thresholds, so it rejects
# composite partition keys before attempting any Iceberg work.
# ───────────────────────────────────────────────────────────────────────────
story_composite_key_rejected() {
    step "TC-071: composite partition key RANGE (region, ts) rejected at archive time"
    q "$HOST" "CREATE TABLE IF NOT EXISTS public.composite_part (
        id bigint, region text NOT NULL, ts timestamptz NOT NULL,
        PRIMARY KEY (id, region, ts)
    ) PARTITION BY RANGE (region, ts);" >/dev/null
    # register succeeds: validatePKSuperset passes because the PK covers all
    # partition-key columns. The composite-key guard fires later in the archiver.
    if "$ARCHIVER" register --config /tmp/journey-archiver.yaml --table composite_part \
            --period monthly --hot-period "1 month" --retention "5 years" >/tmp/journey-cp-reg.log 2>&1; then
        pass "TC-071: register composite_part succeeded (PK covers partition key)"
    else
        fail "TC-071: register composite_part failed unexpectedly — see /tmp/journey-cp-reg.log"
        tail -3 /tmp/journey-cp-reg.log
        q "$HOST" "DROP TABLE IF EXISTS public.composite_part;" >/dev/null 2>&1; return
    fi
    assert_eq "TC-071: composite_part row written to partition_config" "1" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.partition_config WHERE table_name='composite_part';")"
    # Archive run: detectPartitionColumns sees two columns and exits non-zero
    # before any Iceberg or S3 work is attempted.
    if "$ARCHIVER" --config /tmp/journey-archiver.yaml >/tmp/journey-cp.log 2>&1; then
        fail "TC-071: archiver should have rejected the composite partition key"
    else
        if grep -qi "multi-column partition keys are not supported" /tmp/journey-cp.log; then
            pass "TC-071: archiver rejects composite partition key (multi-column guard)"
        else
            fail "TC-071: archiver failed but wrong reason"; tail -5 /tmp/journey-cp.log
        fi
    fi
    # Clean up so partition_config stays tidy for any subsequent stories.
    q "$HOST" "DELETE FROM coldfront.partition_config WHERE table_name='composite_part';" >/dev/null 2>&1
    q "$HOST" "DROP TABLE IF EXISTS public.composite_part;" >/dev/null 2>&1
}

# ── orchestrate ────────────────────────────────────────────────────────────
# Setup is shared. The story set then branches on mode: tiered exercises the
# hot+cold partitioned path; decoupled exercises the all-Iceberg wrapper. (The
# tiered stories assume the partitioned `events` table and don't apply to an
# iceberg-only relation, and vice-versa.)
story_setup
[ "$MESH" = 1 ] && story_mesh_substrate          # bakery substrate replicates in all directions
[ "$MESH" = 1 ] && story_mesh_partition_config   # config table replicates in all directions
[ "$MESH" = 1 ] && story_mesh_partition_ddl      # partition lifecycle DDL replicates (verify-before-bench)
if [ "$MODE" = "tiered" ]; then
    story_provision_tiered
    [ "$MESH" = 1 ] && story_mesh_tiered    # cross-node tiered, while hot+cold coexist
    story_reads
    story_types
    story_writes
    story_compaction        # iceberg-go RewriteDataFiles, now that the manifest-list
                            # format-version interop patch makes the cold tier's
                            # manifests iceberg-go-readable
    story_maintenance       # iceberg-go ExpireSnapshots + DeleteOrphanFiles — reclaim the
                            # snapshot/small-file bloat compaction leaves (Lakekeeper can't)
    story_writes_plpgsql
    story_app_privilege          # non-superuser onboarding + cold I/O (mesh: cross-node + SD bakery)
    story_mixed_concurrency
    story_ddl
    story_blocks
    story_ext_requires
    story_ext_directory_guc
    story_concurrency
    story_concurrent_writers
    story_txn
    story_coexist
    story_cold_retention
    story_tiered_twolevel
    story_partitioner_idmode
    story_partitioner_multitable
    story_partitioner_after_swap
    story_fk_constraint
    story_archiver_rollback
    story_partitioner_fk_drop
    story_register_cli
    story_partition_config_ownership   # each binary loads only its own rows
    story_wrong_s3_endpoint            # TC-022: bad S3 endpoint → Phase 2 connection error
    story_empty_partition              # TC-024: 0-row partition archives cleanly
    story_rename_hot_table             # TC-040: hot table rename updates registry + DML
    story_partitioner_set_retention    # TC-052: set --retention updates partition_config
    story_partitioner_disable_enable   # TC-053: disable silently excludes; enable restores
    story_partitioner_remove           # TC-054: remove unregisters; table intact
    story_composite_key_rejected       # TC-071: RANGE (col1, col2) rejected at archive time
else
    story_provision_decoupled
    story_decoupled_crud
    story_decoupled_plpgsql
    story_decoupled_concurrency
    story_decoupled_ryw
fi
[ "$MESH" = 1 ] && [ "$MODE" = decoupled ] && story_mesh   # tiered+mesh runs story_mesh_tiered (above)
[ "$MESH" = 1 ] && story_mesh_multiwriter   # >1 cold writer/node cross-node (tiered: events, decoupled: iceonly)
[ -n "$STANDBY" ]    && story_standby_reads

summary
