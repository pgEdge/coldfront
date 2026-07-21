#!/bin/bash
# ci/probe-standby.sh — STEP-0 RISK GATE for the standby matrix.
#
# The entire standby surface hinges on ONE unverified assumption: can pg_duckdb
# run iceberg_scan on a read-only hot standby? Per the project rule "verify the
# component before investing", this probe answers that BEFORE any standby matrix
# cell is built. It stands up a vanilla primary with real hot+cold data, takes a
# physical base backup into a standby container (entrypoint COLDFRONT_STANDBY_OF),
# and on the STANDBY:
#   - confirms it is a hot standby in recovery, caught up to the primary;
#   - reads cross-tier via the lazy-attach path (realistic: a fresh session
#     SELECTs the tiered view, the extension hook ATTACHes 'ice', the events
#     view UNIONs hot+cold);
#   - reads cross-tier + cold-only via an EXPLICIT ensure_attached() (isolates
#     iceberg_scan on the replica);
#   - confirms a write through the view fails CLEANLY (read-only txn), not a crash.
#
# GREEN authorizes building the standby cells (matrix.sh step 4). RED keeps them
# PENDING and localizes exactly what pg_duckdb does on a standby.
#
# Usage: ci/probe-standby.sh [--pg 16|17|18] [--keep]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/lib.sh"

PG="${PG_MAJOR:-18}"; KEEP=0
while [ $# -gt 0 ]; do case "$1" in
  --pg) PG="$2"; shift 2;;
  --keep) KEEP=1; shift;;
  *) echo "probe-standby.sh: unknown arg $1"; exit 2;;
esac; done

cd "$ROOT"
export PG_MAJOR="$PG"
COMPOSE="docker compose -f docker-compose.matrix.yml"
DB=coldfront-db-1
SB="$CF_STANDBY"
ARCHIVER="./bin/archiver"
WAREHOUSE=wh

trap topo_teardown EXIT   # unless --keep, removes the standby + tears the stack down

# ── 1. Bring up the vanilla primary stack ──────────────────────────────────
step "1. build + up primary stack"
docker rm -f "$SB" >/dev/null 2>&1 || true
$COMPOSE down -v >/dev/null 2>&1 || true
$COMPOSE up -d --build >/dev/null 2>&1
for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = healthy ] && break
    sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = healthy ] || { fail "primary not healthy"; exit 1; }

