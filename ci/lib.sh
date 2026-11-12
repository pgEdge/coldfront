#!/bin/bash
# ci/lib.sh — shared helpers for the ColdFront E2E matrix.
#
# Sourced by journey.sh, matrix.sh, topo/*.sh, probe-standby.sh. There is ONE
# set of assert + psql helpers (DRY), matching the style of the original
# run-ci-local.sh so output and semantics are unchanged.
#
# psql is addressed by container name; the journey is topology-agnostic and
# never hardcodes a node — callers pass the container. CF_PSQL overrides the
# psql binary path for images where it isn't on PATH.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

step() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }
pass() { echo -e "${GREEN}  PASS: $1${NC}"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}  FAIL: $1${NC}"; FAIL=$((FAIL + 1)); }
# note: a logged, uncounted line — for coverage that is intentionally skipped in
# a given cell (so it's visible, never silent, but isn't a pass or a failure).
note() { echo -e "${YELLOW}  NOTE: $1${NC}"; }

assert_eq()       { if [ "$2" = "$3" ];        then pass "$1"; else fail "$1 — expected '$2', got '$3'"; fi; }
assert_gt()       { if [ "$3" -gt "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 — expected > $2, got '$3'"; fi; }
assert_contains() { case "$3" in *"$2"*) pass "$1";; *) fail "$1 — '$3' does not contain '$2'";; esac; }
# Assert two values differ (for "this must have changed" checks).
assert_ne()       { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1 — both sides are '$2'"; fi; }
# Assert a command/SQL produced a specific error fragment (for blocked-op / read-only stories).
assert_err()      { case "$3" in *"$2"*) pass "$1";; *) fail "$1 — error did not contain '$2'; got: $3";; esac; }

# psql binary inside the container. pgEdge + pgduckdb images have it on PATH;
# override via CF_PSQL for an image that doesn't (e.g. /usr/pgsql-17/bin/psql).
CF_PSQL="${CF_PSQL:-psql}"
CF_DBUSER="${CF_DBUSER:-coldfront}"
CF_DBNAME="${CF_DBNAME:-coldfront}"

# q <container> <sql>  — one -tA -c query; trimmed scalar/rows on stdout.
q()  { local c="$1"; shift; docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "$c" "$CF_PSQL" -tA -c "$*"; }
# qf <container>  — heredoc on stdin (-tA), for batched KEY:value blocks and multi-statement scripts.
qf() { local c="$1"; shift; docker exec -i -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "$c" "$CF_PSQL" -tA; }
# q_may <container> <sql>  — run, capture stdout+stderr, never fail the script (for negative/error stories).
q_may() { local c="$1"; shift; docker exec -e PGUSER="$CF_DBUSER" -e PGDATABASE="$CF_DBNAME" "$c" "$CF_PSQL" -tA -c "$*" 2>&1 || true; }

# extract KEY "$BLOCK"  — pull the value from a "KEY:value" line in a captured block.
extract() { echo "$2" | grep "^$1:" | head -1 | cut -d: -f2-; }

