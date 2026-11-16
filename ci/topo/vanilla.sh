#!/bin/bash
# ci/topo/vanilla.sh — single-node ("vanilla") topology: bring the stack up,
# bootstrap Lakekeeper + warehouse, run the journey against the primary, tear
# down. Spock/snowflake are NOT loaded (vanilla = local advisory-lock bakery).
#
# Usage: ci/topo/vanilla.sh --mode tiered|decoupled [--pg 16|17|18]
#                           [--compose <file>] [--keep] [--regress]
#
# --pg selects the PG major; the stack builds the DuckDB 1.5.x image
# (docker/Dockerfile.duckdb15, spock/snowflake left out → vanilla).
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
if [ "$BACKEND" = azure ] || [ "$BACKEND" = azure-vended ]; then
  : "${COLDFRONT_AZURE_ACCOUNT:?--backend azure needs COLDFRONT_AZURE_ACCOUNT}"
  : "${COLDFRONT_AZURE_FILESYSTEM:?--backend azure needs COLDFRONT_AZURE_FILESYSTEM}"
fi
if [ "$BACKEND" = azure ]; then
  : "${COLDFRONT_AZURE_KEY:?--backend azure needs COLDFRONT_AZURE_KEY}"
  : "${COLDFRONT_AZURE_CONNECTION_STRING:?--backend azure needs COLDFRONT_AZURE_CONNECTION_STRING}"
fi
# azure-vended runs with the account's storage key as Lakekeeper's credential,
# or, on an account with key access off, with Lakekeeper's own identity: the
# managed identity's client and tenant IDs and the job's OIDC token.
if [ "$BACKEND" = azure-vended ] && [ -z "${COLDFRONT_AZURE_KEY:-}" ]; then
  : "${COLDFRONT_AZURE_TOKEN_FILE:?--backend azure-vended needs COLDFRONT_AZURE_KEY or COLDFRONT_AZURE_TOKEN_FILE}"
  : "${COLDFRONT_AZURE_CLIENT_ID:?--backend azure-vended with a token needs COLDFRONT_AZURE_CLIENT_ID}"
  : "${COLDFRONT_AZURE_TENANT_ID:?--backend azure-vended with a token needs COLDFRONT_AZURE_TENANT_ID}"
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
# aws-vended is real AWS S3 with no credential anywhere in the stack: Lakekeeper
# assumes the data role from its own identity (the GitHub role through the job's
# OIDC token in CI, the caller's session locally) and vends per-table STS
# credentials to DuckDB. The identifiers are the cloud-aws environment's
# variables; the cell writes under its own prefix, which the teardown purges.
if [ "$BACKEND" = aws-vended ]; then
  : "${COLDFRONT_AWS_BUCKET:?--backend aws-vended needs COLDFRONT_AWS_BUCKET}"
  : "${COLDFRONT_AWS_REGION:?--backend aws-vended needs COLDFRONT_AWS_REGION}"
  : "${COLDFRONT_AWS_DATA_ROLE_ARN:?--backend aws-vended needs COLDFRONT_AWS_DATA_ROLE_ARN}"
  : "${COLDFRONT_AWS_EXTERNAL_ID:?--backend aws-vended needs COLDFRONT_AWS_EXTERNAL_ID}"
fi

cd "$ROOT" || exit 1
export PG_MAJOR="$PG"           # consumed by docker-compose.matrix.yml build arg + entrypoint
require_base "$PG" || exit 1    # exports COLDFRONT_BASE for the same build
export COMPOSE="docker compose -f $COMPOSE_FILE"   # journey TC-277 recreates db with it
DB=coldfront-db-1

# A cloud lane with a federated identity: Lakekeeper's identity goes in an
# environment file the cloud compose override reads on the host, so a local
# run's session keys stay private to the caller; the token directory, which
# the container reads, is mounted at /oidc; and the cell writes under its own
# prefix, which the teardown purges.
CELL_PREFIX=""; TOKEN_FILE=""
case "$BACKEND" in
  aws-vended)   TOKEN_FILE="${COLDFRONT_AWS_TOKEN_FILE:-}";;
  azure-vended) TOKEN_FILE="${COLDFRONT_AZURE_TOKEN_FILE:-}";;
esac
# Whatever can be missing is checked before the cell creates anything.
if [ -n "$TOKEN_FILE" ]; then
  : "${COLDFRONT_CLOUD_DIR:?a cell with a token file runs under ci/cloud.sh run}"
  [ "$BACKEND" = aws-vended ] && : "${COLDFRONT_AWS_CI_ROLE_ARN:?COLDFRONT_AWS_TOKEN_FILE needs COLDFRONT_AWS_CI_ROLE_ARN}"
