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
ARCHIVER="${ARCHIVER:-./bin/archiver}"
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
  --archiver) ARCHIVER="$2"; shift 2;;
  *) echo "journey.sh: unknown arg $1"; exit 2;;
esac; done
[ -n "$HOST" ] || { echo "journey.sh: --host required"; exit 2; }

step "JOURNEY  host=$HOST  mode=$MODE  mesh=$MESH  standby=${STANDBY:-none}"

# ───────────────────────────────────────────────────────────────────────────
# Story 1 — Setup: extensions, S3 secret, arm the login attach.
# (GUCs warehouse/lakekeeper_endpoint live in the node's postgresql.conf; the
#  topology brought up Lakekeeper + the warehouse already.)
# ───────────────────────────────────────────────────────────────────────────
story_setup() {
    step "1. Setup (extensions, S3 secret, arm login-attach)"
    qf "$HOST" <<EOSQL >/dev/null
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
-- iceberg/avro: the patched binary is shipped in the image + autoloaded on
-- ATTACH (TYPE ICEBERG) with allow_unsigned; no install_extension needed.
DROP SERVER IF EXISTS simple_s3_secret CASCADE;
SELECT duckdb.create_simple_secret('s3','admin','adminsecret','','us-east-1','path','','${SW_IP}:8333','','','false');
SELECT coldfront.arm_login_attach();
EOSQL
    local ext; ext=$(q "$HOST" "SELECT count(*) FROM pg_extension WHERE extname IN ('pg_duckdb','coldfront');")
    assert_eq "extensions present" "2" "$ext"
    local armed; armed=$(q "$HOST" "SELECT attach_on_login FROM coldfront.runtime_config LIMIT 1;")
    assert_eq "login-attach armed" "t" "$armed"
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
CREATE TABLE IF NOT EXISTS p_2026_01 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS p_2026_02 PARTITION OF events FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS p_2026_03 PARTITION OF events FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS p_2026_04 PARTITION OF events FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
INSERT INTO events (ts, status, data) SELECT '2026-01-15'::timestamptz + (i*interval '1 hour'), 'ok', '{"m":"jan"}'::jsonb FROM generate_series(1,100) i;
INSERT INTO events (ts, status, data) SELECT '2026-02-10'::timestamptz + (i*interval '1 hour'), 'ok', '{"m":"feb"}'::jsonb FROM generate_series(1,80) i;
INSERT INTO events (ts, status, data) SELECT '2026-03-05'::timestamptz + (i*interval '1 hour'), 'ok', '{"m":"mar"}'::jsonb FROM generate_series(1,60) i;
INSERT INTO events (ts, status, data) SELECT '2026-04-01'::timestamptz + (i*interval '1 hour'), 'ok', '{"m":"apr"}'::jsonb FROM generate_series(1,40) i;
EOSQL
    local seeded; seeded=$(q "$HOST" "SELECT count(*) FROM public.events;")
    assert_eq "seeded 280 rows (pre-archive, plain table)" "280" "$seeded"

    # Pin the hot/cold cutoff to a FIXED date (2026-04-15) regardless of the wall
    # clock. The archiver (correctly) computes cutoff = now − retention, so set
    # retention = now − 2026-04-15: the Apr partition stays hot and Jan–Mar cold
    # against the fixed seed dates above, deterministically, without touching the
    # archiver. (A literal "1 month" drifts the cutoff across the Apr/May boundary
    # as the clock advances — the day it crosses, Apr flips hot→cold and the
    # hot-tier write assertions break.)
    local ret_days=$(( ( $(date -u +%s) - $(date -u -d '2026-04-15' +%s) ) / 86400 ))
    cat > /tmp/journey-archiver.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "${WAREHOUSE}"
  lakekeeper_endpoint: "http://${LK_IP}:8181/catalog"
  namespace: "default"
s3:
  endpoint: "${SW_IP}:8333"
  region: "us-east-1"
  access_key: "admin"
  secret_key: "adminsecret"
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      hot_period: "${ret_days} days"
EOF
    if "$ARCHIVER" --config /tmp/journey-archiver.yaml >/tmp/journey-archiver.log 2>&1; then
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
# The retention cutoff (2026-02-01) drops the Jan cold rows and keeps Feb/Mar.
# Runs last so it doesn't perturb earlier stories' counts; jan_before is read
# dynamically so the row-math holds regardless of what else landed in cold.
# ───────────────────────────────────────────────────────────────────────────
story_cold_retention() {
    step "Cold retention: drop Iceberg data past retention_period"
    local before jan_before
    before=$(q "$HOST" "SELECT count(*) FROM events;")
    jan_before=$(q "$HOST" "SELECT count(*) FROM events WHERE ts >= '2026-01-01' AND ts < '2026-02-01';")
    assert_gt "Jan cold rows present before retention" "0" "$jan_before"

    local ret_days ret_long
    ret_days=$(( ( $(date -u +%s) - $(date -u -d '2026-04-15' +%s) ) / 86400 ))   # hot cutoff  = 2026-04-15
    ret_long=$(( ( $(date -u +%s) - $(date -u -d '2026-02-01' +%s) ) / 86400 ))    # drop cutoff = 2026-02-01
    cat > /tmp/journey-coldret.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "${WAREHOUSE}"
  lakekeeper_endpoint: "http://${LK_IP}:8181/catalog"
  namespace: "default"
s3:
  endpoint: "${SW_IP}:8333"
  region: "us-east-1"
  access_key: "admin"
  secret_key: "adminsecret"
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      hot_period: "${ret_days} days"
      retention_period: "${ret_long} days"
EOF
    if "$ARCHIVER" --config /tmp/journey-coldret.yaml >/tmp/journey-coldret.log 2>&1; then
        pass "archiver cold-retention run completed"
    else
        fail "archiver cold-retention run — see /tmp/journey-coldret.log"; tail -5 /tmp/journey-coldret.log
    fi
    assert_eq "Jan cold rows dropped by retention" "0" \
        "$(q "$HOST" "SELECT count(*) FROM events WHERE ts >= '2026-01-01' AND ts < '2026-02-01';")"
    assert_gt "Feb cold rows retained" "0" \
        "$(q "$HOST" "SELECT count(*) FROM events WHERE ts >= '2026-02-01' AND ts < '2026-03-01';")"
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
    # Retry the provision until the wrapper view exists: on a cold warehouse the
    # CREATE SCHEMA (namespace) and the immediately-following CREATE TABLE can
    # race in Lakekeeper (the table POST lands before the namespace resolves →
    # 405), and create_iceberg_table is one transaction so it rolls back. The
    # retry's CREATE SCHEMA IF NOT EXISTS finds the settled namespace.
    local i
    for i in 1 2 3 4 5; do
        q_may "$HOST" "SELECT coldfront.create_iceberg_table('public','iceonly','[{\"name\":\"id\",\"type\":\"bigint\"},{\"name\":\"ts\",\"type\":\"timestamptz\"},{\"name\":\"status\",\"type\":\"text\"},{\"name\":\"data\",\"type\":\"jsonb\"}]'::jsonb);" >/dev/null 2>&1
        [ "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='iceonly' AND relkind='v' AND relnamespace='public'::regnamespace;")" = "1" ] && break
        sleep 2
    done
    assert_eq "iceonly wrapper view created" "v" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='iceonly' AND relnamespace='public'::regnamespace;")"
    assert_eq "iceberg-only registry row present" "1" "$(q "$HOST" "SELECT count(*) FROM coldfront.tiered_views WHERE is_iceberg_only AND iceberg_table='ice.default.iceonly';")"
    assert_eq "no hot table for iceberg-only view" "" "$(q "$HOST" "SELECT hot_table FROM coldfront.tiered_views WHERE iceberg_table='ice.default.iceonly';")"
}

# ───────────────────────────────────────────────────────────────────────────
# Decoupled CRUD — every DML on the wrapper view is rewritten by the C hook to
# a single duckdb.raw_query against Iceberg (no INSTEAD OF trigger). Covers the
# INSERT shapes, jsonb surfacing, UPDATE, DELETE.
# ───────────────────────────────────────────────────────────────────────────
story_decoupled_crud() {
    step "6. Decoupled CRUD (INSERT/SELECT/UPDATE/DELETE → Iceberg via the hook)"
    local O; O=$(qf "$HOST" <<'EOSQL'
INSERT INTO iceonly VALUES (1,'2026-05-01 10:00:00+00','s1','{"a":1}'),(2,'2026-05-01 10:00:01+00','s2','{"a":2}');
SELECT 'CNT:'||count(*) FROM iceonly;
SELECT 'JSONTYPE:'||pg_typeof(data)::text FROM iceonly LIMIT 1;
SELECT 'JSON:'||(data->>'a') FROM iceonly WHERE id=1;
INSERT INTO iceonly VALUES (10,'2026-05-01 10:01:00+00','multi','{}'),(11,'2026-05-01 10:01:01+00','multi','{}'),(12,'2026-05-01 10:01:02+00','multi','{}');
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
        q "$HOST" "INSERT INTO iceonly VALUES (${k}00,'2026-06-0${k} 10:00:00+00','conc','{}');" >/tmp/journey-conc.$k 2>&1 &
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
INSERT INTO iceonly VALUES (99,'2026-05-01 11:00:00+00','in_tx','{}');
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
SELECT 'RO_HOT:'   || count(*) FROM events WHERE ts >= '2026-03-01';
SELECT 'RO_COLD:'  || count(*) FROM events WHERE ts  < '2026-03-01';
SELECT 'JSONB_TYPE:'   || pg_typeof(data)::text FROM events LIMIT 1;
SELECT 'JSONB_COLD_M:' || (data->>'m') FROM events WHERE ts < '2026-03-01' AND status='ok' ORDER BY ts LIMIT 1;
SELECT 'JSONB_HOT_M:'  || (data->>'m') FROM events WHERE ts >= '2026-03-01' AND status='ok' ORDER BY ts LIMIT 1;
EOSQL
)
    assert_eq "total rows (hot+cold via view)" "280"  "$(extract RO_TOTAL "$O")"
    assert_eq "rows ts>=2026-03-01 (Mar cold + Apr hot)" "100" "$(extract RO_HOT "$O")"
    assert_eq "cold rows ts<2026-03-01 (Jan+Feb, read from Iceberg)" "180" "$(extract RO_COLD "$O")"
    assert_eq "data surfaces as json" "json" "$(extract JSONB_TYPE "$O")"
    assert_eq "json cold round-trip"  "jan"  "$(extract JSONB_COLD_M "$O")"
    assert_eq "json hot round-trip"   "mar"  "$(extract JSONB_HOT_M "$O")"
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
CREATE TABLE IF NOT EXISTS typed_2026_01 PARTITION OF typed FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS typed_2026_04 PARTITION OF typed FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
-- inet/cidr are intentionally absent: pg_duckdb cannot process inet (Oid 869)
-- in an Iceberg-backed query, so they are rejected at provisioning (asserted
-- below). IP data is stored as text instead.
INSERT INTO typed (ts,c_int,c_small,c_real,c_dbl,c_bool,c_date,c_uuid,c_txt,c_vc,c_bytea,c_num,c_jsonb)
VALUES ('2026-01-10', 42, 7, 1.5, 2.5, true, '2026-01-10', '11111111-1111-1111-1111-111111111111','hi','abc','\xdeadbeef'::bytea, 123.45, '{"k":1}');
INSERT INTO typed (ts,c_int,c_small,c_real,c_dbl,c_bool,c_date,c_uuid,c_txt,c_vc,c_bytea,c_num,c_jsonb)
VALUES ('2026-04-10', 42, 7, 1.5, 2.5, true, '2026-01-10', '11111111-1111-1111-1111-111111111111','hi','abc','\xdeadbeef'::bytea, 123.45, '{"k":1}');
EOSQL
    # Same fixed-cutoff pin as events (cutoff = 2026-04-15): typed's Jan partition
    # cold, Apr hot, deterministically.
    local ret_days=$(( ( $(date -u +%s) - $(date -u -d '2026-04-15' +%s) ) / 86400 ))
    cat > /tmp/journey-typed.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog", namespace: "default" }
s3:       { endpoint: "${SW_IP}:8333", region: "us-east-1", access_key: "admin", secret_key: "adminsecret" }
archiver: { tables: [ { source_table: typed, partition_period: monthly, hot_period: "${ret_days} days" } ] }
EOF
    "$ARCHIVER" --config /tmp/journey-typed.yaml >/tmp/journey-typed.log 2>&1 \
        && pass "typed table archived (Jan → cold)" || { fail "typed archive — see /tmp/journey-typed.log"; tail -5 /tmp/journey-typed.log; }
    local O; O=$(qf "$HOST" <<'EOSQL'
SELECT 'COLD_NUM:'  || c_num::text   FROM typed WHERE ts < '2026-02-01';
SELECT 'COLD_UUID:' || c_uuid::text  FROM typed WHERE ts < '2026-02-01';
SELECT 'COLD_SMALL:'|| c_small::text FROM typed WHERE ts < '2026-02-01';
SELECT 'COLD_BOOL:' || c_bool::text  FROM typed WHERE ts < '2026-02-01';
-- bytea: encode()/hex() aren't exposed through pg_duckdb and its ::text render
-- carries backslashes that the shell's echo mangles. Compare the cold value to
-- the hot source value as a bool — backslash-free and verifies content fidelity.
SELECT 'BYTEAEQ:' || (c_bytea = (SELECT c_bytea FROM typed WHERE ts >= '2026-04-01' LIMIT 1))::text FROM typed WHERE ts < '2026-02-01';
-- Native byte count: '\xdeadbeef' is 4 bytes. A stringification bug would store
-- the 10-char text '\xdeadbeef' (10 bytes). Independent of the equality check.
SELECT 'BYTEALEN:' || octet_length(c_bytea)::text FROM typed WHERE ts < '2026-02-01';
SELECT 'HOT_NUM:'   || c_num::text   FROM typed WHERE ts >= '2026-04-01';
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
VALUES ('2026-01-20', 1,1,1,1,true,'2026-01-20','22222222-2222-2222-2222-222222222222','x','y','\xcafe'::bytea, 1.0, '{}');
SELECT 'COLDINS_LEN:' || octet_length(c_bytea)::text FROM typed
  WHERE c_uuid = '22222222-2222-2222-2222-222222222222' AND ts < '2026-02-01';
EOSQL
)
    assert_eq "cold-INSERT-via-trigger bytea stored natively (2 bytes)" "2" "$(extract COLDINS_LEN "$CI")"

    # inet/cidr are rejected at provisioning — no cast makes them readable
    # through pg_duckdb once the table is Iceberg-backed. Match the specific
    # rejection text, not just the type name (which the input itself contains).
    local IE; IE=$(q_may "$HOST" "SELECT coldfront.create_iceberg_table('public','ip_reject','[{\"name\":\"a\",\"type\":\"inet\"}]'::jsonb);")
    assert_contains "inet rejected at provisioning" "store IP data as text" "$IE"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 6 — Writes via the view (proven assertions from run-ci-local).
# ───────────────────────────────────────────────────────────────────────────
story_writes() {
    step "6. Writes via view (hot/cold INSERT-UPDATE-DELETE, dual-tier)"
    local O; O=$(qf "$HOST" <<'EOSQL'
INSERT INTO events (ts, status, data) VALUES ('2026-04-09 12:00+00','ci_hot_ins','{}');
SELECT 'RW_HOT_INS:'  || count(*) FROM _events WHERE status='ci_hot_ins';
INSERT INTO events (ts, status, data) VALUES ('2026-01-15 12:00+00','ci_cold_ins','{}');
SELECT 'RW_COLD_INS:' || count(*) FROM events WHERE status='ci_cold_ins';
UPDATE events SET status='ci_hot_upd' WHERE ts='2026-04-09 12:00:00+00' AND status='ci_hot_ins';
SELECT 'RW_HOT_UPD:'  || status FROM _events WHERE ts='2026-04-09 12:00:00+00';
UPDATE events SET status='ci_cold_upd' WHERE ts='2026-01-15 01:00:00+00';
SELECT 'RW_COLD_UPD:' || count(*) FROM events WHERE status='ci_cold_upd';
DELETE FROM events WHERE ts='2026-04-09 12:00:00+00' AND status='ci_hot_upd';
SELECT 'RW_HOT_DEL:'  || count(*) FROM _events WHERE status='ci_hot_upd';
DELETE FROM events WHERE ts='2026-01-15 01:00:00+00' AND status='ci_cold_upd';
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
 ('2026-04-05 00:00+00','mixseed0','{}'),('2026-01-05 00:00+00','mixseed0','{}'),
 ('2026-04-06 00:00+00','mixseed1','{}'),('2026-01-06 00:00+00','mixseed1','{}'),
 ('2026-04-07 00:00+00','mixseed2','{}'),('2026-01-07 00:00+00','mixseed2','{}'),
 ('2026-04-08 00:00+00','mixseed3','{}'),('2026-01-08 00:00+00','mixseed3','{}');
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
    assert_eq "concurrent mixed write updated the cold tier (4 Jan rows)" "4" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='mixdone' AND ts < '2026-02-01';")"
    assert_eq "concurrent mixed write updated the hot tier (4 Apr rows)"  "4" "$(q "$HOST" "SELECT count(*) FROM _events WHERE status='mixdone';")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 7 — Schema DDL. Column-shape changes are BLOCKED (duckdb-iceberg can't
# ALTER an Iceberg table); RENAME TABLE/VIEW are supported (no Iceberg touch).
# ───────────────────────────────────────────────────────────────────────────
story_ddl() {
    step "7. Schema DDL (column changes blocked; rename table/view supported)"
    assert_err "ADD COLUMN blocked"     "cannot alter columns" "$(q_may "$HOST" "ALTER TABLE _events ADD COLUMN payload text;")"
    assert_err "DROP COLUMN blocked"    "cannot alter columns" "$(q_may "$HOST" "ALTER TABLE _events DROP COLUMN status;")"
    assert_err "ALTER TYPE blocked"     "cannot alter columns" "$(q_may "$HOST" "ALTER TABLE _events ALTER COLUMN id TYPE bigint;")"
    assert_err "RENAME COLUMN blocked"  "cannot rename a column" "$(q_may "$HOST" "ALTER TABLE _events RENAME COLUMN status TO state;")"
    # RENAME VIEW is supported and must migrate the watermark so the cold branch survives.
    q "$HOST" "ALTER VIEW events RENAME TO events_v2;" >/dev/null
    local cold; cold=$(q "$HOST" "SELECT count(*) FROM events_v2 WHERE ts < '2026-03-01';")
    assert_gt "cold tier survives view rename" "0" "$cold"
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
# Story 9 — Concurrency / no-409: writes that race the archive cycle survive.
# p_2026_04 is still hot after the first cycle (cutoff 2026-04-15). A second
# cycle with the cutoff pinned PAST 2026-05-01 expires it; --debug-export-delay
# holds the capture window open while concurrent UPDATE/DELETE/INSERT race into
# the delta trigger, which the cold replay must apply. (Ported from
# run-ci-local.sh step 8b — the one E2E behaviour the journey didn't yet cover.)
# ───────────────────────────────────────────────────────────────────────────
story_concurrency() {
    step "9. Race window: writes during the archive cycle survive into cold"
    qf "$HOST" <<'EOSQL' >/dev/null
INSERT INTO events (ts, status, data) VALUES
  ('2026-04-15 12:00+00','race_seed_a','{}'),
  ('2026-04-16 12:00+00','race_seed_b','{}'),
  ('2026-04-17 12:00+00','race_seed_c','{}'),
  ('2026-04-18 12:00+00','race_will_delete','{}');
EOSQL
    # Pin the race cutoff PAST 2026-05-01 (target 2026-05-15) so the Apr
    # partition — the last hot one — is expired by this cycle, deterministically.
    local ret_race=$(( ( $(date -u +%s) - $(date -u -d '2026-05-15' +%s) ) / 86400 ))
    cat > /tmp/journey-race.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog", namespace: "default" }
s3:       { endpoint: "${SW_IP}:8333", region: "us-east-1", access_key: "admin", secret_key: "adminsecret" }
archiver: { tables: [ { source_table: events, partition_period: monthly, hot_period: "${ret_race} days" } ] }
EOF
    "$ARCHIVER" --config /tmp/journey-race.yaml --debug-export-delay 4s >/tmp/journey-race.log 2>&1 &
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
INSERT INTO events (ts, status, data) VALUES ('2026-04-19 12:00+00','during_archive_insert','{}');
EOSQL
    if wait "$apid"; then pass "archiver cycle 2 completed cleanly (no 409)"
    else fail "archiver errored during race window"; tail -5 /tmp/journey-race.log; fi
    assert_eq "race UPDATEs survived (3 retagged in cold)" "3" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='during_archive';")"
    assert_eq "race INSERT survived (1 new in cold)"       "1" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='during_archive_insert';")"
    assert_eq "race DELETE survived (0 remaining)"         "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE status='race_will_delete';")"
    assert_eq "no rows left in original race_seed status"  "0" "$(q "$HOST" "SELECT count(*) FROM events WHERE status IN ('race_seed_a','race_seed_b','race_seed_c');")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 9b — Concurrency / no-409 (tiered): parallel COLD writers to one table
# all land. By this point every partition is archived (cutoff past 2026-05-01),
# so below-cutoff INSERTs route through the cold path (_tiered_insert_cold) and
# the same advisory-lock bakery serializes them. Parity with the decoupled
# probe — the standing multi-writer no-409 rule applies to both modes.
# ───────────────────────────────────────────────────────────────────────────
story_concurrent_writers() {
    step "9b. Concurrency: parallel tiered COLD writers serialize via the bakery (no 409)"
    local k pids=()
    rm -f /tmp/journey-tconc.* 2>/dev/null
    for k in 1 2 3 4 5 6 7 8; do
        q "$HOST" "INSERT INTO events (ts,status,data) VALUES ('2026-04-2${k} 09:00:00+00','tconc','{}');" >/tmp/journey-tconc.$k 2>&1 &
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
    "$ARCHIVER" --config /tmp/journey-archiver.yaml >/tmp/journey-idem.log 2>&1 \
        && assert_contains "archiver idempotent (re-run no-op)" "nothing to tier or expire" "$(cat /tmp/journey-idem.log)" \
        || fail "archiver idempotent re-run errored"
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
    q "$HOST" "INSERT INTO events (ts,status,data) VALUES ('2026-01-09 00:00+00','coexist_probe','{}');" >/dev/null 2>&1
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
        assert_eq "iceberg-only registered on peer $pc" "1" "$(q "$pc" "SELECT count(*) FROM coldfront.tiered_views WHERE is_iceberg_only AND iceberg_table='ice.default.iceonly';")"
    done

    # Cross-node READ: every row db1 wrote to Iceberg is visible on each peer via
    # the shared Lakekeeper catalog (no Spock involved on the cold path).
    local d1; d1=$(q "$HOST" "SELECT count(*) FROM iceonly;")
    for pc in "${PARR[@]}"; do
        assert_eq "peer $pc sees db1's iceberg rows via shared Lakekeeper" "$d1" "$(q "$pc" "SELECT count(*) FROM iceonly;")"
    done

    # Cross-node WRITE: a write on a peer is visible on db1 (shared catalog).
    local p1="${PARR[0]}"
    q "$p1" "INSERT INTO iceonly VALUES (5001,'2026-07-01 10:00:00+00','from_peer','{}');" >/dev/null 2>&1
    assert_eq "write from peer $p1 visible on db1" "1" "$(q "$HOST" "SELECT count(*) FROM iceonly WHERE status='from_peer';")"

    # R-A bakery under multi-node contention: concurrent cold writers on db1 AND
    # a peer to the SAME Iceberg table must both land. Here v_armed is true
    # (snowflake.node + dblink_self set), so this exercises the Ricart-Agrawala
    # claim protocol across nodes — not the local advisory lock — to avoid 409.
    rm -f /tmp/journey-ra.* 2>/dev/null
    q "$HOST" "INSERT INTO iceonly VALUES (6001,'2026-07-02 10:00:00+00','ra','{}');" >/tmp/journey-ra.1 2>&1 &
    q "$p1"   "INSERT INTO iceonly VALUES (6002,'2026-07-02 10:00:01+00','ra','{}');" >/tmp/journey-ra.2 2>&1 &
    wait
    assert_eq "no cross-node cold writer errored (R-A bakery, no 409)" "0" \
        "$(cat /tmp/journey-ra.* 2>/dev/null | grep -cEi 'error|conflict|409')"
    assert_eq "concurrent cross-node cold writers both landed (R-A bakery, no 409)" "2" "$(q "$HOST" "SELECT count(*) FROM iceonly WHERE status='ra';")"
    rm -f /tmp/journey-ra.* 2>/dev/null
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
    q "$p1" "INSERT INTO events (ts,status,data) VALUES ('2026-01-25 09:00+00','xnode_cold','{}');" >/dev/null 2>&1
    assert_eq "cold write from peer $p1 visible on db1 (shared Lakekeeper)" "1" \
        "$(q "$HOST" "SELECT count(*) FROM events WHERE status='xnode_cold';")"
    q "$HOST" "DELETE FROM events WHERE status='xnode_cold';" >/dev/null 2>&1
    assert_eq "cross-node row cleaned up (post-provision baseline restored)" "$total" "$(q "$HOST" "SELECT count(*) FROM events;")"
}

# ───────────────────────────────────────────────────────────────────────────
# Story 13 — Standby reads: a read-only physical replica serves cross-tier reads
# (hot via physical replication, cold via iceberg_scan executed on the read-only
# backend) and rejects writes cleanly. The coldfront catalog (registry,
# watermark, runtime_config) and the DuckDB S3 secret arrive through the base
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
    assert_eq "runtime_config (login-attach) replicated" "t" "$(q "$STANDBY" "SELECT attach_on_login FROM coldfront.runtime_config LIMIT 1;")"
    assert_eq "registered view OID identical (physical replication)" \
        "$(q "$HOST" "SELECT '$vn'::regclass::oid;")" "$(q "$STANDBY" "SELECT '$vn'::regclass::oid;")"

    # Reads MATCH the primary across tiers. The login trigger attaches 'ice' on
    # connect; iceberg_scan then executes read-only on the replica.
    assert_eq "standby cross-tier read == primary" "$(q "$HOST" "SELECT count(*) FROM $vn;")" "$(q "$STANDBY" "SELECT count(*) FROM $vn;")"
    assert_eq "standby cold-side read (iceberg_scan on replica) == primary" \
        "$(q "$HOST" "SELECT count(*) FROM $vn WHERE ts < '2026-04-01';")" \
        "$(q "$STANDBY" "SELECT count(*) FROM $vn WHERE ts < '2026-04-01';")"

    # tiered only: the watermark drives the hot/cold cutoff; it must replicate too.
    [ "$MODE" = tiered ] && assert_eq "archive_watermark replicated" \
        "$(q "$HOST" "SELECT count(*) FROM coldfront.archive_watermark;")" "$(q "$STANDBY" "SELECT count(*) FROM coldfront.archive_watermark;")"

    # A write through the view fails CLEANLY, not a coldfront crash. Use a COLD-
    # dated row so it routes through coldfront's cold chokepoint
    # (_exec_iceberg_with_claim) on BOTH modes, exercising the standby guard there
    # — a hot write would be rejected by PG natively, never reaching coldfront.
    local w; w=$(q_may "$STANDBY" "INSERT INTO $vn (ts,status,data) VALUES ('2026-01-20','x','{}'::jsonb);")
    assert_err "cold write through view on standby → clean read-only rejection" "read-only" "$w"

    # Mesh + tiered: the standby is a physical replica of db1 (HOST). A peer's HOT
    # write reaches db1 via Spock (logical) and then the standby via physical
    # replication — the property unique to a mesh-node read replica. Scoped to
    # tiered deliberately: decoupled has no PG data path (all rows live in shared
    # Lakekeeper, which the standby reads directly — already covered by the
    # cold-side read assertion above), and an Iceberg targeted-column INSERT is
    # unsupported, so there is no hot-tier peer write to route here anyway.
    if [ "$MESH" = 1 ] && [ "$MODE" = tiered ] && [ -n "${PEERS:-}" ]; then
        local PARR peer seen=0 j; read -ra PARR <<< "$PEERS"; peer="${PARR[0]}"
        q "$peer" "INSERT INTO $vn (ts,status,data) VALUES ('2026-04-22 08:00+00','sb_xnode','{}'::jsonb);" >/dev/null 2>&1
        for j in $(seq 1 30); do
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
CREATE TABLE IF NOT EXISTS regional_eu_p_2026_01 PARTITION OF regional_eu FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS regional_eu_p_2026_02 PARTITION OF regional_eu FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS regional_eu_p_2026_03 PARTITION OF regional_eu FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS regional_eu_p_2026_04 PARTITION OF regional_eu FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE IF NOT EXISTS regional_us_p_2026_01 PARTITION OF regional_us FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS regional_us_p_2026_02 PARTITION OF regional_us FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS regional_us_p_2026_03 PARTITION OF regional_us FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS regional_us_p_2026_04 PARTITION OF regional_us FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
INSERT INTO regional (region, ts, status, data) SELECT 'eu', '2026-01-15'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,100) i;
INSERT INTO regional (region, ts, status, data) SELECT 'eu', '2026-02-10'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,80) i;
INSERT INTO regional (region, ts, status, data) SELECT 'eu', '2026-03-05'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,60) i;
INSERT INTO regional (region, ts, status, data) SELECT 'eu', '2026-04-01'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"eu"}'::jsonb FROM generate_series(1,40) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', '2026-01-20'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,50) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', '2026-02-12'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,40) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', '2026-03-08'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,30) i;
INSERT INTO regional (region, ts, status, data) SELECT 'us', '2026-04-02'::timestamptz + (i*interval '1 hour'), 'ok', '{"r":"us"}'::jsonb FROM generate_series(1,20) i;
EOSQL
    assert_eq "2-level seeded 420 rows" "420" "$(q "$HOST" "SELECT count(*) FROM public.regional;")"

    local ret_days; ret_days=$(( ( $(date -u +%s) - $(date -u -d '2026-04-15' +%s) ) / 86400 ))  # cutoff 2026-04-15
    cat > /tmp/journey-tl.yaml <<EOF
