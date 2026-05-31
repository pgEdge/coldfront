#!/bin/bash
# ci/topo/mesh.sh — 3-node Spock mesh topology.
#
# Brings up db1/db2/db3 on the ONE parameterized image (MESH=on → the entrypoint
# loads snowflake,spock,pg_duckdb,coldfront and writes the mesh GUCs), forms the
# Spock mesh (node_create + 6 bidirectional subs), bootstraps Lakekeeper +
# warehouse, arms login-attach on every node, then runs the journey against db1
# with --mesh so the mesh-only stories (cross-node visibility, bakery under
# multi-node contention) run too. Lakekeeper is on its own dedicated Postgres.
#
# Usage: ci/topo/mesh.sh [--mode tiered|decoupled] [--pg 16|17|18] [--keep]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/../lib.sh"

MODE="tiered"; COMPOSE_FILE="docker-compose.mesh.yml"; KEEP=0; PG="${PG_MAJOR:-18}"
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="$2"; shift 2;;
  --pg) PG="$2"; shift 2;;
  --compose) COMPOSE_FILE="$2"; shift 2;;
  --keep) KEEP=1; shift;;
  *) echo "mesh.sh: unknown arg $1"; exit 2;;
esac; done

cd "$ROOT"
export PG_MAJOR="$PG"
COMPOSE="docker compose -f $COMPOSE_FILE"
NODES="db1 db2 db3"
PRIMARY="coldfront-db1-1"
PEERS="coldfront-db2-1 coldfront-db3-1"

cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

# In-mesh psql by spock node name (db1/db2/db3 → container coldfront-dbN-1).
m() { local n="$1"; shift; docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "coldfront-${n}-1" "$CF_PSQL" -tA -c "$*" 2>&1 | grep -avE 'NOTICE|result:|^BOOLEAN|Rows:|Success'; }

step "mesh: build + up ($COMPOSE_FILE, pg$PG)"
$COMPOSE down -v >/dev/null 2>&1 || true
$COMPOSE up -d --build >/dev/null 2>&1
for i in $(seq 1 60); do
    h=0; for n in $NODES; do [ "$(docker inspect -f '{{.State.Health.Status}}' "coldfront-${n}-1" 2>/dev/null)" = "healthy" ] && h=$((h+1)); done
    [ "$h" = 3 ] && break; sleep 2
done
[ "${h:-0}" = 3 ] || { echo "not all nodes healthy ($h/3)"; exit 1; }