elif [ "$BACKEND" = aws-vended ]; then
  # A local run: the caller's own session, for Lakekeeper and the purge alike.
  creds=$(aws configure export-credentials --format env-no-export) || exit 1
fi
if [ "$BACKEND" = aws-vended ] || { [ "$BACKEND" = azure-vended ] && [ -n "$TOKEN_FILE" ]; }; then
  CF_LK_ENV_DIR=$(mktemp -d /tmp/coldfront-cloud.XXXXXX); export CF_LK_ENV_DIR
  {
    if [ "$BACKEND" = aws-vended ]; then
      echo "LAKEKEEPER__ENABLE_AWS_SYSTEM_CREDENTIALS=true"
      echo "AWS_REGION=$COLDFRONT_AWS_REGION"
      if [ -n "$TOKEN_FILE" ]; then
        # The GitHub role, assumed with the job's token.
        echo "AWS_ROLE_ARN=$COLDFRONT_AWS_CI_ROLE_ARN"
        echo "AWS_WEB_IDENTITY_TOKEN_FILE=/oidc/$(basename "$TOKEN_FILE")"
      else
        printf '%s\n' "$creds"
      fi
    else
      # The managed identity, through workload identity federation.
      echo "LAKEKEEPER__ENABLE_AZURE_SYSTEM_CREDENTIALS=true"
      echo "AZURE_CLIENT_ID=$COLDFRONT_AZURE_CLIENT_ID"
      echo "AZURE_TENANT_ID=$COLDFRONT_AZURE_TENANT_ID"
      echo "AZURE_FEDERATED_TOKEN_FILE=/oidc/$(basename "$TOKEN_FILE")"
    fi
  } > "$CF_LK_ENV_DIR/lakekeeper.env"
  # The purge's identity: ci/cloud.sh's env file in CI, the session written above locally.
  COLDFRONT_CLI_ENV="${COLDFRONT_CLI_ENV:-$CF_LK_ENV_DIR/lakekeeper.env}"
  CF_LK_TOKEN_DIR="${TOKEN_FILE:+$(dirname "$TOKEN_FILE")}"
  export CF_LK_TOKEN_DIR="${CF_LK_TOKEN_DIR:-$CF_LK_ENV_DIR}"
  CELL_PREFIX=$(cell_prefix)
  [ -n "${COLDFRONT_CI_PREFIXES:-}" ] && echo "$CELL_PREFIX/" >> "$COLDFRONT_CI_PREFIXES"
  COMPOSE="$COMPOSE -f docker-compose.cloud.yml"
fi

trap topo_teardown EXIT

step "vanilla: build + up ($COMPOSE_FILE)"
$COMPOSE down -v >/dev/null 2>&1 || true
# shellcheck disable=SC2086  # COMPOSE is a command line
run_logged $COMPOSE up -d --build || true
for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] && break
    sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] || { echo "db not healthy"; docker logs --tail 40 "$DB" 2>&1; exit 1; }

ip() { docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
DB_IP=$(ip "$DB"); LK_IP=$(ip coldfront-lakekeeper-1)
# SeaweedFS only exists in the plain-s3 backend; azure's cold store is real ADLS
# and gcs's is real GCS (both reached over the network, no local store container).
# gcs reuses the stock matrix.yml image, whose COLDFRONT_WAREHOUSE GUC is "wh" —
# so the gcs warehouse must also be named "wh" (only its storage profile differs:
# s3 @ GCS). azure has its own image/compose with the wh-azure GUC.
case "$BACKEND" in
  azure)  SW_IP="";;
  azure-vended) SW_IP="";;
  gcs)    SW_IP="";;
  aws)    SW_IP="";;
  aws-vended) SW_IP="";;
  *)      SW_IP=$(ip coldfront-seaweedfs-1);;   # s3 (static) + vended
esac

# SeaweedFS backends: pre-create the bucket, matching every real backend (the
# aws/gcs/azure lanes all point at a pre-provisioned bucket; Lakekeeper never
# creates it). SeaweedFS auto-creates on first write only for the static-identity
# path; the vended lane's STS write path does not, so the bucket must exist first.
if [ -n "$SW_IP" ]; then
  # `weed shell bucket.create` exits 0 even before the master is ready, so verify
  # the bucket actually appears in bucket.list; retry until it does (SeaweedFS may
  # still be warming up right after compose up).
  created=0
  for _ in $(seq 1 15); do
    docker exec coldfront-seaweedfs-1 sh -c "echo 's3.bucket.create -name iceberg' | weed shell" >/dev/null 2>&1
    if docker exec coldfront-seaweedfs-1 sh -c "echo 's3.bucket.list' | weed shell" 2>/dev/null | grep -q ' iceberg'; then created=1; break; fi
    sleep 2
  done
  [ "$created" = 1 ] || { echo "FATAL: SeaweedFS bucket 'iceberg' not created after retries"; exit 1; }