ip() { docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
DB_IP=$(ip "$DB"); SW_IP=$(ip coldfront-seaweedfs-1); LK_IP=$(ip coldfront-lakekeeper-1)

step "2. bootstrap Lakekeeper + warehouse"
curl -sf "http://$LK_IP:8181/management/v1/bootstrap" -X POST -H "Content-Type: application/json" \
     -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
for _ in $(seq 1 15); do
    WH=$(curl -s "http://$LK_IP:8181/management/v1/warehouse" -X POST -H "Content-Type: application/json" -d "{
      \"warehouse-name\":\"wh\",
      \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
      \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
    }" 2>&1)
    echo "$WH" | grep -q "warehouse-id" && break
    echo "$WH" | grep -qi "already exists" && break
    sleep 2
done

# ── 3. Provision a tiered events table with hot+cold data (journey prefix) ──
step "3. provision tiered events (extensions, secret, seed, archiver → Jan-Mar cold, Apr hot)"
qf "$DB" <<EOSQL >/dev/null
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin','adminsecret','${SW_IP}:8333');
EOSQL
qf "$DB" <<'EOSQL' >/dev/null
SET search_path = public;
CREATE TABLE IF NOT EXISTS events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL, status text, data jsonb,
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
# Pin the cutoff to 2026-04-15 (Apr hot, Jan-Mar cold) regardless of wall clock.
ret_days=$(( ( $(date -u +%s) - $(date -u -d '2026-04-15' +%s) ) / 86400 ))
cat > /tmp/probe-archiver.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "${WAREHOUSE}"
  lakekeeper_endpoint: "http://${LK_IP}:8181/catalog"
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
make -s build >/dev/null 2>&1 || go build -o bin/archiver ./cmd/archiver
if "$ARCHIVER" --config /tmp/probe-archiver.yaml >/tmp/probe-archiver.log 2>&1; then
    pass "archiver run (cold data created)"
else
    fail "archiver run — see /tmp/probe-archiver.log"; tail -8 /tmp/probe-archiver.log; exit 1
fi

PRIMARY_TOTAL=$(q "$DB" "SELECT count(*) FROM public.events;")
PRIMARY_HOT=$(q "$DB" "SELECT count(*) FROM public.p_2026_04;")
PRIMARY_COLD=$(( PRIMARY_TOTAL - PRIMARY_HOT ))
assert_eq "primary cross-tier count" "280" "$PRIMARY_TOTAL"
note "primary: hot(Apr)=$PRIMARY_HOT  cold(Jan-Mar via iceberg)=$PRIMARY_COLD"
assert_gt "primary actually has cold iceberg rows" "0" "$PRIMARY_COLD"

# ── 4. Stand up a physical standby of the primary ──────────────────────────
step "4. base-backup a read-only standby of $DB"
if standby_up "$DB" "$SB"; then pass "standby accepting connections"; else fail "standby never accepted connections"; exit 1; fi

# psql on the standby for pure-PG infra checks and the explicit-attach gate.
sb_psql() { docker exec -i -e PGUSER=coldfront -e PGDATABASE=coldfront "$SB" psql -tA "$@" 2>&1; }

INREC=$(sb_psql -c "SELECT pg_is_in_recovery();")
assert_eq "standby is in recovery (hot standby)" "t" "$INREC"

# Wait for the hot partition to replicate (pure-PG, no iceberg dependency).
for _ in $(seq 1 30); do
    [ "$(sb_psql -c 'SELECT count(*) FROM public.p_2026_04;')" = "$PRIMARY_HOT" ] && break
    sleep 1
done
assert_eq "standby caught up (hot partition via physical replication)" "$PRIMARY_HOT" "$(sb_psql -c 'SELECT count(*) FROM public.p_2026_04;')"

# The persistent-secret file is outside PGDATA, so it did not ride the base
# backup — materialize it on the replica from the (physically replicated)
# storage_secret row. SELECT + a DuckDB file write, no PG write, so it is
# allowed on a read-only standby.
sb_psql -c "SELECT coldfront.materialize_storage_secret();" >/dev/null 2>&1

# ── 5. THE GATE — iceberg reads on the read-only standby ───────────────────
step "5. GATE — pg_duckdb iceberg_scan on the read-only standby"

# 5a. Explicit-attach path: ensure_attached() + reads MUST run in ONE session
#     (the ATTACH is session-local).
GATE=$(sb_psql <<'EOSQL'
SELECT coldfront.ensure_attached();
SELECT 'TOTAL:'||count(*) FROM public.events;
SELECT 'COLD:'||count(*) FROM public.events WHERE ts < '2026-04-01';
EOSQL
)
SB_TOTAL=$(extract TOTAL "$GATE"); SB_COLD=$(extract COLD "$GATE")
if [ -z "$SB_TOTAL" ]; then note "explicit-attach gate raw output:"; echo "$GATE" | sed 's/^/      /'; fi
assert_eq "standby cross-tier read == primary (explicit attach, iceberg_scan works)" "$PRIMARY_TOTAL" "${SB_TOTAL:-MISSING}"
assert_eq "standby cold-only read (pure iceberg_scan)" "$PRIMARY_COLD" "${SB_COLD:-MISSING}"

# 5b. Lazy-attach path (realistic: a fresh session SELECTs the tiered view; the
# extension hook attaches 'ice' on first touch — no explicit call). q_may
# captures stderr too, so the duckdb ATTACH NOTICE rides along; the count is the
# lone pure-numeric line (NOTICE/BOOLEAN/[Rows] lines are not).
LAZY=$(q_may "$SB" "SELECT count(*) FROM public.events;")
LAZY_NUM=$(echo "$LAZY" | grep -E '^[0-9]+$' | tail -1)
if [ -n "$LAZY_NUM" ]; then
    assert_eq "lazy-attach session reads cross-tier on standby (hook attaches 'ice')" "$PRIMARY_TOTAL" "$LAZY_NUM"
else
    note "lazy-attach path returned: $LAZY"
    fail "lazy-attach not standby-safe (read errored on the read-only replica)"
fi

# ── 6. Writes through the view must fail CLEANLY (read-only), not crash ────
step "6. write through the view fails cleanly (read-only txn)"
W=$(q_may "$SB" "INSERT INTO public.events (ts,status,data) VALUES ('2026-04-20','x','{}'::jsonb);")
assert_err "view INSERT on standby → clean read-only error" "read-only" "$W"

step "probe-standby summary"
summary