# require_base <pg>: resolve the base image the tree's recipe maps to
# (ci/base-ref.sh), make sure it is present locally or pullable, and export it
# as COLDFRONT_BASE for the app build. A base that is neither stops the run here
# and names the two ways to produce it.
require_base() {
    local pg="$1" ref err
    ref="$("${BASH_SOURCE[0]%/*}/base-ref.sh" "$pg")" || return 1
    if ! docker image inspect "$ref" >/dev/null 2>&1 && ! err="$(docker pull "$ref" 2>&1)"; then
        echo "base image $ref is not available (${err##*$'\n'})" >&2
        echo "  build it locally:  docker build -f docker/Dockerfile.duckdb15-base --build-arg PG_MAJOR=$pg -t $ref ." >&2
        echo "  or publish it:     gh workflow run base-image.yml --ref ${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}} -f push=true" >&2
        return 1
    fi
    export COLDFRONT_BASE="$ref"
    require_repo_client || return 1
}

# require_repo_client: resolve the pgEdge repo client cert (REPO_CLIENT_CRT /
# REPO_CLIENT_KEY, default <repo>/client.{crt,key}), fail if missing, export the
# paths for compose and set REPO_SECRET_ARGS for `docker build`.
require_repo_client() {
    local root crt key
    root="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
    crt="${REPO_CLIENT_CRT:-$root/client.crt}"
    key="${REPO_CLIENT_KEY:-$root/client.key}"
    if [ ! -r "$crt" ] || [ ! -r "$key" ]; then
        echo "pgEdge repository client certificate not found: need $crt and $key" >&2
        echo "  put client.crt and client.key at the repo root, or set REPO_CLIENT_CRT and REPO_CLIENT_KEY to their paths" >&2
        return 1
    fi
    REPO_CLIENT_CRT="$(cd "$(dirname "$crt")" && pwd)/$(basename "$crt")"
    REPO_CLIENT_KEY="$(cd "$(dirname "$key")" && pwd)/$(basename "$key")"
    export REPO_CLIENT_CRT REPO_CLIENT_KEY
    # compose (buildx bake) won't read secret files outside the project dir
    # without fs.read, and compose has no --allow flag.
    case "$REPO_CLIENT_CRT:$REPO_CLIENT_KEY" in
        "$root"/*:"$root"/*) ;;
        *) export BUILDX_BAKE_ENTITLEMENTS_FS=0;;
    esac
    # shellcheck disable=SC2034  # read by the scripts that source this file
    REPO_SECRET_ARGS=(--secret "id=repo_client_crt,src=$REPO_CLIENT_CRT"
                      --secret "id=repo_client_key,src=$REPO_CLIENT_KEY")
}

# summary  — print pass/fail tally; returns nonzero if any FAIL (drives matrix exit code).
summary() {
    echo -e "\n  Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
    [ "$FAIL" -eq 0 ]
}

# standby_up <primary-container> <standby-name>  — base-backup a read-only
# physical standby of <primary-container> onto a fresh container of the SAME
# image + network, via the entrypoint's COLDFRONT_STANDBY_OF branch, and wait
# until it accepts connections. Returns nonzero (and dumps the standby log) if it
# never comes up. Shared by ci/probe-standby.sh and the topology scripts (DRY).
standby_up() {
    local primary="$1" sb="$2" db_ip net img
    db_ip=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$primary")
    net=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$primary")
    img=$(docker inspect -f '{{.Config.Image}}' "$primary")
    docker rm -f "$sb" >/dev/null 2>&1 || true
    docker run -d --name "$sb" --network "$net" \
        -e PG_MAJOR="${PG_MAJOR:-18}" -e COLDFRONT_STANDBY_OF="$db_ip" "$img" >/dev/null || return 1
    for _ in $(seq 1 45); do
        docker exec "$sb" pg_isready -U "$CF_DBUSER" -d "$CF_DBNAME" >/dev/null 2>&1 && return 0
        sleep 2
    done
    docker logs "$sb" 2>&1 | tail -20
    return 1
}

# boot_secret_wait <container>: wait up to 30 s for the entrypoint's boot step
# to log that it wrote the DuckDB storage secret on <container>. The log spans
# restarts, and a line from an earlier boot still means the file is there,
# because a restart keeps the container's writable layer. A session reads the
# secret directory once, when its first DuckDB query starts its DuckDB
# instance, so a session whose instance started before the write never loads
# the secret.
boot_secret_wait() {
    local _
    for _ in $(seq 1 30); do
        docker logs "$1" 2>&1 | grep -F 'coldfront: wrote the DuckDB storage secret' >/dev/null && return 0
        sleep 1
    done
    return 1
}

# The single read-only-replica container name — shared by the probe and both topo
# scripts (they never run concurrently, so one name is safe and avoids divergence).
CF_STANDBY="${CF_STANDBY:-coldfront-standby}"

# topo_standby <primary-container>  — when the topology was invoked with --standby
# (STANDBY=1), base-backup a read-only physical replica of <primary-container> as
# $CF_STANDBY and set STANDBY_ARG to the journey's --standby flag; otherwise
# STANDBY_ARG stays empty. Exits the topology on bring-up failure. The ONE home
# for topo standby bring-up — neither topo script duplicates it.
STANDBY_ARG=()
topo_standby() {
    [ "${STANDBY:-0}" = 1 ] || return 0
    step "base-backup a read-only standby of $1"
    standby_up "$1" "$CF_STANDBY" || { echo "standby $CF_STANDBY did not come up"; exit 1; }
    # shellcheck disable=SC2034  # consumed as "${STANDBY_ARG[@]}" by topo/{vanilla,mesh}.sh, which source this file
    STANDBY_ARG=(--standby "$CF_STANDBY")
}

# topo_teardown  — the EXIT trap shared by topo/*.sh and the probe: unless --keep
# (KEEP=1), remove the standby (if any) and tear the compose stack down. Reads the
# caller's $KEEP and $COMPOSE. A failed cell first prints its servers' crash
# lines: a backend that crashed reads on the client side only as a lost
# connection, and the server's lines name the signal and the statement. The
# servers log to $PGDATA/log through the logging collector, not to stdout.
topo_teardown() {
    local rc=$? c purged down=0
    if [ "$rc" -ne 0 ]; then
        for c in $($COMPOSE ps -q 2>/dev/null) ${CF_STANDBY:-}; do
            docker exec "$c" sh -c 'cat "$PGDATA"/log/*.log' 2>/dev/null \
                | grep -E 'terminated by signal|Failed process was running|terminate called|PANIC' | tail -20
        done
    fi
    [ "${KEEP:-0}" = 1 ] && return 0
    docker rm -f "$CF_STANDBY" >/dev/null 2>&1 || true
    $COMPOSE down -v >/dev/null 2>&1 || down=$?
    # A cloud cell's leftovers, both made by the topology that set CELL_PREFIX:
    # the prefix, purged only once its writers are gone (AWS documents that
    # aborting an upload during a part upload "might or might not succeed"), so
    # a stack that did not come down leaves it, and before the identity
    # directory goes, since a local run's purge reads its session there; a
    # purge that leaves anything fails the cell. An Azure cell logs the CLI in
    # again first: its session lasts about an hour, the token file stays fresh.
    if [ -n "${CELL_PREFIX:-}" ]; then
        if [ "$down" -ne 0 ]; then
            echo "compose down failed, so $CELL_PREFIX is not purged" >&2; purged=1
        elif [ "$BACKEND" = azure-vended ] && ! az_login; then
            echo "the Azure login before the purge failed" >&2; purged=1
        else
            cloud_purge "$CELL_PREFIX/"; purged=$?
        fi
        rm -rf -- "$CF_LK_ENV_DIR"
        [ "$purged" -eq 0 ] || { echo "purge of $CELL_PREFIX failed" >&2; exit 1; }
    fi
}

# ── Cloud cells ───────────────────────────────────────────────────────────────
# cell_prefix: the key prefix one cloud cell writes under (the warehouse's
# key-prefix), and the only thing its purge removes:
# coldfront-ci/<UTC yyyymmddThhmmssZ>-<random>.
cell_prefix() { printf 'coldfront-ci/%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }

# pull_image <image>: pull with a retry, because a public registry refuses a
# pull over its per-second quota (ECR Public: one unauthenticated pull per
# second) and the refusal is momentary. Five attempts, the waits growing from
# 5 to 20 seconds.
pull_image() {
    local i
    for i in 1 2 3 4 5; do
        docker pull -q "$1" >/dev/null && return 0
        [ "$i" -lt 5 ] && sleep $((i * 5))
    done
    echo "pull_image: $1 could not be pulled" >&2
    return 1
}

# s3cli <args...>: the AWS CLI from AWS's own image, pinned by digest, so a
# host's CLI packaging cannot break a purge (Ubuntu's 2.31.35 build on Python
# 3.14 fails on list-objects-v2 before it sends a request). Its identity is the
# env file COLDFRONT_CLI_ENV names and nothing from the caller's shell: a local
# cell's session keys, or AWS_CONFIG_FILE and AWS_PROFILE for the token-based
# role chain, whose directory (COLDFRONT_CLOUD_DIR) is mounted at its own path
# so the config's file paths hold inside the container.
S3CLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.37.9@sha256:92de75724b6a746951f0e8b915d86bbccd7cb55aff96cd0cb4f7017272160780"
s3cli() {
    docker run --rm ${COLDFRONT_CLOUD_DIR:+-v "$COLDFRONT_CLOUD_DIR:$COLDFRONT_CLOUD_DIR:ro"} \
        --env-file "${COLDFRONT_CLI_ENV:?}" -e AWS_REGION="${COLDFRONT_AWS_REGION:-}" "$S3CLI_IMAGE" "$@"
}

# s3_purge <bucket> <prefix>: abort every incomplete multipart upload and
# delete every object under one cell's prefix, then list both again and fail
# unless nothing is left. Refuses a prefix that is not exactly one cell's: an
# empty one would empty the bucket, and one without its trailing slash would
# also match a longer sibling. In an unversioned bucket a delete is final, so an
# empty listing means no versions or delete markers either.
s3_purge() {
    local bucket="$1" prefix="$2" key upload_id objects uploads
    [[ $prefix =~ ^coldfront-ci/[0-9]{8}T[0-9]{6}Z-[0-9a-f]+/$ ]] || { echo "s3_purge: refusing prefix '$prefix'" >&2; return 1; }
    s3cli s3api list-multipart-uploads --bucket "$bucket" --prefix "$prefix" \
        --query 'Uploads[].[Key, UploadId] || `[]`' --output text |
    while IFS=$'\t' read -r key upload_id; do
        [ -n "$key" ] && s3cli s3api abort-multipart-upload --bucket "$bucket" --key "$key" --upload-id "$upload_id" </dev/null
    done
    s3cli s3 rm "s3://$bucket/$prefix" --recursive --only-show-errors
    objects=$(s3cli s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --query 'length(Contents || `[]`)' --output json)
    uploads=$(s3cli s3api list-multipart-uploads --bucket "$bucket" --prefix "$prefix" --query 'length(Uploads || `[]`)' --output json)
    echo "purged $prefix: $objects objects and $uploads incomplete uploads left"
    [ "$objects" = 0 ] && [ "$uploads" = 0 ]
}

# azcli <args...>: the Azure CLI from Microsoft's image, pinned by digest. Its
# login state lives in COLDFRONT_CLOUD_DIR/azure, mounted read-write, so one
# federated login (az_login) serves the calls that follow it; the token
# directory is mounted at its own path for the login.
AZCLI_IMAGE="mcr.microsoft.com/azure-cli:2.91.0@sha256:933eb8dcb81aecb6f77e03c5b8660f0a1dfa9e1d16525763a27f86ff3b83a044"
azcli() {
    docker run --rm -v "$COLDFRONT_CLOUD_DIR:$COLDFRONT_CLOUD_DIR" -e AZURE_CONFIG_DIR="$COLDFRONT_CLOUD_DIR/azure" \
        -e AZURE_CORE_OUTPUT=tsv "$AZCLI_IMAGE" az "$@"
}

# az_login: sign the CLI in as the managed identity with the job's OIDC token.
# The token lives a few minutes, the session it opens about an hour, so each
# subcommand of ci/cloud.sh logs in once with a fresh token.
az_login() {
    azcli login --service-principal --username "$COLDFRONT_AZURE_CLIENT_ID" --tenant "$COLDFRONT_AZURE_TENANT_ID" \
        --federated-token "$(cat "$COLDFRONT_AZURE_TOKEN_FILE")" --allow-no-subscriptions >/dev/null
}

# adls_purge <prefix>: delete one cell's directory under the filesystem and
# fail unless it is gone. `directory delete` is recursive; `exists` answers
# false only for a missing path and fails on anything else (a 403 included), so
# a permission problem never reads as a clean result. The same prefix guard as
# s3_purge, minus the slash the S3 key prefix carries.
adls_purge() {
    local dir="${1%/}"
    [[ $dir =~ ^coldfront-ci/[0-9]{8}T[0-9]{6}Z-[0-9a-f]+$ ]] || { echo "adls_purge: refusing prefix '$1'" >&2; return 1; }
    if [ "$(azcli storage fs directory exists --file-system "$COLDFRONT_AZURE_FILESYSTEM" --name "$dir" \
             --account-name "$COLDFRONT_AZURE_ACCOUNT" --auth-mode login --query exists)" = true ]; then
        azcli storage fs directory delete --file-system "$COLDFRONT_AZURE_FILESYSTEM" --name "$dir" \
            --account-name "$COLDFRONT_AZURE_ACCOUNT" --auth-mode login --yes >/dev/null
    fi
    local left; left=$(azcli storage fs directory exists --file-system "$COLDFRONT_AZURE_FILESYSTEM" --name "$dir" \
                        --account-name "$COLDFRONT_AZURE_ACCOUNT" --auth-mode login --query exists)
    echo "purged $dir: directory present afterwards: $left"
    [ "$left" = false ]
}

# cloud_purge <prefix>: the purge of the cell's cloud, chosen by the backend
# the topology runs with.
cloud_purge() {
    case "${BACKEND:-}" in
        aws-vended)   s3_purge "$COLDFRONT_AWS_BUCKET" "$1";;
        azure-vended) adls_purge "$1";;
        *) echo "cloud_purge: no cloud for backend '${BACKEND:-}'" >&2; return 1;;
    esac
}

# create_warehouse_and_seed <lk_ip> <wh_body>  — POST the (backend-specific) Lakekeeper
# warehouse with retry, then seed the 'default' Iceberg namespace. The seed is REQUIRED:
# DuckDB 1.5.x defers an Iceberg CREATE SCHEMA to transaction COMMIT while CREATE TABLE
# POSTs eagerly, so coldfront.create_iceberg_table (decoupled, one txn) 404s on a cold
# warehouse unless the namespace is pre-committed here as its own REST call. Exits the
# caller on warehouse-create failure. The ONE home for this — topo/vanilla.sh,
# topo/mesh.sh and ops.sh all call it (callers build the backend-specific <wh_body>).
create_warehouse_and_seed() {
    local lk_ip="$1" wh_body="$2" wh="" wid
    for _ in $(seq 1 15); do
        wh=$(curl -s "http://$lk_ip:8181/management/v1/warehouse" -X POST -H "Content-Type: application/json" -d "$wh_body" 2>&1)
        echo "$wh" | grep -q "warehouse-id" && break
        echo "$wh" | grep -qi "already exists" && { wh="warehouse-id (exists)"; break; }
        sleep 2
    done
    echo "$wh" | grep -q "warehouse-id" || { echo "warehouse creation failed after retries: $wh"; exit 1; }
    wid=$(echo "$wh" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    [ -z "$wid" ] && wid=$(curl -s "http://$lk_ip:8181/management/v1/warehouse" | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
    if [ -n "$wid" ]; then
        curl -s -X POST "http://$lk_ip:8181/catalog/v1/$wid/namespaces" \
            -H "Content-Type: application/json" -d '{"namespace":["public"]}' >/dev/null 2>&1 || true
    fi
}
