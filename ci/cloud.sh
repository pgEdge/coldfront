#!/bin/bash
# ci/cloud.sh: the cloud side of a GitHub cloud job. Usage:
#
#   ci/cloud.sh <aws|azure> run -- <command...>
#                        Request the job's OIDC token for the cloud, keep it
#                        fresh while the command runs (GitHub's tokens live a
#                        few minutes, and Lakekeeper re-reads the file whenever
#                        it rebuilds its credential), sign the cloud's CLI in,
#                        and run the command.
#   ci/cloud.sh <aws|azure> finish
#                        Purge every prefix the job's cells recorded and verify
#                        each is empty. Runs under `if: always()`, so a failed
#                        or cancelled job still cleans up.
#   ci/cloud.sh <aws|azure> sweep
#                        Purge every prefix older than 6 hours, GitHub's maximum
#                        job length, so none can belong to a running job, and
#                        fail if there was anything to purge: a leak from an
#                        earlier run is a failure, not a note.
#
# Everything it writes goes under one world-readable directory, because the
# Lakekeeper container reads the token as another user, and the CLI containers
# mount the same directory at the same path.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/lib.sh"
CLOUD="${1:-}"; shift || true
# shellcheck disable=SC2034  # BACKEND picks the purge in cloud_purge (ci/lib.sh)
case "$CLOUD" in
  aws)   : "${COLDFRONT_AWS_BUCKET:?}" "${COLDFRONT_AWS_REGION:?}" "${COLDFRONT_AWS_CI_ROLE_ARN:?}" \
           "${COLDFRONT_AWS_DATA_ROLE_ARN:?}" "${COLDFRONT_AWS_EXTERNAL_ID:?}"
         AUDIENCE=sts.amazonaws.com; BACKEND=aws-vended;;
  azure) : "${COLDFRONT_AZURE_ACCOUNT:?}" "${COLDFRONT_AZURE_FILESYSTEM:?}" "${COLDFRONT_AZURE_CLIENT_ID:?}" \
           "${COLDFRONT_AZURE_TENANT_ID:?}"
         AUDIENCE=api://AzureADTokenExchange; BACKEND=azure-vended;;
  *) echo "usage: ci/cloud.sh <aws|azure> run -- <command...> | finish | sweep" >&2; exit 2;;
esac

DIR="${RUNNER_TEMP:-/tmp}/coldfront-$CLOUD"
mkdir -p "$DIR" && chmod 755 "$DIR"
TOKEN="$DIR/token"

# fetch_token: one OIDC token for the cloud's audience, masked in the log and
# written atomically, so a reader never sees a partial file.
fetch_token() {
    local t
    t=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$AUDIENCE" | jq -er .value) || return 1
    echo "::add-mask::$t"
    printf '%s' "$t" > "$TOKEN.new" && chmod 644 "$TOKEN.new" && mv "$TOKEN.new" "$TOKEN"
}

# setup: the token, the cloud CLI's identity (AWS: the role chain, the GitHub
# role from the token and the data role from it with the external ID; Azure: a
# federated login as the managed identity), and the variables the topology and
# the purge read.
setup() {
    fetch_token || { echo "cloud.sh: no OIDC token (id-token: write missing?)" >&2; exit 1; }
    export COLDFRONT_CLOUD_DIR="$DIR" COLDFRONT_CI_PREFIXES="$DIR/prefixes"
    touch "$COLDFRONT_CI_PREFIXES"
    if [ "$CLOUD" = azure ]; then
        export COLDFRONT_AZURE_TOKEN_FILE="$TOKEN"
        mkdir -p "$DIR/azure" && chmod 777 "$DIR/azure"
        az_login || { echo "cloud.sh: the federated login failed" >&2; exit 1; }
        echo "identity: $(azcli account show --query user.name 2>/dev/null || echo "$COLDFRONT_AZURE_CLIENT_ID")"
        return
    fi
    cat > "$DIR/config" <<EOF
[profile ci]
role_arn = $COLDFRONT_AWS_CI_ROLE_ARN
web_identity_token_file = $TOKEN
role_session_name = coldfront-ci
region = $COLDFRONT_AWS_REGION

[profile data]
role_arn = $COLDFRONT_AWS_DATA_ROLE_ARN
source_profile = ci
external_id = $COLDFRONT_AWS_EXTERNAL_ID
role_session_name = coldfront-ci
region = $COLDFRONT_AWS_REGION
EOF
    chmod 644 "$DIR/config"
    export AWS_CONFIG_FILE="$DIR/config" AWS_PROFILE=data COLDFRONT_AWS_TOKEN_FILE="$TOKEN"
    local arn; arn=$(s3cli sts get-caller-identity --query Arn --output text) || { echo "cloud.sh: the role chain failed" >&2; exit 1; }
    echo "identity: $arn"
}

# list_prefixes: every cell prefix in the store, one `coldfront-ci/<ts>-<id>/`
# per line, for the sweep.
list_prefixes() {
    if [ "$CLOUD" = aws ]; then
        s3cli s3api list-objects-v2 --bucket "$COLDFRONT_AWS_BUCKET" --prefix coldfront-ci/ --delimiter / \
            --query 'CommonPrefixes[].[Prefix] || `[]`' --output text
    else
        # A missing coldfront-ci directory is an empty listing; any other failed answer fails the caller.
        local there; there=$(azcli storage fs directory exists --file-system "$COLDFRONT_AZURE_FILESYSTEM" --name coldfront-ci \
                              --account-name "$COLDFRONT_AZURE_ACCOUNT" --auth-mode login --query exists) || return 1
        [ "$there" = false ] && return 0
        azcli storage fs directory list --file-system "$COLDFRONT_AZURE_FILESYSTEM" --path coldfront-ci --recursive false \
            --account-name "$COLDFRONT_AZURE_ACCOUNT" --auth-mode login --query '[].name' | sed 's#$#/#'
    fi
}

case "${1:-}" in
  run)
    shift; [ "${1:-}" = -- ] && shift
    setup
    ( while sleep 120; do fetch_token || echo "cloud.sh: token refresh failed" >&2; done ) &
    refresher=$!
    "$@"; rc=$?
    kill "$refresher" 2>/dev/null
    exit "$rc";;
  finish)
    setup
    # The cells' containers first: a cancelled job leaves them running, mid-write.
    docker ps -q --filter name=coldfront- | xargs -r docker rm -f >/dev/null
    rc=0
    while read -r p; do
        [ -n "$p" ] && { cloud_purge "$p" || rc=1; }
    done < "$COLDFRONT_CI_PREFIXES"
    exit "$rc";;
  sweep)
    setup
    cutoff=$(date -u -d '-6 hours' +%Y%m%dT%H%M%SZ); n=0
    prefixes=$(LC_ALL=C list_prefixes) || { echo "::error::sweep: the listing failed" >&2; exit 1; }
    while read -r p; do
        [ -n "$p" ] || continue
        ts=${p#coldfront-ci/}; ts=${ts%%-*}
        [[ $ts =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && [[ $ts < $cutoff ]] || continue
        echo "::error::sweep: $p is older than 6 hours and still in the store"
        cloud_purge "$p" || exit 1
        n=$((n + 1))
    done <<< "$prefixes"
    [ "$n" -eq 0 ] || { echo "sweep: purged $n prefix(es) an earlier run left behind" >&2; exit 1; }
    echo "sweep: nothing older than 6 hours under coldfront-ci/";;
  *) echo "usage: ci/cloud.sh <aws|azure> run -- <command...> | finish | sweep" >&2; exit 2;;
esac