postgres: { dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable" }
iceberg:  { warehouse: "${WAREHOUSE}", lakekeeper_endpoint: "http://${LK_IP}:8181/catalog", namespace: "default" }
s3:       { endpoint: "${SW_IP}:8333", region: "us-east-1", access_key: "admin", secret_key: "adminsecret" }
archiver:
  tables:
    - source_table: regional
      partition_column: ts
      partition_period: monthly
      hot_period: "${ret_days} days"
      sub_partition: { values_source: "SELECT region FROM (VALUES ('eu'),('us')) r(region)" }
EOF
    if "$ARCHIVER" --config /tmp/journey-tl.yaml >/tmp/journey-tl.log 2>&1; then
        pass "2-level archiver run completed (no flat-partitioning Fatal)"
    else
        fail "2-level archiver run — see /tmp/journey-tl.log"; tail -8 /tmp/journey-tl.log; return
    fi

    # Shape: the top becomes a view; the renamed hot table stays LIST-partitioned.
    assert_eq "regional is now a view" "v" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='regional';")"
    assert_eq "_regional is the LIST hot table" "p" "$(q "$HOST" "SELECT relkind FROM pg_class WHERE relname='_regional';")"

    # Past-hot leaves (Jan-Mar) tiered away for BOTH regions; Apr leaves remain hot.
    assert_eq "eu Jan leaf gone from hot"  "0" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='regional_eu_p_2026_01';")"
    assert_eq "us Mar leaf gone from hot"  "0" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='regional_us_p_2026_03';")"
    assert_eq "eu Apr leaf still hot"      "1" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='regional_eu_p_2026_04';")"
    assert_eq "us Apr leaf still hot"      "1" "$(q "$HOST" "SELECT count(*) FROM pg_class WHERE relname='regional_us_p_2026_04';")"

    # Read correctness across the boundary (the view UNIONs hot + cold).
    assert_eq "2-level total readable (hot+cold)" "420" "$(q "$HOST" "SELECT count(*) FROM regional;")"
    assert_eq "eu total (240 cold + 40 hot)"      "280" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu';")"
    assert_eq "us total (120 cold + 20 hot)"      "140" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='us';")"
    # Cold side is region-usable: a region-filtered cold read returns that region only.
    assert_eq "eu cold rows (Jan-Mar) present"    "240" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu' AND ts < '2026-04-01';")"
    assert_eq "old eu Jan leaf rows live in cold" "100" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu' AND ts >= '2026-01-01' AND ts < '2026-02-01';")"

    # Idempotency / cross-region wipe guard: a second run must NOT lose cold rows
    # (a region-blind Phase-0 wipe would under-count here).
    "$ARCHIVER" --config /tmp/journey-tl.yaml >/tmp/journey-tl2.log 2>&1
    assert_eq "re-run keeps all cold rows (region-scoped wipe)" "420" "$(q "$HOST" "SELECT count(*) FROM regional;")"
    assert_eq "re-run keeps eu cold rows" "240" "$(q "$HOST" "SELECT count(*) FROM regional WHERE region='eu' AND ts < '2026-04-01';")"
}

# ── orchestrate ────────────────────────────────────────────────────────────
# Setup is shared. The story set then branches on mode: tiered exercises the
# hot+cold partitioned path; decoupled exercises the all-Iceberg wrapper. (The
# tiered stories assume the partitioned `events` table and don't apply to an
# iceberg-only relation, and vice-versa.)
story_setup
[ "$MESH" = 1 ] && story_mesh_substrate   # bakery substrate replicates in all directions
if [ "$MODE" = "tiered" ]; then
    story_provision_tiered
    [ "$MESH" = 1 ] && story_mesh_tiered    # cross-node tiered, while hot+cold coexist
    story_reads
    story_types
    story_writes
    story_mixed_concurrency
    story_ddl
    story_blocks
    story_concurrency
    story_concurrent_writers
    story_txn
    story_coexist
    story_cold_retention
    story_tiered_twolevel
else
    story_provision_decoupled
    story_decoupled_crud
    story_decoupled_concurrency
    story_decoupled_ryw
fi
[ "$MESH" = 1 ] && [ "$MODE" = decoupled ] && story_mesh   # tiered+mesh runs story_mesh_tiered (above)
[ -n "$STANDBY" ]    && story_standby_reads

summary
