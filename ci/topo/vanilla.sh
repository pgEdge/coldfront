#!/bin/bash
# ci/topo/vanilla.sh — single-node ("vanilla") topology: bring the stack up,
# bootstrap Lakekeeper + warehouse, run the journey against the primary, tear
# down. Spock/snowflake are NOT loaded (vanilla = local advisory-lock bakery).
#
# Usage: ci/topo/vanilla.sh --mode tiered|decoupled [--pg 16|17|18]
#                           [--compose <file>] [--keep] [--regress]
#
# --pg selects the PG major; the stack builds the ONE parameterized image
# (docker/Dockerfile, pgEdge minimal base, spock/snowflake left out → vanilla).
# --regress runs the pg_regress installcheck (the unit layer) against the same
# up stack before the journey — used by ci/matrix.sh so the unit + E2E layers
# share one bring-up. The journey + assertions are identical across PG majors.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/../lib.sh"

MODE="tiered"; COMPOSE_FILE="docker-compose.matrix.yml"; KEEP=0; REGRESS=0; STANDBY=0
PG="${PG_MAJOR:-18}"
# Cold-store backend: s3 (default) or azure (ADLS Gen2 on the DuckDB 1.5.x image,
# via --compose docker-compose.matrix-azure.yml). azure reads its identifiers and
# creds from env (never committed): COLDFRONT_AZURE_ACCOUNT, _FILESYSTEM, _KEY
# (the warehouse credential) and _CONNECTION_STRING (the client-side secret).
BACKEND="${COLDFRONT_BACKEND:-s3}"
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="$2"; shift 2;;
  --pg) PG="$2"; shift 2;;
  --compose) COMPOSE_FILE="$2"; shift 2;;
  --backend) BACKEND="$2"; shift 2;;
  --keep) KEEP=1; shift;;
  --regress) REGRESS=1; shift;;
  --standby) STANDBY=1; shift;;
  *) echo "vanilla.sh: unknown arg $1"; exit 2;;
esac; done
if [ "$BACKEND" = azure ]; then
  : "${COLDFRONT_AZURE_ACCOUNT:?--backend azure needs COLDFRONT_AZURE_ACCOUNT}"
  : "${COLDFRONT_AZURE_FILESYSTEM:?--backend azure needs COLDFRONT_AZURE_FILESYSTEM}"
  : "${COLDFRONT_AZURE_KEY:?--backend azure needs COLDFRONT_AZURE_KEY}"
  : "${COLDFRONT_AZURE_CONNECTION_STRING:?--backend azure needs COLDFRONT_AZURE_CONNECTION_STRING}"
fi
# GCS is the s3 path pointed at the GCS S3-interop endpoint with an HMAC key pair
# + a bucket (no separate backend; Lakekeeper uses an s3 profile @ storage.googleapis.com).
if [ "$BACKEND" = gcs ]; then
  : "${COLDFRONT_GCS_ACCESS_KEY:?--backend gcs needs COLDFRONT_GCS_ACCESS_KEY (HMAC)}"
  : "${COLDFRONT_GCS_SECRET_KEY:?--backend gcs needs COLDFRONT_GCS_SECRET_KEY (HMAC)}"
  : "${COLDFRONT_GCS_BUCKET:?--backend gcs needs COLDFRONT_GCS_BUCKET}"
fi
# aws is REAL AWS S3 (no local store): a Lakekeeper s3 profile with NO endpoint,
# path-style-access:false, flavor:aws — so DuckDB and Lakekeeper both use AWS's
# native per-Region virtual-hosted + HTTPS addressing (required for Regions
# launched after 2019-03-20). Creds + bucket + region from env (never committed).
if [ "$BACKEND" = aws ]; then
  : "${COLDFRONT_AWS_ACCESS_KEY:?--backend aws needs COLDFRONT_AWS_ACCESS_KEY}"
  : "${COLDFRONT_AWS_SECRET_KEY:?--backend aws needs COLDFRONT_AWS_SECRET_KEY}"
  : "${COLDFRONT_AWS_BUCKET:?--backend aws needs COLDFRONT_AWS_BUCKET}"
  : "${COLDFRONT_AWS_REGION:?--backend aws needs COLDFRONT_AWS_REGION}"
