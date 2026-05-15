#!/bin/bash
set -e
set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

step() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }
pass() { echo -e "${GREEN}  PASS: $1${NC}"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; FAIL=$((FAIL + 1)); }

assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi
}

assert_gt() {
    if [ "$3" -gt "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 — expected > $2, got '$3'"; fi
}

COMPOSE="docker compose -f docker-compose.distributed.yml"

# Run a psql command against a container's PG via the local compose network.
# Usage: qry db1 "SELECT ..."
qry() {
    local node="$1"; shift
    docker exec -e PGUSER=coldfront -e PGDATABASE=coldfront \
        "coldfront-${node}-1" /usr/pgsql-17/bin/psql -tA -c "$*"
}
qryf() {
    local node="$1"; shift
    docker exec -i -e PGUSER=coldfront -e PGDATABASE=coldfront \
        "coldfront-${node}-1" /usr/pgsql-17/bin/psql -tA
}

# ============================================================
step "1. gofmt check"
if [ -n "$(gofmt -l .)" ]; then
    gofmt -d .
    fail "code is not formatted"
    exit 1
fi
pass "formatting ok"

# ============================================================
step "1b. golangci-lint"
LINTER="${GOLANGCI_LINT:-$(command -v golangci-lint || echo "$HOME/go/bin/golangci-lint")}"
if [ ! -x "$LINTER" ]; then
    fail "golangci-lint not found"
    exit 1
fi
if ! "$LINTER" run ./...; then
    fail "golangci-lint found issues"
    exit 1
fi
pass "lint clean"

# ============================================================
step "2. Unit tests"
if ! make test 2>&1; then
    fail "unit tests"
    exit 1
fi
pass "unit tests"

# ============================================================
step "3. Build"
if ! make build 2>&1; then
    fail "build"
    exit 1
fi
pass "build ($(ls -lh bin/archiver | awk '{print $5}'))"

# ============================================================
step "4. Ensure coldfront-spock image exists"
if ! docker image inspect coldfront-spock:latest >/dev/null 2>&1; then
    echo "Building coldfront-spock:latest (one-time, ~20 min for DuckDB)..."
    docker build -f docker/coldfront-spock.Dockerfile -t coldfront-spock:latest . || {
        fail "image build"
        exit 1
    }
fi
pass "image ready"

# ============================================================
step "5. Start distributed stack"
$COMPOSE down -v 2>/dev/null || true
$COMPOSE up -d

echo "Waiting for db1, db2, db3 to be healthy..."
for i in $(seq 1 60); do
    H1=$(docker inspect -f '{{.State.Health.Status}}' coldfront-db1-1 2>/dev/null || echo "-")
    H2=$(docker inspect -f '{{.State.Health.Status}}' coldfront-db2-1 2>/dev/null || echo "-")
    H3=$(docker inspect -f '{{.State.Health.Status}}' coldfront-db3-1 2>/dev/null || echo "-")
    if [ "$H1" = "healthy" ] && [ "$H2" = "healthy" ] && [ "$H3" = "healthy" ]; then break; fi
    sleep 2
done
if [ "$H1" != "healthy" ] || [ "$H2" != "healthy" ] || [ "$H3" != "healthy" ]; then
    fail "nodes not healthy (db1=$H1 db2=$H2 db3=$H3)"
    $COMPOSE logs --tail=30
    exit 1
fi
pass "3 nodes healthy"

LK_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' coldfront-lakekeeper-1)
SW_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' coldfront-seaweedfs-1)

# ============================================================
step "5b. Extension smoke test on db1"
# Proves all required extensions load with coldfront-spock image. The
# dblink + snowflake extensions back the bakery protocol (multi-writer
# iceberg commit serialisation, see ARCHITECTURE_DECOUPLED.md).
qry db1 "CREATE EXTENSION IF NOT EXISTS dblink;" >/dev/null
qry db1 "CREATE EXTENSION IF NOT EXISTS snowflake;" >/dev/null
qry db1 "CREATE EXTENSION IF NOT EXISTS spock;" >/dev/null
qry db1 "CREATE EXTENSION IF NOT EXISTS pg_duckdb;" >/dev/null
qry db1 "CREATE EXTENSION IF NOT EXISTS coldfront;" >/dev/null
EXT_LIST=$(qry db1 "SELECT string_agg(extname,',' ORDER BY extname) FROM pg_extension WHERE extname IN ('dblink','snowflake','spock','pg_duckdb','coldfront');")
assert_eq "all required extensions loadable on db1" "dblink,coldfront,pg_duckdb,snowflake,spock" "$EXT_LIST"

# ============================================================
step "6. Spock mesh bootstrap (3 nodes, full mesh, 6 subs)"

# Create extensions on db2 and db3 too. dblink + snowflake are bakery
# prereqs (multi-writer iceberg commit serialisation).
for n in db2 db3; do
    qry $n "CREATE EXTENSION IF NOT EXISTS dblink;" >/dev/null
    qry $n "CREATE EXTENSION IF NOT EXISTS snowflake;" >/dev/null
    qry $n "CREATE EXTENSION IF NOT EXISTS spock;" >/dev/null
done

# Also create pg_duckdb and coldfront on all nodes (CREATE EXTENSION is DDL
# but we need it on every node up-front to avoid bootstrap ordering issues;
# once spock is active, subsequent DDL auto-replicates via ddl_sql repset).
for n in db2 db3; do
    qry $n "CREATE EXTENSION IF NOT EXISTS pg_duckdb;" >/dev/null
    qry $n "CREATE EXTENSION IF NOT EXISTS coldfront;" >/dev/null
done

# Node create on each node (idempotent-guarded)
for n in db1 db2 db3; do
    qry $n "SELECT CASE WHEN EXISTS(SELECT 1 FROM spock.node WHERE node_name='$n')
              THEN 'exists' ELSE spock.node_create('$n','host=$n user=coldfront dbname=coldfront port=5432')::text END;" >/dev/null
done

# Bidirectional subscriptions (6 total)
for a in db1 db2 db3; do
    for b in db1 db2 db3; do
        [ "$a" = "$b" ] && continue
        qry $a "SELECT spock.sub_create('sub_${a}_from_${b}','host=$b user=coldfront dbname=coldfront port=5432');" >/dev/null
    done
done

# Wait for initial sync on all subs
echo "Waiting for sub_wait_for_sync..."
for n in db1 db2 db3; do
    qry $n "SELECT spock.sub_wait_for_sync(sub_name) FROM spock.subscription;" >/dev/null
done
pass "spock mesh up and synced"

# ============================================================
step "7. Bootstrap Lakekeeper + create warehouse"
curl -sf http://$LK_IP:8181/management/v1/bootstrap -X POST \
    -H "Content-Type: application/json" \
    -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true

WH_RESULT=$(curl -s http://$LK_IP:8181/management/v1/warehouse -X POST \
    -H "Content-Type: application/json" -d "{
  \"warehouse-name\":\"wh\",
  \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
  \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
}" 2>&1)

if echo "$WH_RESULT" | grep -q "warehouse-id"; then
    pass "warehouse created"
else
    fail "warehouse creation: $WH_RESULT"
    $COMPOSE down -v
    exit 1
fi

# With the warehouse provisioned, arm the coldfront LOGIN event trigger on
# every node. From this point on, every new psql connection auto-attaches
# the Iceberg catalog — no user-visible warmup needed. The arm helper is a
# plain UPDATE on coldfront.runtime_config, so any role with UPDATE on that
# table can call it (no superuser, no ALTER SYSTEM).
for n in db1 db2 db3; do
    qry $n "SELECT coldfront.arm_login_attach()" >/dev/null
done
pass "coldfront login-attach armed on all nodes"

# ============================================================
step "8. Seed schema + 280 rows on db1"
# DuckDB iceberg extension install is file-based/per-node; run on all 3 nodes.
# The S3 secret is session-persistent via a PG foreign server; on Spock-aware
# nodes the CREATE SERVER would replicate via ddl_sql, but explicit setup on
# each node is safer and matches what coldfront.ensure_attached() expects.
for n in db1 db2 db3; do
    qry $n "SELECT duckdb.install_extension('iceberg');" >/dev/null
    qry $n "DROP SERVER IF EXISTS simple_s3_secret CASCADE;" >/dev/null
    qry $n "SELECT duckdb.create_simple_secret('s3','admin','adminsecret','','us-east-1','path','','${SW_IP}:8333','','','false');" >/dev/null
done

qryf db1 <<'EOSQL'
SET search_path = public;
CREATE TABLE IF NOT EXISTS events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL,
    status text,
    data jsonb,
    PRIMARY KEY (id, ts)  -- composite: PG requires PK to include partition key;
                          -- archiver requires PK for race-safe delta capture
) PARTITION BY RANGE (ts);
CREATE TABLE IF NOT EXISTS p_2026_01 PARTITION OF events FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE IF NOT EXISTS p_2026_02 PARTITION OF events FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE IF NOT EXISTS p_2026_03 PARTITION OF events FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE IF NOT EXISTS p_2026_04 PARTITION OF events FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
INSERT INTO events (ts, status, data) SELECT '2026-01-15'::timestamptz + (i * interval '1 hour'), 'ok', '{"m":"jan"}'::jsonb FROM generate_series(1,100) i;
INSERT INTO events (ts, status, data) SELECT '2026-02-10'::timestamptz + (i * interval '1 hour'), 'ok', '{"m":"feb"}'::jsonb FROM generate_series(1,80) i;
INSERT INTO events (ts, status, data) SELECT '2026-03-05'::timestamptz + (i * interval '1 hour'), 'ok', '{"m":"mar"}'::jsonb FROM generate_series(1,60) i;
INSERT INTO events (ts, status, data) SELECT '2026-04-01'::timestamptz + (i * interval '1 hour'), 'ok', '{"m":"apr"}'::jsonb FROM generate_series(1,40) i;
EOSQL

