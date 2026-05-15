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
    fail "golangci-lint not found (install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest or set GOLANGCI_LINT)"
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
step "4. Start docker-compose stack"
docker compose -f docker-compose.test.yml down -v 2>/dev/null || true
docker compose -f docker-compose.test.yml up -d --build
sleep 12

DB_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' coldfront-db-1)
LK_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' coldfront-lakekeeper-1)
SW_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' coldfront-seaweedfs-1)

# ============================================================
step "4b. coldfront pg_regress installcheck"
# The db container has postgresql-server-dev-18 + gcc + make from the image
# build; the fixtures set coldfront.warehouse/lakekeeper_endpoint to '' so
# ensure_attached() is a no-op and Lakekeeper isn't needed for this step.
docker exec coldfront-db-1 rm -rf /tmp/coldfront 2>/dev/null
docker cp extension/coldfront coldfront-db-1:/tmp/coldfront >/dev/null
if docker exec -e PGUSER=coldfront -e PGDATABASE=coldfront coldfront-db-1 \
       bash -c 'cd /tmp/coldfront && make installcheck 2>&1' | tee /tmp/mt_installcheck.log | tail -8; then
    pass "pg_regress installcheck"
else
    docker exec coldfront-db-1 cat /tmp/coldfront/test/regression.diffs 2>/dev/null | head -80
    fail "pg_regress installcheck"
    docker compose -f docker-compose.test.yml down -v
    exit 1
fi

# ============================================================
step "5. Bootstrap Lakekeeper + create warehouse"
curl -sf http://$LK_IP:8181/management/v1/bootstrap -X POST -H "Content-Type: application/json" -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true

WH_RESULT=$(curl -s http://$LK_IP:8181/management/v1/warehouse -X POST -H "Content-Type: application/json" -d "{
  \"warehouse-name\":\"wh\",
  \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
  \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
}" 2>&1)

if echo "$WH_RESULT" | grep -q "warehouse-id"; then
    pass "warehouse created"
else
    fail "warehouse creation: $WH_RESULT"
    docker compose -f docker-compose.test.yml down -v
    exit 1
fi

export PGPASSWORD=coldfront

# ============================================================
step "6. Setup PG data"
psql -h $DB_IP -U coldfront -d coldfront -q <<EOSQL
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT duckdb.install_extension('iceberg');
DROP SERVER IF EXISTS simple_s3_secret CASCADE;
SELECT duckdb.create_simple_secret('s3', 'admin', 'adminsecret', '', 'us-east-1', 'path', '', '${SW_IP}:8333', '', '', 'false');

-- Warehouse is now provisioned (step 5). Arm the coldfront LOGIN event
-- trigger so every new psql connection auto-attaches the Iceberg catalog.
SELECT coldfront.arm_login_attach();

