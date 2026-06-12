#!/bin/bash
# ci/topo/mesh.sh — 3-node Spock mesh topology.
#
# Brings up db1/db2/db3 on the ONE parameterized image (MESH=on → the entrypoint
# loads snowflake,spock,pg_duckdb,coldfront and writes the mesh GUCs), forms the
# Spock mesh (node_create + 6 bidirectional subs), bootstraps Lakekeeper +
# warehouse, sets the storage secret on every node, then runs the journey against db1
# with --mesh so the mesh-only stories (cross-node visibility, bakery under
# multi-node contention) run too. Lakekeeper is on its own dedicated Postgres.
#
# Usage: ci/topo/mesh.sh [--mode tiered|decoupled] [--pg 16|17|18] [--keep]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/../lib.sh"

MODE="tiered"; COMPOSE_FILE="docker-compose.mesh.yml"; KEEP=0; PG="${PG_MAJOR:-18}"; STANDBY=0
# Cold-store backend: s3 (default, SeaweedFS) or azure (ADLS Gen2 on the DuckDB
# 1.5.x image, via --compose docker-compose.mesh-azure.yml). azure reads its
# identifiers + creds from env (never committed): COLDFRONT_AZURE_ACCOUNT,
# _FILESYSTEM, _KEY (warehouse credential) and _CONNECTION_STRING (the secret).
BACKEND="${COLDFRONT_BACKEND:-s3}"
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="$2"; shift 2;;
  --pg) PG="$2"; shift 2;;
  --compose) COMPOSE_FILE="$2"; shift 2;;
  --backend) BACKEND="$2"; shift 2;;
  --keep) KEEP=1; shift;;
  --standby) STANDBY=1; shift;;
  *) echo "mesh.sh: unknown arg $1"; exit 2;;
esac; done
if [ "$BACKEND" = azure ]; then
  : "${COLDFRONT_AZURE_ACCOUNT:?--backend azure needs COLDFRONT_AZURE_ACCOUNT}"
  : "${COLDFRONT_AZURE_FILESYSTEM:?--backend azure needs COLDFRONT_AZURE_FILESYSTEM}"
  : "${COLDFRONT_AZURE_KEY:?--backend azure needs COLDFRONT_AZURE_KEY}"
  : "${COLDFRONT_AZURE_CONNECTION_STRING:?--backend azure needs COLDFRONT_AZURE_CONNECTION_STRING}"
fi
if [ "$BACKEND" = gcs ]; then
  : "${COLDFRONT_GCS_ACCESS_KEY:?--backend gcs needs COLDFRONT_GCS_ACCESS_KEY (HMAC)}"
  : "${COLDFRONT_GCS_SECRET_KEY:?--backend gcs needs COLDFRONT_GCS_SECRET_KEY (HMAC)}"
  : "${COLDFRONT_GCS_BUCKET:?--backend gcs needs COLDFRONT_GCS_BUCKET}"
fi

cd "$ROOT"
export PG_MAJOR="$PG"
COMPOSE="docker compose -f $COMPOSE_FILE"
NODES="db1 db2 db3"
PRIMARY="coldfront-db1-1"
PEERS="coldfront-db2-1 coldfront-db3-1"

trap topo_teardown EXIT

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
DB1_IP=$(ip "$PRIMARY"); LK_IP=$(ip coldfront-lakekeeper-1)
# SeaweedFS only exists in the s3 backend; azure's cold store is real ADLS.
if [ "$BACKEND" = azure ]; then SW_IP=""; WAREHOUSE=wh-azure; elif [ "$BACKEND" = gcs ]; then SW_IP=""; WAREHOUSE=wh; else SW_IP=$(ip coldfront-seaweedfs-1); WAREHOUSE=wh; fi

step "mesh: extensions on all nodes"
# One CREATE EXTENSION per call with ON_ERROR_STOP, errors surfaced — never chain
# them in a single psql -c (the first failure aborts the rest) and never hide them
# behind /dev/null: a silent CREATE EXTENSION spock failure once let a dead mesh
# masquerade as healthy for an entire matrix run.
for n in $NODES; do
    for ext in dblink snowflake spock pg_duckdb coldfront; do
        if ! out=$(docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "coldfront-${n}-1" \
                   "$CF_PSQL" -v ON_ERROR_STOP=1 -qtAc "CREATE EXTENSION IF NOT EXISTS $ext;" 2>&1); then
            echo "CREATE EXTENSION $ext on $n FAILED: $out"; exit 1
        fi
    done
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
[ "$subs" = 2 ] || { echo "spock bootstrap FAILED: db1 has '$subs' subscriptions (expected 2) — mesh not formed"; exit 1; }

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
# fully usable on a peer: archive_watermark (keyed by table_name) gives the peer's
# write hook the hot/cold cutoff, and tiered_views (keyed by schema_name,relname)
# arms the hook to recognise the view for UPDATE/DELETE + DDL-blocking. Both are
# name-keyed, so the repset copies each row verbatim and correct on every node (a
# name is node-independent). VERIFIED necessary: drop the tiered_views entry and
# the registry is absent on peers (only INSERT keeps working, via the replicated
# INSTEAD trigger) — the archiver runs on db1 only, so a peer never registers the
# view itself; it gets the row by replication. (See ARCHITECTURE_TIERED.md "Tiered
# tables in a Spock mesh". Decoupled re-registers per-node, so this is tiered-only.)
if [ "$MODE" = tiered ]; then
    for n in $NODES; do
        m "$n" "SELECT spock.repset_add_table('default','coldfront.tiered_views'::regclass, false);"    >/dev/null 2>&1
        m "$n" "SELECT spock.repset_add_table('default','coldfront.archive_watermark'::regclass, false);" >/dev/null 2>&1
    done
