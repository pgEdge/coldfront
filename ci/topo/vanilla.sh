#!/bin/bash
# ci/topo/vanilla.sh — single-node ("vanilla") topology: bring the stack up,
# bootstrap Lakekeeper + warehouse, run the journey against the primary, tear
# down. Spock/snowflake are NOT loaded (vanilla = local advisory-lock bakery).
#
# Usage: ci/topo/vanilla.sh --mode tiered|decoupled [--compose <file>] [--keep]
#
# For now this targets the existing docker-compose.test.yml (PG18 + pgduckdb).
# When the parameterized image family lands (matrix step 2) the compose/image
# become arguments; the journey + assertions do not change.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/../lib.sh"

MODE="tiered"; COMPOSE_FILE="docker-compose.test.yml"; KEEP=0
while [ $# -gt 0 ]; do case "$1" in
  --mode) MODE="$2"; shift 2;;
  --compose) COMPOSE_FILE="$2"; shift 2;;
  --keep) KEEP=1; shift;;
  *) echo "vanilla.sh: unknown arg $1"; exit 2;;
esac; done

cd "$ROOT"
COMPOSE="docker compose -f $COMPOSE_FILE"
DB=coldfront-db-1

cleanup() { [ "$KEEP" = 1 ] || $COMPOSE down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

step "vanilla: build + up ($COMPOSE_FILE)"
$COMPOSE down -v >/dev/null 2>&1 || true
$COMPOSE up -d --build >/dev/null 2>&1
for i in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] && break
    sleep 2
done
[ "$(docker inspect -f '{{.State.Health.Status}}' "$DB" 2>/dev/null)" = "healthy" ] || { echo "db not healthy"; exit 1; }

ip() { docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
DB_IP=$(ip "$DB"); SW_IP=$(ip coldfront-seaweedfs-1); LK_IP=$(ip coldfront-lakekeeper-1)

step "vanilla: bootstrap Lakekeeper + warehouse"
curl -sf "http://$LK_IP:8181/management/v1/bootstrap" -X POST -H "Content-Type: application/json" \
     -d '{"accept-terms-of-use":true}' >/dev/null 2>&1 || true
WH=$(curl -s "http://$LK_IP:8181/management/v1/warehouse" -X POST -H "Content-Type: application/json" -d "{
  \"warehouse-name\":\"wh\",
  \"storage-profile\":{\"type\":\"s3\",\"bucket\":\"iceberg\",\"region\":\"us-east-1\",\"endpoint\":\"http://${SW_IP}:8333\",\"path-style-access\":true,\"flavor\":\"s3-compat\",\"sts-enabled\":false,\"remote-signing-enabled\":false},
  \"storage-credential\":{\"type\":\"s3\",\"credential-type\":\"access-key\",\"aws-access-key-id\":\"admin\",\"aws-secret-access-key\":\"adminsecret\"}
}" 2>&1)
echo "$WH" | grep -q "warehouse-id" || { echo "warehouse creation failed: $WH"; exit 1; }

step "vanilla: build archiver"
make -s build >/dev/null 2>&1 || go build -o bin/archiver ./cmd/archiver

step "vanilla: run journey (mode=$MODE)"
"$SCRIPT_DIR/../journey.sh" --host "$DB" --db-ip "$DB_IP" --sw-ip "$SW_IP" --lk-ip "$LK_IP" --mode "$MODE"