fi

step "vanilla: bootstrap Lakekeeper + warehouse ($BACKEND)"
curl -sf "http://$LK_IP:8181/management/v1/bootstrap" -X POST -H "Content-Type: application/json" \
     -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
# Backend-specific warehouse profile + credential. s3 validates by writing a
# probe object (SeaweedFS may still be warming up → retry); azure (ADLS Gen2)
# validates against the real account (identifiers + key from COLDFRONT_AZURE_*).
if [ "$BACKEND" = azure-vended ] && [ -n "$TOKEN_FILE" ]; then
  # The managed identity signs the delegation keys; the warehouse holds no key,
  # and the cell's prefix is its key-prefix under the filesystem.
  WH_BODY="{
    \"warehouse-name\":\"wh-azure\",
    \"storage-profile\":{\"type\":\"adls\",\"filesystem\":\"${COLDFRONT_AZURE_FILESYSTEM}\",\"account-name\":\"${COLDFRONT_AZURE_ACCOUNT}\",\"key-prefix\":\"${CELL_PREFIX}\"},
    \"storage-credential\":{\"type\":\"az\",\"credential-type\":\"azure-system-identity\"}
  }"
elif [ "$BACKEND" = azure ] || [ "$BACKEND" = azure-vended ]; then
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
elif [ "$BACKEND" = aws-vended ]; then
  # Real AWS S3 with vended credentials: the warehouse holds no key. Lakekeeper
  # assumes the data role with the external ID from its own identity and vends
  # per-table STS credentials; the cell's prefix is the warehouse's key-prefix.
  WH_BODY="{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"${COLDFRONT_AWS_BUCKET}\",\"key-prefix\":\"${CELL_PREFIX}\",\"region\":\"${COLDFRONT_AWS_REGION}\",\"path-style-access\":false,\"flavor\":\"aws\",\"sts-enabled\":true,\"assume-role-arn\":\"${COLDFRONT_AWS_DATA_ROLE_ARN}\",\"remote-signing-enabled\":false},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"aws-system-identity\",\"external-id\":\"${COLDFRONT_AWS_EXTERNAL_ID}\"}
  }"
elif [ "$BACKEND" = vended ]; then
  # Vended: SeaweedFS issues per-table STS creds. sts-enabled + assume-role-arn
  # (the role/trust-policy in docker/seaweedfs-iam.json); sts-endpoint = the S3
  # endpoint. The warehouse's OWN credential stays the long-term admin access-key
  # (vending changes only the client plane). Lakekeeper delivers the temp creds in
  # LoadTable, which duckdb-iceberg (ACCESS_DELEGATION_MODE VENDED_CREDENTIALS) uses.
  WH_BODY="{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":true,\"sts-endpoint\":\"http://${SW_IP}:8333\",\"assume-role-arn\":\"arn:aws:iam::000000000000:role/coldfront\"},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
  }"
else
  WH_BODY="{
    \"warehouse-name\":\"wh\",
    \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
    \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
  }"
fi
create_warehouse_and_seed "$LK_IP" "$WH_BODY"   # POST warehouse + seed 'default' namespace (ci/lib.sh)

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
    run_logged docker build -f docker/Dockerfile.duckdb15 --build-arg PG_MAJOR="$PG" --target cf-build "${REPO_SECRET_ARGS[@]}" -t "$BUILD_IMG" . || true
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

# The compactor is a separate iceberg-go module that `make build` does NOT build.
# Journey stories 6d/6e drive it; without it a missing ./bin/compactor reads as
# "No such file or directory" and hides a compactor regression. Build it here,
# and abort if the build fails since 6d/6e depend on it.
step "vanilla: build compactor (separate iceberg-go module; journey 6d/6e need it)"
make -s compactor || { echo "vanilla.sh: compactor build failed: stories 6d/6e require ./bin/compactor"; exit 1; }

topo_standby "$DB"

step "vanilla: run journey (backend=$BACKEND mode=$MODE standby=$STANDBY)"
# Pass the azure connection string via the INHERITED env (COLDFRONT_AZURE_CONNECTION_STRING),
# never as a CLI arg — argv is world-visible in `ps`, and the connection string carries the
# storage account key. journey.sh reads it from the same env var.
BACKEND_ARG=(--backend "$BACKEND")
"$SCRIPT_DIR/../journey.sh" --host "$DB" --db-ip "$DB_IP" --sw-ip "$SW_IP" --lk-ip "$LK_IP" --mode "$MODE" "${BACKEND_ARG[@]}" "${STANDBY_ARG[@]}"