fi
# Per-table lifecycle config + the cold-tier storage secret replicate by value
# in any mesh mode (partition_config is also self-registered by the binaries via
# partcfg.EnsureTable; doing it here too is harmless).
for n in $NODES; do
    m "$n" "SELECT spock.repset_add_table('default','coldfront.partition_config'::regclass, false);" >/dev/null 2>&1
    m "$n" "SELECT spock.repset_add_table('default','coldfront.storage_secret'::regclass, false);" >/dev/null 2>&1
done
pass "spock mesh formed (6 subs) + bakery substrate armed on all nodes"

step "mesh: bootstrap Lakekeeper + warehouse ($BACKEND)"
curl -sf "http://$LK_IP:8181/management/v1/bootstrap" -X POST -H "Content-Type: application/json" \
     -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
# Backend-specific warehouse profile + credential (mirrors ci/topo/vanilla.sh):
# azure → adls profile validated against the real account; s3 → SeaweedFS.
if [ "$BACKEND" = azure ]; then
  WH_BODY="{
    \"warehouse-name\":\"wh-azure\",
    \"storage-profile\":{\"type\":\"adls\",\"filesystem\":\"${COLDFRONT_AZURE_FILESYSTEM}\",\"account-name\":\"${COLDFRONT_AZURE_ACCOUNT}\"},
    \"storage-credential\":{\"type\":\"az\",\"credential-type\":\"shared-access-key\",\"key\":\"${COLDFRONT_AZURE_KEY}\"}
  }"
elif [ "$BACKEND" = gcs ]; then
  WH_BODY="{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"${COLDFRONT_GCS_BUCKET}\",\"key-prefix\":\"coldfront-ci-gcs\",\"region\":\"us-east-1\",\"endpoint\":\"https://storage.googleapis.com\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"${COLDFRONT_GCS_ACCESS_KEY}\",\"aws-secret-access-key\":\"${COLDFRONT_GCS_SECRET_KEY}\"}
  }"
else
  WH_BODY="{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
  }"
fi
WH=""
for i in $(seq 1 15); do
  WH=$(curl -s "http://$LK_IP:8181/management/v1/warehouse" -X POST -H "Content-Type: application/json" -d "$WH_BODY" 2>&1)
  echo "$WH" | grep -q "warehouse-id" && break
  echo "$WH" | grep -qi "already exists" && { WH="warehouse-id (exists)"; break; }
  sleep 2
done
echo "$WH" | grep -q "warehouse-id" || { echo "warehouse creation failed after retries: $WH"; exit 1; }

step "mesh: set cold-tier storage secret on all nodes ($BACKEND)"
# set_storage_secret[_azure] writes the in-DB row (replicated via the repset
# above) and materializes a DuckDB PERSISTENT secret on each node — loaded at
# init, so cold reads/writes resolve creds with no connect-time setup. Run per
# node so every node's secret file is materialized regardless of apply-trigger
# behavior. The azure connection string carries the shared key; it rides the
# COLDFRONT_AZURE_CONNECTION_STRING env (never a committed value).
for n in $NODES; do
    if [ "$BACKEND" = azure ]; then
        m "$n" "SELECT coldfront.set_storage_secret_azure('${COLDFRONT_AZURE_CONNECTION_STRING}');" >/dev/null 2>&1
    elif [ "$BACKEND" = gcs ]; then
        m "$n" "SELECT coldfront.set_storage_secret('${COLDFRONT_GCS_ACCESS_KEY}','${COLDFRONT_GCS_SECRET_KEY}','storage.googleapis.com','us-east-1','path',true);" >/dev/null 2>&1
    else
        m "$n" "SELECT coldfront.set_storage_secret('admin','adminsecret','${SW_IP}:8333');" >/dev/null 2>&1
    fi
done

step "mesh: build archiver"
make -s build >/dev/null 2>&1 || go build -o bin/archiver ./cmd/archiver

topo_standby "$PRIMARY"

step "mesh: run journey (backend=$BACKEND mode=$MODE standby=$STANDBY) against db1 + mesh stories"
"$SCRIPT_DIR/../journey.sh" --host "$PRIMARY" --db-ip "$DB1_IP" --sw-ip "$SW_IP" --lk-ip "$LK_IP" \
    --mode "$MODE" --backend "$BACKEND" --warehouse "$WAREHOUSE" --mesh --peers "$PEERS" "${STANDBY_ARG[@]}"