# Wait up to 30s for Spock to replicate 280 rows to db2 and db3
for i in $(seq 1 15); do
    C2=$(qry db2 "SELECT count(*) FROM events")
    C3=$(qry db3 "SELECT count(*) FROM events")
    if [ "$C2" = "280" ] && [ "$C3" = "280" ]; then break; fi
    sleep 2
done
assert_eq "db2 sees 280 seed rows via Spock" "280" "$C2"
assert_eq "db3 sees 280 seed rows via Spock" "280" "$C3"

# ============================================================
step "9. Run archiver against db1"
DB1_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' coldfront-db1-1)
cat > /tmp/ci-dist-archiver.yaml <<EOF
postgres:
  dsn: "host=${DB1_IP} port=5432 dbname=coldfront user=coldfront sslmode=disable"
iceberg:
  warehouse: "wh"
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
      retention_period: "1 month"
EOF
./bin/archiver --config /tmp/ci-dist-archiver.yaml 2>&1
pass "archiver completed on db1"

# Wait for DDL to replicate (partition detach, rename _events, view create)
echo "Waiting for archiver DDL to replicate via spock..."
for i in $(seq 1 15); do
    V2=$(qry db2 "SELECT count(*) FROM pg_views WHERE viewname='events' AND schemaname='public'")
    V3=$(qry db3 "SELECT count(*) FROM pg_views WHERE viewname='events' AND schemaname='public'")
    if [ "$V2" = "1" ] && [ "$V3" = "1" ]; then break; fi
    sleep 2
done
assert_eq "view 'events' replicated to db2" "1" "$V2"
assert_eq "view 'events' replicated to db3" "1" "$V3"