fi

cd "$ROOT"
export PG_MAJOR="$PG"           # consumed by docker-compose.matrix.yml build arg + entrypoint
COMPOSE="docker compose -f $COMPOSE_FILE"
DB=coldfront-db-1

trap topo_teardown EXIT

step "vanilla: build + up ($COMPOSE_FILE)"
$COMPOSE down -v >/dev/null 2>&1 || true
$COMPOSE up -d --build >/dev/null 2>&1
for i in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] && break
    sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] || { echo "db not healthy"; exit 1; }

ip() { docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
DB_IP=$(ip "$DB"); LK_IP=$(ip coldfront-lakekeeper-1)
# SeaweedFS only exists in the plain-s3 backend; azure's cold store is real ADLS
# and gcs's is real GCS (both reached over the network, no local store container).
# gcs reuses the stock matrix.yml image, whose COLDFRONT_WAREHOUSE GUC is "wh" —
# so the gcs warehouse must also be named "wh" (only its storage profile differs:
# s3 @ GCS). azure has its own image/compose with the wh-azure GUC.
case "$BACKEND" in
  azure) SW_IP=""; WAREHOUSE=wh-azure;;
  gcs)   SW_IP=""; WAREHOUSE=wh;;
  aws)   SW_IP=""; WAREHOUSE=wh;;
  *)     SW_IP=$(ip coldfront-seaweedfs-1); WAREHOUSE=wh;;
esac

step "vanilla: bootstrap Lakekeeper + warehouse ($BACKEND)"
curl -sf "http://$LK_IP:8181/management/v1/bootstrap" -X POST -H "Content-Type: application/json" \
     -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
# Backend-specific warehouse profile + credential. s3 validates by writing a
# probe object (SeaweedFS may still be warming up → retry); azure (ADLS Gen2)
# validates against the real account (identifiers + key from COLDFRONT_AZURE_*).
if [ "$BACKEND" = azure ]; then
  WH_BODY="{
    \"warehouse-name\":\"wh-azure\",
    \"storage-profile\":{\"type\":\"adls\",\"filesystem\":\"${COLDFRONT_AZURE_FILESYSTEM}\",\"account-name\":\"${COLDFRONT_AZURE_ACCOUNT}\"},
    \"storage-credential\":{\"type\":\"az\",\"credential-type\":\"shared-access-key\",\"key\":\"${COLDFRONT_AZURE_KEY}\"}
  }"
elif [ "$BACKEND" = gcs ]; then
  # GCS via S3-interop: lakekeeper s3 profile @ storage.googleapis.com, HMAC creds.
  # Named "wh" to match the stock image's COLDFRONT_WAREHOUSE GUC (see above).
  WH_BODY="{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"${COLDFRONT_GCS_BUCKET}\",\"key-prefix\":\"coldfront-ci-gcs\",\"region\":\"us-east-1\",\"endpoint\":\"https://storage.googleapis.com\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"${COLDFRONT_GCS_ACCESS_KEY}\",\"aws-secret-access-key\":\"${COLDFRONT_GCS_SECRET_KEY}\"}
  }"
elif [ "$BACKEND" = aws ]; then
  # REAL AWS S3: native s3 profile — NO endpoint, path-style-access:false,
  # flavor:aws ⇒ AWS per-Region virtual-hosted + HTTPS (the addressing post-2019
  # Regions require). Bucket/Region/creds from COLDFRONT_AWS_*. Named "wh".
  WH_BODY="{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"${COLDFRONT_AWS_BUCKET}\",\"key-prefix\":\"coldfront-ci-aws\",\"region\":\"${COLDFRONT_AWS_REGION}\",\"path-style-access\":false,\"flavor\":\"aws\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"${COLDFRONT_AWS_ACCESS_KEY}\",\"aws-secret-access-key\":\"${COLDFRONT_AWS_SECRET_KEY}\"}
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
  # Already created on a prior attempt? Treat as success.
  echo "$WH" | grep -qi "already exists" && { WH="warehouse-id (exists)"; break; }
  sleep 2