SET search_path = public;
CREATE TABLE IF NOT EXISTS events (
    id bigint GENERATED ALWAYS AS IDENTITY,
    ts timestamptz NOT NULL,
    status text,
    data jsonb,
    PRIMARY KEY (id, ts)  -- composite: PG requires PK to include partition key
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
pass "seeded 280 rows"

# ============================================================
step "7. Run archiver"
cat > /tmp/ci-archiver.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lakekeeper:8181/catalog"
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

./bin/archiver --config /tmp/ci-archiver.yaml 2>&1
pass "archiver completed"

# ============================================================
step "8. E2E assertions"

# All assertions in a single psql session. The coldfront LOGIN event trigger
# (armed above via coldfront.attach_on_login) auto-attaches the Iceberg
# catalog for this session, so no explicit ATTACH is needed here.
E2E_OUTPUT=$(psql -h $DB_IP -U coldfront -d coldfront -t -A <<EOSQL
-- Watermark
SELECT 'WM:' || cutoff_time FROM coldfront.archive_watermark WHERE table_name = 'events';

-- Reads via unified view
SELECT 'RO_TOTAL:' || count(*) FROM events;
SELECT 'RO_HOT:'   || count(*) FROM events WHERE ts >= '2026-03-01';
SELECT 'RO_COLD:'  || count(*) FROM events WHERE ts  < '2026-03-01';

-- jsonb round-trip via the view: data must surface as jsonb (not text), and
-- the `->>` operator must work on both tiers. Seed put '{"m":"jan"}' on the
-- January partition (cold) and '{"m":"mar"}' on the March partition (hot).
SELECT 'JSONB_TYPE:' || pg_typeof(data)::text FROM events LIMIT 1;
SELECT 'JSONB_COLD_M:' || (data->>'m') FROM events
  WHERE ts  < '2026-03-01' AND status='ok' ORDER BY ts LIMIT 1;
SELECT 'JSONB_HOT_M:'  || (data->>'m') FROM events
  WHERE ts >= '2026-03-01' AND status='ok' ORDER BY ts LIMIT 1;

-- Hot INSERT via view (INSTEAD OF trigger routes to _events)
INSERT INTO events (ts, status, data) VALUES ('2026-04-09 12:00+00', 'ci_hot_ins', '{}');
SELECT 'RW_HOT_INS:' || count(*) FROM _events WHERE status = 'ci_hot_ins';

-- Cold INSERT via view (trigger routes to Iceberg via duckdb.raw_query)
INSERT INTO events (ts, status, data) VALUES ('2026-01-15 12:00+00', 'ci_cold_ins', '{}');
SELECT 'RW_COLD_INS:' || count(*) FROM events WHERE status = 'ci_cold_ins';

-- Hot UPDATE via view.  WHERE must include a ts predicate that proves the
-- hot tier; the extension errors on predicates it can't classify.
UPDATE events SET status = 'ci_hot_upd'
  WHERE ts = '2026-04-09 12:00:00+00' AND status = 'ci_hot_ins';
SELECT 'RW_HOT_UPD:' || status FROM _events WHERE ts = '2026-04-09 12:00:00+00';

-- Cold UPDATE via view.  Updates a pre-archived cold row (ts before cutoff);
-- freshly cold-inserted rows are visible to iceberg_scan reads but not to
-- raw_query writes in the same DuckDB session (Iceberg snapshot isolation —
-- known v0.1 limitation).
UPDATE events SET status = 'ci_cold_upd' WHERE ts = '2026-01-15 01:00:00+00';
SELECT 'RW_COLD_UPD:' || count(*) FROM events WHERE status = 'ci_cold_upd';

-- Hot DELETE via view (ts predicate proves hot tier).
DELETE FROM events WHERE ts = '2026-04-09 12:00:00+00' AND status = 'ci_hot_upd';
SELECT 'RW_HOT_DEL:' || count(*) FROM _events WHERE status = 'ci_hot_upd';

-- Cold DELETE via view (ts predicate proves cold tier).
DELETE FROM events WHERE ts = '2026-01-15 01:00:00+00' AND status = 'ci_cold_upd';
SELECT 'RW_COLD_DEL:' || count(*) FROM events WHERE status = 'ci_cold_upd';

-- Permissive-mode dual-tier UPDATE: the predicate (status = 'ok') has no ts
-- constraint, so classify_qual returns TIER_AMBIGUOUS.  With
-- coldfront.allow_mixed_writes = on (default), the hook emits a dual-tier
-- CTE that writes to both tiers and enables unsafe_allow_mixed_transactions
-- for the statement.  Hot-side 100 'ok' rows + cold-side 179 'ok' rows
-- become 'dual_upd'.
SELECT 'RW_DUAL_HOT_PRE:'  || count(*) FROM _events WHERE status = 'ok';
SELECT 'RW_DUAL_TOTAL_PRE:' || count(*) FROM events  WHERE status = 'ok';
UPDATE events SET status = 'dual_upd' WHERE status = 'ok';
SELECT 'RW_DUAL_HOT_POST:'  || count(*) FROM _events WHERE status = 'dual_upd';
SELECT 'RW_DUAL_TOTAL_POST:'|| count(*) FROM events  WHERE status = 'dual_upd';
SELECT 'RW_DUAL_REMAINING_OK:' || count(*) FROM events WHERE status = 'ok';

-- Permissive-mode ROLLBACK: DuckDB's XactCallback ties its transaction to
-- PG's, so rolling back undoes both tiers together.
BEGIN;
UPDATE events SET status = 'rollback_me' WHERE status = 'dual_upd';
ROLLBACK;
SELECT 'RB_HOT_ROLLBACK_ME:'   || count(*) FROM _events WHERE status = 'rollback_me';
SELECT 'RB_TOTAL_ROLLBACK_ME:' || count(*) FROM events  WHERE status = 'rollback_me';
SELECT 'RB_HOT_DUAL_STILL:'    || count(*) FROM _events WHERE status = 'dual_upd';
EOSQL
)

extract() { echo "$E2E_OUTPUT" | grep "^$1:" | head -1 | cut -d: -f2-; }

WM_VAL=$(extract WM)
assert_gt "watermark set" 0 "${#WM_VAL}"
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

# Permissive-mode dual-tier UPDATE: hot count should grow by pre-hot-ok;
# total dual_upd count should equal pre-total-ok; no 'ok' rows left.
DUAL_HOT_PRE=$(extract RW_DUAL_HOT_PRE)
DUAL_TOTAL_PRE=$(extract RW_DUAL_TOTAL_PRE)
assert_eq "dual update hot side"     "$DUAL_HOT_PRE"   "$(extract RW_DUAL_HOT_POST)"
assert_eq "dual update total side"   "$DUAL_TOTAL_PRE" "$(extract RW_DUAL_TOTAL_POST)"
assert_eq "dual update no ok left"   "0"               "$(extract RW_DUAL_REMAINING_OK)"

# ROLLBACK must undo both tiers (DuckDB XactCallback ties the transactions).
assert_eq "rollback undoes hot"      "0"               "$(extract RB_HOT_ROLLBACK_ME)"
assert_eq "rollback undoes cold too" "0"               "$(extract RB_TOTAL_ROLLBACK_ME)"
assert_eq "rollback keeps hot dual"  "$DUAL_HOT_PRE"   "$(extract RB_HOT_DUAL_STILL)"

# ============================================================
step "8b. Race-window regression: writes during archive cycle"

# Seed witness rows in p_2026_04 (still hot post-cycle-1). These INSERTs go
# through the view's INSTEAD-OF trigger → routed hot → land in p_2026_04.
psql -h $DB_IP -U coldfront -d coldfront -q <<EOSQL
INSERT INTO events (ts, status, data) VALUES
  ('2026-04-15 12:00+00', 'race_seed_a', '{}'),
  ('2026-04-16 12:00+00', 'race_seed_b', '{}'),
  ('2026-04-17 12:00+00', 'race_seed_c', '{}'),
  ('2026-04-18 12:00+00', 'race_will_delete', '{}');
EOSQL

# Cycle 2 with 1-day retention forces p_2026_04 (upper '2026-05-01') to
# be expired and archived. --debug-export-delay holds the trigger-capture
# window open for 4s after Phase 2 (bulk export) and before Phase 3 (replay
# + cutover), so concurrent writes from another psql session race
# deterministically into the delta capture trigger.
cat > /tmp/ci-archiver-race.yaml <<EOF
postgres:
  dsn: "host=${DB_IP} port=5432 dbname=coldfront user=coldfront password=coldfront sslmode=disable"
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lakekeeper:8181/catalog"
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
      retention_period: "1 day"
EOF

./bin/archiver --config /tmp/ci-archiver-race.yaml --debug-export-delay 4s \
    > /tmp/race-archiver.log 2>&1 &
ARCHIVER_PID=$!

# Wait until the archiver enters the trigger-capture window (logged when it
# starts the delay). Poll up to 30s.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    if grep -q "debug-export-delay" /tmp/race-archiver.log 2>/dev/null; then break; fi
    sleep 1
done

# Concurrent writes during the capture window:
#   - UPDATE existing seeded rows (a, b, c) → cold replay must pick up the new status
#   - DELETE one seeded row              → cold replay must propagate the delete to Iceberg
#   - INSERT a new row                    → cold replay must add it to Iceberg
psql -h $DB_IP -U coldfront -d coldfront -tA <<EOSQL > /tmp/race-writes.log 2>&1
UPDATE events SET status='during_archive' WHERE status IN ('race_seed_a','race_seed_b','race_seed_c');
DELETE FROM events WHERE status='race_will_delete';
INSERT INTO events (ts, status, data) VALUES ('2026-04-19 12:00+00', 'during_archive_insert', '{}');
EOSQL

wait $ARCHIVER_PID
ARCHIVER_RC=$?

if [ "$ARCHIVER_RC" -ne 0 ]; then
    cat /tmp/race-archiver.log
    fail "archiver exited non-zero during race-window test"
else
    pass "archiver completed cycle 2 cleanly"
fi

# After cycle 2: p_2026_04 has been archived. The trigger-captured writes
# must appear in Iceberg via the unified view.
assert_eq "race UPDATEs survived (3 rows retagged)" "3" \
    "$(psql -h $DB_IP -U coldfront -d coldfront -tAc \
        "SELECT count(*) FROM events WHERE status='during_archive'")"
assert_eq "race INSERT survived (1 new row)" "1" \
    "$(psql -h $DB_IP -U coldfront -d coldfront -tAc \
        "SELECT count(*) FROM events WHERE status='during_archive_insert'")"
assert_eq "race DELETE survived (0 rows remaining)" "0" \
    "$(psql -h $DB_IP -U coldfront -d coldfront -tAc \
        "SELECT count(*) FROM events WHERE status='race_will_delete'")"
assert_eq "no rows still in original race_seed status" "0" \
    "$(psql -h $DB_IP -U coldfront -d coldfront -tAc \
        "SELECT count(*) FROM events WHERE status IN ('race_seed_a','race_seed_b','race_seed_c')")"

# Idempotency
./bin/archiver --config /tmp/ci-archiver.yaml 2>&1 | grep -q "no expired partitions"
pass "idempotency (third run is no-op)"

# ============================================================
step "9. Tear down"
docker compose -f docker-compose.test.yml down -v 2>/dev/null
pass "stack torn down"

# ============================================================
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "  Passed: ${GREEN}$PASS${NC}"
echo -e "  Failed: ${RED}$FAIL${NC}"
echo -e "${YELLOW}========================================${NC}"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