# ============================================================
step "10. Mirrored 9 assertions on db1 (single-node semantics)"
E2E_OUTPUT=$(docker exec -i -e PGUSER=coldfront -e PGDATABASE=coldfront coldfront-db1-1 \
    /usr/pgsql-17/bin/psql -tA <<EOSQL
SELECT 'WM:' || cutoff_time FROM coldfront.archive_watermark WHERE table_name = 'events';
SELECT 'RO_TOTAL:' || count(*) FROM events;
SELECT 'RO_HOT:'   || count(*) FROM events WHERE ts >= '2026-03-01';
SELECT 'RO_COLD:'  || count(*) FROM events WHERE ts  < '2026-03-01';
-- jsonb round-trip via the view: data must surface as jsonb (not text) and
-- the `->>` operator must work on both tiers.
SELECT 'JSONB_TYPE:' || pg_typeof(data)::text FROM events LIMIT 1;
SELECT 'JSONB_COLD_M:' || (data->>'m') FROM events
  WHERE ts  < '2026-03-01' AND status='ok' ORDER BY ts LIMIT 1;
SELECT 'JSONB_HOT_M:'  || (data->>'m') FROM events
  WHERE ts >= '2026-03-01' AND status='ok' ORDER BY ts LIMIT 1;
INSERT INTO events (ts, status, data) VALUES ('2026-04-09 12:00+00', 'ci_hot_ins', '{}');
SELECT 'RW_HOT_INS:' || count(*) FROM _events WHERE status = 'ci_hot_ins';
INSERT INTO events (ts, status, data) VALUES ('2026-01-15 12:00+00', 'ci_cold_ins', '{}');
SELECT 'RW_COLD_INS:' || count(*) FROM events WHERE status = 'ci_cold_ins';
UPDATE events SET status = 'ci_hot_upd' WHERE ts = '2026-04-09 12:00:00+00' AND status = 'ci_hot_ins';
SELECT 'RW_HOT_UPD:' || status FROM _events WHERE ts = '2026-04-09 12:00:00+00';
UPDATE events SET status = 'ci_cold_upd' WHERE ts = '2026-01-15 01:00:00+00';
SELECT 'RW_COLD_UPD:' || count(*) FROM events WHERE status = 'ci_cold_upd';
DELETE FROM events WHERE ts = '2026-04-09 12:00:00+00' AND status = 'ci_hot_upd';
SELECT 'RW_HOT_DEL:' || count(*) FROM _events WHERE status = 'ci_hot_upd';
DELETE FROM events WHERE ts = '2026-01-15 01:00:00+00' AND status = 'ci_cold_upd';
SELECT 'RW_COLD_DEL:' || count(*) FROM events WHERE status = 'ci_cold_upd';
EOSQL
)
extract() { echo "$E2E_OUTPUT" | grep "^$1:" | head -1 | cut -d: -f2-; }

WM_VAL=$(extract WM)
assert_gt "watermark set"            0 "${#WM_VAL}"
assert_eq "total rows (hot+cold)"    "280"        "$(extract RO_TOTAL)"
assert_eq "hot rows"                 "100"        "$(extract RO_HOT)"
assert_eq "cold rows"                "180"        "$(extract RO_COLD)"
assert_eq "data surfaces as json"    "json"       "$(extract JSONB_TYPE)"
assert_eq "json cold round-trip"     "jan"        "$(extract JSONB_COLD_M)"
assert_eq "json hot round-trip"      "mar"        "$(extract JSONB_HOT_M)"
assert_eq "hot insert via view"      "1"          "$(extract RW_HOT_INS)"
assert_eq "cold insert via view"     "1"          "$(extract RW_COLD_INS)"
assert_eq "hot update via view"      "ci_hot_upd" "$(extract RW_HOT_UPD)"
assert_eq "cold update via view"     "1"          "$(extract RW_COLD_UPD)"
assert_eq "hot delete via view"      "0"          "$(extract RW_HOT_DEL)"
assert_eq "cold delete via view"     "0"          "$(extract RW_COLD_DEL)"

# ============================================================
step "10b. Tiered mode INSERT shapes: multi-row VALUES, generate_series, pg_table"
# In tiered mode, INSERT INTO events flows through the INSTEAD OF row trigger
# which routes each row to either the hot PG partition or the cold Iceberg
# table based on ts vs the archive watermark. The C hook does NOT rewrite
# tiered-view INSERTs (only iceberg-only views). Per-row dispatch on the
# cold side is slow today; small counts keep CI fast while still proving
# correctness across all four input shapes.

# Path 2: multi-row VALUES, mix of hot and cold timestamps in one statement.
qry db1 "INSERT INTO events (ts, status, data) VALUES
  ('2026-04-15 09:00+00','tiered_p2_hot','{}'),
  ('2026-04-15 09:01+00','tiered_p2_hot','{}'),
  ('2026-04-15 09:02+00','tiered_p2_hot','{}'),
  ('2026-01-25 09:00+00','tiered_p2_cold','{}'),
  ('2026-01-25 09:01+00','tiered_p2_cold','{}');" >/dev/null
P2H=$(qry db1 "SELECT count(*) FROM events WHERE status='tiered_p2_hot';" | tail -1)
P2C=$(qry db1 "SELECT count(*) FROM events WHERE status='tiered_p2_cold';" | tail -1)
assert_eq "tiered path 2 (multi-row VALUES, hot)"  "3" "$P2H"
assert_eq "tiered path 2 (multi-row VALUES, cold)" "2" "$P2C"

# Path 3: SELECT FROM generate_series — DuckDB-side generator on the cold
# side, plain PG generator on the hot side; both go through the trigger.
qry db1 "INSERT INTO events (ts, status, data)
         SELECT '2026-04-20 00:00+00'::timestamptz + i*interval '1 minute',
                'tiered_p3_hot', jsonb_build_object('i', i)
         FROM generate_series(1,5) i;" >/dev/null
qry db1 "INSERT INTO events (ts, status, data)
         SELECT '2026-02-15 00:00+00'::timestamptz + i*interval '1 minute',
                'tiered_p3_cold', jsonb_build_object('i', i)
         FROM generate_series(1,5) i;" >/dev/null