done
echo "$WH" | grep -q "warehouse-id" || { echo "warehouse creation failed after retries: $WH"; exit 1; }

# Seed the Iceberg namespace at provisioning time (deployment layer, alongside
# warehouse creation). DuckDB 1.5.x defers an Iceberg CREATE SCHEMA to
# transaction COMMIT while CREATE TABLE POSTs to the catalog eagerly, so
# create_iceberg_table (decoupled mode) — which runs both in ONE plpgsql
# transaction — 404s on a cold warehouse: the table POST references a namespace
# Lakekeeper has not committed yet. The archiver (tiered) issues them as two
# separate autocommitted statements and is unaffected. Creating the namespace
# here, as its own committed REST POST, makes create_iceberg_table's in-txn
# CREATE SCHEMA IF NOT EXISTS a no-op so the CREATE TABLE succeeds. See README.
WID=$(echo "$WH" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -z "$WID" ] && WID=$(curl -s "http://$LK_IP:8181/management/v1/warehouse" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
[ -n "$WID" ] && curl -s -X POST "http://$LK_IP:8181/catalog/v1/$WID/namespaces" \
    -H "Content-Type: application/json" -d '{"namespace":["default"]}' >/dev/null 2>&1 || true

if [ "$REGRESS" = 1 ]; then
    step "vanilla: pg_regress installcheck (unit layer)"
    # The runtime image is lean (no make/pg_regress). Run the unit layer from the
    # app Dockerfile's cf-build stage — it has the PG devel toolchain, pg_regress,
    # and the coldfront extension source at /build/coldfront, and builds in seconds
    # FROM the pgEdge base. It needs NO pg_duckdb / no private base image: pg_regress
    # only drives SQL against the RUNNING db (built from the app image, which already
    # has pg_duckdb + coldfront) over the compose network. The fixtures set
    # coldfront.warehouse/lakekeeper_endpoint to '' so ensure_attached() is a no-op
    # and Lakekeeper isn't needed here.
    BUILD_IMG="coldfront-regress:pg${PG}"
    docker build -f docker/Dockerfile.duckdb15 --build-arg PG_MAJOR="$PG" --target cf-build -t "$BUILD_IMG" . >/dev/null 2>&1
    NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$DB")
    if docker run --rm --network "$NET" \
           -e PGHOST=db -e PGPORT=5432 -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" \
           "$BUILD_IMG" bash -c 'cd /build/coldfront && make installcheck 2>&1; rc=$?; cat test/regression.diffs 2>/dev/null | head -60; exit $rc' | tail -12; then
        pass "pg_regress installcheck"
    else
        fail "pg_regress installcheck"
        exit 1
    fi
fi

step "vanilla: build archiver"
make -s build >/dev/null 2>&1 || go build -o bin/archiver ./cmd/archiver

topo_standby "$DB"

step "vanilla: run journey (backend=$BACKEND mode=$MODE standby=$STANDBY)"
# Pass the azure connection string via the INHERITED env (COLDFRONT_AZURE_CONNECTION_STRING),
# never as a CLI arg — argv is world-visible in `ps`, and the connection string carries the
# storage account key. journey.sh reads it from the same env var.
BACKEND_ARG=(--backend "$BACKEND" --warehouse "$WAREHOUSE")
"$SCRIPT_DIR/../journey.sh" --host "$DB" --db-ip "$DB_IP" --sw-ip "$SW_IP" --lk-ip "$LK_IP" --mode "$MODE" "${BACKEND_ARG[@]}" "${STANDBY_ARG[@]}"