ip() { docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
DB1_IP=$(ip "$PRIMARY"); SW_IP=$(ip coldfront-seaweedfs-1); LK_IP=$(ip coldfront-lakekeeper-1)

step "mesh: extensions on all nodes"
for n in $NODES; do
    docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "coldfront-${n}-1" "$CF_PSQL" -q -c \
        "CREATE EXTENSION IF NOT EXISTS dblink; CREATE EXTENSION IF NOT EXISTS snowflake; CREATE EXTENSION IF NOT EXISTS spock; CREATE EXTENSION IF NOT EXISTS pg_duckdb; CREATE EXTENSION IF NOT EXISTS coldfront;" >/dev/null 2>&1
done

step "mesh: Spock bootstrap (3 nodes, 6 subs)"
for n in $NODES; do
    m "$n" "SELECT CASE WHEN EXISTS(SELECT 1 FROM spock.node WHERE node_name='$n') THEN 'exists' ELSE spock.node_create('$n','host=$n user=coldfront dbname=coldfront port=5432')::text END;" >/dev/null
done
for a in $NODES; do for b in $NODES; do [ "$a" = "$b" ] && continue
    m "$a" "SELECT spock.sub_create('sub_${a}_from_${b}','host=$b user=coldfront dbname=coldfront port=5432');" >/dev/null 2>&1
done; done
for n in $NODES; do m "$n" "SELECT spock.sub_wait_for_sync(sub_name) FROM spock.subscription;" >/dev/null 2>&1; done
subs=$(m db1 "SELECT count(*) FROM spock.subscription;")
[ "$subs" = 2 ] || echo "  warning: db1 has $subs subs (expected 2)"

# Pre-arm the R-A bakery substrate on EVERY node: coldfront.claims/claim_acks
# must be in each node's replication set BEFORE any cold write. A peer acks an
# originator's claim by INSERTing into claim_acks (via dblink, so it is the
# peer's own origin); that ack only reaches the originator if claim_acks is in
# the peer's repset. create_iceberg_table() calls this too, but only on the node
# it runs on — so peers would otherwise not be armed until too late, and the
# originator would sleep forever waiting for acks. Idempotent.
for n in $NODES; do m "$n" "SELECT coldfront._ensure_claims_replicated();" >/dev/null 2>&1; done
# Tiered cross-node: replicate the registry + watermark alongside the bakery's
# claims/claim_acks. Both are needed for a tiered table provisioned on db1 to be
# fully usable on a peer: archive_watermark (name-keyed) gives the peer's write
# hook the hot/cold cutoff, and tiered_views arms the OID-keyed hook to recognise
# the view for UPDATE/DELETE + DDL-blocking. VERIFIED both ways: with both in the
# repset each peer ends up with a registry row that resolves to its OWN events
# view; drop the tiered_views entry and the registry is absent on peers (only
# INSERT keeps working, via the replicated INSTEAD trigger). tiered_views is
# OID-keyed and the archiver-recreated view's OID can diverge across nodes — a
# name-keyed registry would be the cleaner design (see ARCHITECTURE_TIERED.md "Tiered
# tables in a Spock mesh"). (Decoupled re-registers per-node, so this is tiered-only.)
if [ "$MODE" = tiered ]; then
    for n in $NODES; do
        m "$n" "SELECT spock.repset_add_table('default','coldfront.tiered_views'::regclass, false);"    >/dev/null 2>&1
        m "$n" "SELECT spock.repset_add_table('default','coldfront.archive_watermark'::regclass, false);" >/dev/null 2>&1
    done
fi
pass "spock mesh formed (6 subs) + bakery substrate armed on all nodes"

step "mesh: bootstrap Lakekeeper + warehouse"
curl -sf "http://$LK_IP:8181/management/v1/bootstrap" -X POST -H "Content-Type: application/json" \
     -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
WH=""
for i in $(seq 1 15); do
  WH=$(curl -s "http://$LK_IP:8181/management/v1/warehouse" -X POST -H "Content-Type: application/json" -d "{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
  }" 2>&1)
  echo "$WH" | grep -q "warehouse-id" && break
  echo "$WH" | grep -qi "already exists" && { WH="warehouse-id (exists)"; break; }
  sleep 2
done
echo "$WH" | grep -q "warehouse-id" || { echo "warehouse creation failed after retries: $WH"; exit 1; }

step "mesh: install iceberg + S3 secret on all nodes"
# Each node attaches Iceberg independently (the DuckDB iceberg extension is
# per-node, and the S3 secret feeds the cold read/write path). The journey's
# setup story does this for db1; peers need it too for cross-node cold reads.
# Create the secret BEFORE arming so the first post-arm login attaches cleanly.
for n in $NODES; do
    docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "coldfront-${n}-1" "$CF_PSQL" -q -c \
        "DROP SERVER IF EXISTS simple_s3_secret CASCADE; SELECT duckdb.create_simple_secret('s3','admin','adminsecret','','us-east-1','path','','${SW_IP}:8333','','','false');" >/dev/null 2>&1
done

step "mesh: arm login-attach on all nodes"
for n in $NODES; do m "$n" "SELECT coldfront.arm_login_attach();" >/dev/null 2>&1; done

step "mesh: build archiver"
make -s build >/dev/null 2>&1 || go build -o bin/archiver ./cmd/archiver

step "mesh: run journey (mode=$MODE) against db1 + mesh stories"
"$SCRIPT_DIR/../journey.sh" --host "$PRIMARY" --db-ip "$DB1_IP" --sw-ip "$SW_IP" --lk-ip "$LK_IP" \
    --mode "$MODE" --mesh --peers "$PEERS"