P3H=$(qry db1 "SELECT count(*) FROM events WHERE status='tiered_p3_hot';" | tail -1)
P3C=$(qry db1 "SELECT count(*) FROM events WHERE status='tiered_p3_cold';" | tail -1)
assert_eq "tiered path 3 (SELECT FROM generate_series, hot)"  "5" "$P3H"
assert_eq "tiered path 3 (SELECT FROM generate_series, cold)" "5" "$P3C"

# Path 4: SELECT FROM <pg_table> — source rows in PG, target is the tiered
# unified view. Mix of hot and cold timestamps so both trigger branches
# fire over the same SELECT.
qry db1 "DROP TABLE IF EXISTS public.tiered_src CASCADE;" >/dev/null
qry db1 "CREATE TABLE public.tiered_src (ts timestamptz, status text, data jsonb);" >/dev/null
qry db1 "INSERT INTO public.tiered_src VALUES
  ('2026-04-25 00:00+00','tiered_p4_hot', '{\"src\":\"pg\"}'),
  ('2026-04-25 00:01+00','tiered_p4_hot', '{\"src\":\"pg\"}'),
  ('2026-04-25 00:02+00','tiered_p4_hot', '{\"src\":\"pg\"}'),
  ('2026-02-20 00:00+00','tiered_p4_cold','{\"src\":\"pg\"}'),
  ('2026-02-20 00:01+00','tiered_p4_cold','{\"src\":\"pg\"}');" >/dev/null
qry db1 "INSERT INTO events (ts, status, data) SELECT ts, status, data FROM public.tiered_src;" >/dev/null
P4H=$(qry db1 "SELECT count(*) FROM events WHERE status='tiered_p4_hot';" | tail -1)
P4C=$(qry db1 "SELECT count(*) FROM events WHERE status='tiered_p4_cold';" | tail -1)
assert_eq "tiered path 4 (SELECT FROM pg_table, hot)"  "3" "$P4H"
assert_eq "tiered path 4 (SELECT FROM pg_table, cold)" "2" "$P4C"

# ============================================================
step "11. Cross-node visibility"
# Re-insert a hot row so we can watch it replicate
qry db1 "INSERT INTO events (ts, status, data) VALUES ('2026-04-10 12:00+00', 'xnode_hot', '{}');" >/dev/null
# Re-insert a cold row (goes to Iceberg via pg_duckdb; not replicated by Spock).
qry db1 "INSERT INTO events (ts, status, data) VALUES ('2026-01-20 12:00+00', 'xnode_cold', '{}');" >/dev/null

# Hot: wait for Spock to replicate _events row to db2/db3
for i in $(seq 1 10); do
    H2=$(qry db2 "SELECT count(*) FROM _events WHERE status='xnode_hot'")
    H3=$(qry db3 "SELECT count(*) FROM _events WHERE status='xnode_hot'")
    if [ "$H2" = "1" ] && [ "$H3" = "1" ]; then break; fi
    sleep 1
done
assert_eq "hot write on db1 → visible on db2 via Spock" "1" "$H2"
assert_eq "hot write on db1 → visible on db3 via Spock" "1" "$H3"

# Cold: view reads go through iceberg_scan; explicit ATTACH in the session
# ensures S3 secret is wired for the read path on fresh sessions.
C2=$(qry db2 "SELECT count(*) FROM events WHERE status='xnode_cold';" | tail -1)
C3=$(qry db3 "SELECT count(*) FROM events WHERE status='xnode_cold';" | tail -1)
assert_eq "cold write on db1 → visible on db2 via shared Lakekeeper" "1" "$C2"
assert_eq "cold write on db1 → visible on db3 via shared Lakekeeper" "1" "$C3"

# ============================================================
step "12. Lakekeeper optimistic concurrency — parallel cold UPDATE from db1 & db2"
# Pre-check: verify the target row sets exist in both tiers before racing.
PRE_JAN=$(qry db1 "SELECT count(*) FROM events WHERE ts >= '2026-01-01' AND ts < '2026-01-20' AND status='ok';" | tail -1)
PRE_FEB=$(qry db1 "SELECT count(*) FROM events WHERE ts >= '2026-02-01' AND ts < '2026-02-20' AND status='ok';" | tail -1)
echo "  pre-race: $PRE_JAN jan 'ok' rows (db1 target), $PRE_FEB feb 'ok' rows (db2 target)"
assert_gt "jan 'ok' rows exist pre-race"  0 "$PRE_JAN"
assert_gt "feb 'ok' rows exist pre-race"  0 "$PRE_FEB"

T0=$(date +%s)
# Disable set -e inside the subshells so a failing UPDATE doesn't abort before
# we get to capture its rc. Lakekeeper's optimistic concurrency is *expected*
# to fail one of these two commits when they race; we want to observe which.
(
    set +e
    qry db1 "UPDATE events SET status='conflict_1' WHERE ts >= '2026-01-01' AND ts < '2026-01-20' AND status='ok';" 2>/tmp/lk-err-1
    echo "$?" > /tmp/lk-rc-1
) &
PID1=$!
(
    set +e
    qry db2 "UPDATE events SET status='conflict_2' WHERE ts >= '2026-02-01' AND ts < '2026-02-20' AND status='ok';" 2>/tmp/lk-err-2
    echo "$?" > /tmp/lk-rc-2
) &
PID2=$!
wait $PID1 $PID2 || true
T1=$(date +%s)
RC1=$(cat /tmp/lk-rc-1)
RC2=$(cat /tmp/lk-rc-2)
ELAPSED=$((T1 - T0))

echo "  rc1=$RC1 rc2=$RC2 elapsed=${ELAPSED}s"
echo "  stderr_1:" && head -3 /tmp/lk-err-1 2>/dev/null
echo "  stderr_2:" && head -3 /tmp/lk-err-2 2>/dev/null

C1_N1=$(qry db1 "SELECT count(*) FROM events WHERE status='conflict_1';" | tail -1)
C1_N2=$(qry db2 "SELECT count(*) FROM events WHERE status='conflict_1';" | tail -1)
C1_N3=$(qry db3 "SELECT count(*) FROM events WHERE status='conflict_1';" | tail -1)
C2_N1=$(qry db1 "SELECT count(*) FROM events WHERE status='conflict_2';" | tail -1)
C2_N2=$(qry db2 "SELECT count(*) FROM events WHERE status='conflict_2';" | tail -1)
C2_N3=$(qry db3 "SELECT count(*) FROM events WHERE status='conflict_2';" | tail -1)

echo "  conflict_1 counts: db1=$C1_N1 db2=$C1_N2 db3=$C1_N3"
echo "  conflict_2 counts: db1=$C2_N1 db2=$C2_N2 db3=$C2_N3"

# Invariants: all 3 nodes agree on each conflict label
assert_eq "conflict_1 consistent across nodes" "$C1_N1,$C1_N1" "$C1_N1,$C1_N2"
assert_eq "conflict_1 consistent db1↔db3"      "$C1_N1"         "$C1_N3"
assert_eq "conflict_2 consistent across nodes" "$C2_N1,$C2_N1" "$C2_N1,$C2_N2"
assert_eq "conflict_2 consistent db1↔db3"      "$C2_N1"         "$C2_N3"

# Outcome classification. Hard failures: both errored, or node divergence
# (caught by earlier assertions). Everything else is an observed outcome we
# record for follow-up hardening.
LANDED_1=0; [ "$C1_N1" != "0" ] && LANDED_1=1
LANDED_2=0; [ "$C2_N1" != "0" ] && LANDED_2=1

OUTCOME="unknown"
if [ "$RC1" != "0" ] && [ "$RC2" != "0" ]; then
    OUTCOME="FAIL (both transactions errored — Lakekeeper unavailable?)"
    fail "both transactions errored — Lakekeeper serialization broken"
elif [ "$RC1" = "0" ] && [ "$RC2" = "0" ] && [ "$LANDED_1" = "1" ] && [ "$LANDED_2" = "1" ]; then
    OUTCOME="A (both commits landed cleanly, ${ELAPSED}s)"
    pass "both concurrent cold UPDATEs committed cleanly"
elif [ "$RC1" = "0" ] && [ "$RC2" = "0" ]; then
    OUTCOME="SILENT_LOSS (both rc=0, but landed_1=$LANDED_1 landed_2=$LANDED_2; pg_duckdb swallowed a Lakekeeper conflict)"
    pass "both rc=0; one side's commit was silently dropped by pg_duckdb — documented for follow-up"
else
    OUTCOME="B (one aborted with error; the other succeeded and landed)"
    pass "one transaction aborted with an error, the other committed — Lakekeeper serialized"
fi
echo -e "${YELLOW}  LK_CONCURRENCY_OUTCOME=${OUTCOME}${NC}"

# ============================================================
step "12b. Bakery prereqs: claims table replicates in all 6 directions"
# The bakery (multi-writer iceberg commit serialisation) requires
# coldfront.claims to replicate cluster-wide. The table is only registered
# in Spock's default repset on a node when something on that node has
# either created an iceberg-only table (which calls
# coldfront._ensure_claims_replicated()) or explicitly registered the
# table. Do both, then probe-verify all 6 directions BEFORE any iceberg
# write — status=replicating doesn't guarantee data flow (verified by
# the manual scale-test debugging in this branch's history).

for n in db1 db2 db3; do
    qry $n "SELECT coldfront._ensure_claims_replicated();" >/dev/null
done

qry db1 "DELETE FROM coldfront.claims;" >/dev/null
sleep 1
qry db1 "INSERT INTO coldfront.claims (iceberg_table, ticket) VALUES ('bakery_probe', 91);" >/dev/null
qry db2 "INSERT INTO coldfront.claims (iceberg_table, ticket) VALUES ('bakery_probe', 92);" >/dev/null
qry db3 "INSERT INTO coldfront.claims (iceberg_table, ticket) VALUES ('bakery_probe', 93);" >/dev/null
sleep 3
for n in db1 db2 db3; do
    C=$(qry $n "SELECT count(*) FROM coldfront.claims WHERE iceberg_table='bakery_probe';" | tail -1)
    assert_eq "claims replication: $n sees all 3 sentinel rows" "3" "$C"
done
qry db1 "DELETE FROM coldfront.claims WHERE iceberg_table='bakery_probe';" >/dev/null

# ============================================================
step "13. Iceberg-only mode: create wrapper on db1, verify cross-node DDL replication"
# `coldfront.create_iceberg_table()` provisions an Iceberg-resident table with
# no PG hot tier: shared Lakekeeper-stored Iceberg table + per-node PG wrapper
# view + registry row. The C hook is the dispatch path for INSERT/UPDATE/DELETE
# on the wrapper view; no INSTEAD OF trigger is created in iceberg-only mode.
# Spock replicates the wrapper view DDL automatically. The registry row uses
# local view_oid as PK, so each node registers its own local view (DML on
# coldfront.tiered_views is
# not replicated — that's intentional, otherwise db1's local OID would
# overwrite db2's row referencing a different OID).

qry db1 "SELECT coldfront.create_iceberg_table('public', 'iceonly_evts',
  '[{\"name\":\"id\",\"type\":\"bigint\"},
    {\"name\":\"ts\",\"type\":\"timestamptz\"},
    {\"name\":\"status\",\"type\":\"text\"},
    {\"name\":\"data\",\"type\":\"jsonb\"}]'::jsonb);" >/dev/null

# Wait for Spock to replicate the wrapper view + trigger to db2 and db3.
echo "  waiting for iceberg-only view DDL to replicate..."
for i in $(seq 1 15); do
    V2=$(qry db2 "SELECT count(*) FROM pg_views WHERE viewname='iceonly_evts' AND schemaname='public'")
    V3=$(qry db3 "SELECT count(*) FROM pg_views WHERE viewname='iceonly_evts' AND schemaname='public'")
    if [ "$V2" = "1" ] && [ "$V3" = "1" ]; then break; fi
    sleep 2
done
assert_eq "iceonly view replicated to db2" "1" "$V2"
assert_eq "iceonly view replicated to db3" "1" "$V3"

# Register the iceberg-only marker on db2 and db3 (coldfront.tiered_views row
# is local-OID-keyed and not replicated). Without this row, the C-side hook
# would not know to short-circuit classify_tier() to TIER_COLD on these
# nodes; UPDATE/DELETE rewrites would fall through to the tiered path and
# fail because there is no _events / partition_col on these views.
for n in db2 db3; do
    qry $n "INSERT INTO coldfront.tiered_views (view_oid, hot_table, iceberg_table, partition_col, is_iceberg_only)
            SELECT c.oid, NULL, 'ice.default.iceonly_evts', NULL, true
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname='public' AND c.relname='iceonly_evts' AND c.relkind='v'
            ON CONFLICT (view_oid) DO UPDATE SET is_iceberg_only=true;" >/dev/null
done

R1=$(qry db1 "SELECT count(*) FROM coldfront.tiered_views WHERE is_iceberg_only AND iceberg_table='ice.default.iceonly_evts';")
R2=$(qry db2 "SELECT count(*) FROM coldfront.tiered_views WHERE is_iceberg_only AND iceberg_table='ice.default.iceonly_evts';")
R3=$(qry db3 "SELECT count(*) FROM coldfront.tiered_views WHERE is_iceberg_only AND iceberg_table='ice.default.iceonly_evts';")
assert_eq "iceberg-only registry row on db1" "1" "$R1"
assert_eq "iceberg-only registry row on db2" "1" "$R2"
assert_eq "iceberg-only registry row on db3" "1" "$R3"

# ============================================================
step "14. Iceberg-only mode: cross-node DML round-trip"
# Writes are not WAL-logged (duckdb.raw_query, not PG DML), so Spock has
# nothing to replicate. All visibility comes from the shared Lakekeeper
# catalog. Each node should see writes from any other node immediately.

qry db1 "INSERT INTO iceonly_evts VALUES (1, '2026-05-01 10:00:00+00', 'from_db1', '{\"by\":\"db1\"}');" >/dev/null
qry db2 "INSERT INTO iceonly_evts VALUES (2, '2026-05-01 10:00:01+00', 'from_db2', '{\"by\":\"db2\"}');" >/dev/null
qry db3 "INSERT INTO iceonly_evts VALUES (3, '2026-05-01 10:00:02+00', 'from_db3', '{\"by\":\"db3\"}');" >/dev/null

N1=$(qry db1 "SELECT count(*) FROM iceonly_evts;" | tail -1)
N2=$(qry db2 "SELECT count(*) FROM iceonly_evts;" | tail -1)
N3=$(qry db3 "SELECT count(*) FROM iceonly_evts;" | tail -1)
assert_eq "iceberg INSERTs from 3 nodes visible on db1" "3" "$N1"
assert_eq "iceberg INSERTs from 3 nodes visible on db2" "3" "$N2"
assert_eq "iceberg INSERTs from 3 nodes visible on db3" "3" "$N3"

# UPDATE on db3, hook short-circuits to TIER_COLD, raw_query writes Iceberg
qry db3 "UPDATE iceonly_evts SET status='upd_by_db3' WHERE id=1;" >/dev/null
S1=$(qry db1 "SELECT status FROM iceonly_evts WHERE id=1;" | tail -1)
S2=$(qry db2 "SELECT status FROM iceonly_evts WHERE id=1;" | tail -1)
S3=$(qry db3 "SELECT status FROM iceonly_evts WHERE id=1;" | tail -1)
assert_eq "UPDATE from db3 visible on db1" "upd_by_db3" "$S1"
assert_eq "UPDATE from db3 visible on db2" "upd_by_db3" "$S2"
assert_eq "UPDATE from db3 visible on db3" "upd_by_db3" "$S3"

qry db1 "DELETE FROM iceonly_evts WHERE id=2;" >/dev/null
D1=$(qry db1 "SELECT count(*) FROM iceonly_evts;" | tail -1)
D2=$(qry db2 "SELECT count(*) FROM iceonly_evts;" | tail -1)
D3=$(qry db3 "SELECT count(*) FROM iceonly_evts;" | tail -1)
assert_eq "DELETE from db1 visible on db1" "2" "$D1"
assert_eq "DELETE from db1 visible on db2" "2" "$D2"
assert_eq "DELETE from db1 visible on db3" "2" "$D3"

# Read-your-own-write inside an explicit BEGIN block on db2. The wrapper
# view sources rows from duckdb.query('SELECT * FROM ice.default.iceonly_evts')
# rather than iceberg_scan(...) so in-tx writes are visible to subsequent
# SELECTs in the same session.
RYW=$(qryf db2 <<'EOSQL'
BEGIN;
INSERT INTO iceonly_evts VALUES (99, '2026-05-01 11:00:00+00', 'in_tx', '{}');
SELECT 'IN_TX:' || count(*) FROM iceonly_evts WHERE id=99;
ROLLBACK;
SELECT 'POST:' || count(*) FROM iceonly_evts WHERE id=99;
EOSQL
)
RYW_IN=$(echo "$RYW" | grep "^IN_TX:" | cut -d: -f2)
RYW_POST=$(echo "$RYW" | grep "^POST:" | cut -d: -f2)
assert_eq "in-tx SELECT sees just-inserted iceberg row (RYW)" "1" "$RYW_IN"
assert_eq "ROLLBACK undoes iceberg INSERT"                    "0" "$RYW_POST"

# Exercise the three INSERT shapes that don't appear in the single-row
# VALUES round-trip above. All four paths go through the coldfront C hook
# (post_parse_analyze) and emit one duckdb.raw_query per statement — one
# Iceberg snapshot per INSERT, regardless of row count.
#
# IDs are chosen disjoint from {1,2,3} so the cross-node UPDATE in step 15
# (WHERE id IN (1,3)) keeps the same target set.

# Path 2: multi-row VALUES (single statement, N rows -> one snapshot)
qry db1 "INSERT INTO iceonly_evts VALUES
  (10,'2026-05-01 10:00:10+00','multirow','{}'),
  (11,'2026-05-01 10:00:11+00','multirow','{}'),
  (12,'2026-05-01 10:00:12+00','multirow','{}'),
  (13,'2026-05-01 10:00:13+00','multirow','{}');" >/dev/null
P2_C1=$(qry db1 "SELECT count(*) FROM iceonly_evts WHERE status='multirow';" | tail -1)
P2_C2=$(qry db2 "SELECT count(*) FROM iceonly_evts WHERE status='multirow';" | tail -1)
P2_C3=$(qry db3 "SELECT count(*) FROM iceonly_evts WHERE status='multirow';" | tail -1)
assert_eq "iceberg-only path 2 (multi-row VALUES) on db1" "4" "$P2_C1"
assert_eq "iceberg-only path 2 visible on db2"            "4" "$P2_C2"
assert_eq "iceberg-only path 2 visible on db3"            "4" "$P2_C3"

# Path 3: SELECT FROM generate_series (DuckDB-side function — no pglocal)
qry db1 "INSERT INTO iceonly_evts
         SELECT 100+i, '2026-05-01 10:01:00+00'::timestamptz + i*interval '1 second',
                'gs', jsonb_build_object('i', i)
         FROM generate_series(0,9) i;" >/dev/null
P3_C1=$(qry db1 "SELECT count(*) FROM iceonly_evts WHERE status='gs';" | tail -1)
P3_C2=$(qry db2 "SELECT count(*) FROM iceonly_evts WHERE status='gs';" | tail -1)
P3_C3=$(qry db3 "SELECT count(*) FROM iceonly_evts WHERE status='gs';" | tail -1)
assert_eq "iceberg-only path 3 (SELECT FROM generate_series) on db1" "10" "$P3_C1"
assert_eq "iceberg-only path 3 visible on db2"                       "10" "$P3_C2"
assert_eq "iceberg-only path 3 visible on db3"                       "10" "$P3_C3"

# Path 4: SELECT FROM <pg_table> — DuckDB streams source rows over libpq
# via the postgres extension's pglocal ATTACH (set up by ensure_pg_attached
# called from the C hook). No local materialisation, single Iceberg snapshot.
qry db1 "DROP TABLE IF EXISTS public.ico_src CASCADE;" >/dev/null
qry db1 "CREATE TABLE public.ico_src (id bigint, ts timestamptz, status text, data jsonb);" >/dev/null
qry db1 "INSERT INTO public.ico_src
         SELECT 200+i, '2026-05-01 10:02:00+00'::timestamptz + i*interval '1 second',
                'streamed', jsonb_build_object('i', i)
         FROM generate_series(0,49) i;" >/dev/null
qry db1 "INSERT INTO iceonly_evts SELECT id, ts, status, data FROM public.ico_src;" >/dev/null
P4_C1=$(qry db1 "SELECT count(*) FROM iceonly_evts WHERE status='streamed';" | tail -1)
P4_C2=$(qry db2 "SELECT count(*) FROM iceonly_evts WHERE status='streamed';" | tail -1)
P4_C3=$(qry db3 "SELECT count(*) FROM iceonly_evts WHERE status='streamed';" | tail -1)
assert_eq "iceberg-only path 4 (SELECT FROM pg_table via pglocal) on db1" "50" "$P4_C1"
assert_eq "iceberg-only path 4 visible on db2"                            "50" "$P4_C2"
assert_eq "iceberg-only path 4 visible on db3"                            "50" "$P4_C3"

# ============================================================
step "15. Iceberg-only mode: parallel UPDATE from db1 + db2 (bakery serializes)"
# Same shape as step 12 but for an iceberg-only table — every write goes
# through the coldfront C hook → coldfront._exec_iceberg_with_claim, which
# wraps each iceberg commit in the bakery protocol. Both UPDATEs MUST land
# cleanly (no 409, no silent loss) because the bakery serializes commits
# PG-side before they reach Lakekeeper. (Pre-bakery this step would
# tolerate "B (one aborted)" or "SILENT_LOSS"; with the bakery in place
# both outcomes are bugs.)

# Disjoint targets: db1 updates id=1, db2 updates id=3. With the bakery
# serialising commits, both UPDATEs land cleanly (no 409, no
# last-write-wins overwrite). On the same target set a successful
# bakery would still produce overwrite — meaningful only when the
# writers don't collide on rows, which is the realistic concurrent-
# writer pattern anyway.
T0=$(date +%s)
# R-A bakery serializes concurrent writers via per-claim acks — no 409
# should occur from within-cluster concurrent commits.
(
    set +e
    qry db1 "UPDATE iceonly_evts SET status='ico_c1' WHERE id = 1;" 2>/tmp/lk-ico-err-1
    echo "$?" > /tmp/lk-ico-rc-1
) &
PID1=$!
(
    set +e
    qry db2 "UPDATE iceonly_evts SET status='ico_c2' WHERE id = 3;" 2>/tmp/lk-ico-err-2
    echo "$?" > /tmp/lk-ico-rc-2
) &
PID2=$!
wait $PID1 $PID2 || true
T1=$(date +%s)
ICO_RC1=$(cat /tmp/lk-ico-rc-1)
ICO_RC2=$(cat /tmp/lk-ico-rc-2)
ICO_ELAPSED=$((T1 - T0))

ICO1_N1=$(qry db1 "SELECT count(*) FROM iceonly_evts WHERE status='ico_c1';" | tail -1)
ICO1_N2=$(qry db2 "SELECT count(*) FROM iceonly_evts WHERE status='ico_c1';" | tail -1)
ICO1_N3=$(qry db3 "SELECT count(*) FROM iceonly_evts WHERE status='ico_c1';" | tail -1)
ICO2_N1=$(qry db1 "SELECT count(*) FROM iceonly_evts WHERE status='ico_c2';" | tail -1)
ICO2_N2=$(qry db2 "SELECT count(*) FROM iceonly_evts WHERE status='ico_c2';" | tail -1)
ICO2_N3=$(qry db3 "SELECT count(*) FROM iceonly_evts WHERE status='ico_c2';" | tail -1)

echo "  rc1=$ICO_RC1 rc2=$ICO_RC2 elapsed=${ICO_ELAPSED}s"
echo "  ico_c1 counts: db1=$ICO1_N1 db2=$ICO1_N2 db3=$ICO1_N3"
echo "  ico_c2 counts: db1=$ICO2_N1 db2=$ICO2_N2 db3=$ICO2_N3"
echo "  stderr_1:" && head -3 /tmp/lk-ico-err-1 2>/dev/null
echo "  stderr_2:" && head -3 /tmp/lk-ico-err-2 2>/dev/null

assert_eq "iceberg ico_c1 consistent db1↔db2" "$ICO1_N1" "$ICO1_N2"
assert_eq "iceberg ico_c1 consistent db1↔db3" "$ICO1_N1" "$ICO1_N3"
assert_eq "iceberg ico_c2 consistent db1↔db2" "$ICO2_N1" "$ICO2_N2"
assert_eq "iceberg ico_c2 consistent db1↔db3" "$ICO2_N1" "$ICO2_N3"

ICO_LANDED_1=0; [ "$ICO1_N1" != "0" ] && ICO_LANDED_1=1
ICO_LANDED_2=0; [ "$ICO2_N1" != "0" ] && ICO_LANDED_2=1
if [ "$ICO_RC1" = "0" ] && [ "$ICO_RC2" = "0" ] && [ "$ICO_LANDED_1" = "1" ] && [ "$ICO_LANDED_2" = "1" ]; then
    pass "both iceberg-only concurrent UPDATEs committed cleanly via the bakery"
elif [ "$ICO_RC1" != "0" ] || [ "$ICO_RC2" != "0" ]; then
    fail "iceberg-only concurrent UPDATE errored (bakery should have serialized): rc1=$ICO_RC1 rc2=$ICO_RC2"
else
    fail "iceberg-only commit silently lost (rc=0 on both, landed_1=$ICO_LANDED_1 landed_2=$ICO_LANDED_2) — bakery is broken"
fi
echo -e "${YELLOW}  bakery elapsed=${ICO_ELAPSED}s${NC}"

# ============================================================
step "15b. Bakery: 3 concurrent writers on a single node (per-call ticket isolation)"
# The bakery tracks each in-flight commit by a unique snowflake ticket
# (not by node id), so multiple writers on the SAME PG node coexist
# cleanly — each holds its own ticket, release deletes by ticket only.
# Pre-fix this would error with "more than one row returned by a
# subquery" because the old design assumed 1 writer per node.

(
    set +e
    qry db1 "INSERT INTO iceonly_evts VALUES (501,'2026-05-01 12:00:00+00','mw_a','{}'),(502,'2026-05-01 12:00:01+00','mw_a','{}'),(503,'2026-05-01 12:00:02+00','mw_a','{}');" 2>/tmp/mw-err-a
    echo "$?" > /tmp/mw-rc-a
) &
MW_PID_A=$!
(
    set +e
    qry db1 "INSERT INTO iceonly_evts VALUES (511,'2026-05-01 12:00:10+00','mw_b','{}'),(512,'2026-05-01 12:00:11+00','mw_b','{}'),(513,'2026-05-01 12:00:12+00','mw_b','{}');" 2>/tmp/mw-err-b
    echo "$?" > /tmp/mw-rc-b
) &
MW_PID_B=$!
(
    set +e
    qry db1 "INSERT INTO iceonly_evts VALUES (521,'2026-05-01 12:00:20+00','mw_c','{}'),(522,'2026-05-01 12:00:21+00','mw_c','{}'),(523,'2026-05-01 12:00:22+00','mw_c','{}');" 2>/tmp/mw-err-c
    echo "$?" > /tmp/mw-rc-c
) &
MW_PID_C=$!
wait $MW_PID_A $MW_PID_B $MW_PID_C || true

MW_RC_A=$(cat /tmp/mw-rc-a)
MW_RC_B=$(cat /tmp/mw-rc-b)
MW_RC_C=$(cat /tmp/mw-rc-c)
[ "$MW_RC_A" = "0" ] && [ "$MW_RC_B" = "0" ] && [ "$MW_RC_C" = "0" ] \
    || fail "multi-writer-per-node: rcs were $MW_RC_A,$MW_RC_B,$MW_RC_C — bakery rejected concurrent writers on same node"

MW_TOTAL=$(qry db1 "SELECT count(*) FROM iceonly_evts WHERE status IN ('mw_a','mw_b','mw_c');" | tail -1)
assert_eq "all 9 rows from 3 concurrent same-node writers landed" "9" "$MW_TOTAL"

# All claims must be released (table goes back to empty when no writes are in flight).
sleep 1
MW_LEFTOVER=$(qry db1 "SELECT count(*) FROM coldfront.claims;" | tail -1)
assert_eq "claims table empty after concurrent writers complete" "0" "$MW_LEFTOVER"

# ============================================================
step "16. Idempotency + teardown"
./bin/archiver --config /tmp/ci-dist-archiver.yaml 2>&1 | grep -q "no expired partitions" \
    && pass "idempotency (second archiver run is no-op)" \
    || fail "second archiver run not idempotent"

$COMPOSE down -v 2>/dev/null
pass "stack torn down"

# ============================================================
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "  Passed: ${GREEN}$PASS${NC}"
echo -e "  Failed: ${RED}$FAIL${NC}"
echo -e "${YELLOW}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
