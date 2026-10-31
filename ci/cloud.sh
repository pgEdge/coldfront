#!/bin/bash
# ci/cloud.sh: the AWS side of a GitHub cloud job. Three subcommands:
#
#   run -- <command...>  Request the job's OIDC token for AWS, keep it fresh
#                        while the command runs (GitHub's tokens live a few
#                        minutes, and Lakekeeper re-reads the file whenever it
#                        rebuilds its credential), point the AWS CLI at the role
#                        chain, and run the command.
#   finish               Purge every prefix the job's cells recorded and verify
#                        each is empty. Runs under `if: always()`, so a failed
#                        or cancelled job still cleans up.
#   sweep                Purge every prefix older than 6 hours, GitHub's maximum
#                        job length, so none can belong to a running job, and
#                        fail if there was anything to purge: a leak from an
#                        earlier run is a failure, not a note.
#
# Everything it writes goes under one world-readable directory, because the
# Lakekeeper container reads the token as another user, and the CLI container
# mounts the same directory at the same path.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/lib.sh"
: "${COLDFRONT_AWS_BUCKET:?}" "${COLDFRONT_AWS_REGION:?}" "${COLDFRONT_AWS_CI_ROLE_ARN:?}" \
  "${COLDFRONT_AWS_DATA_ROLE_ARN:?}" "${COLDFRONT_AWS_EXTERNAL_ID:?}"

DIR="${RUNNER_TEMP:-/tmp}/coldfront-aws"
mkdir -p "$DIR" && chmod 755 "$DIR"
TOKEN="$DIR/token"

# fetch_token: one OIDC token with audience sts.amazonaws.com, masked in the
# log and written atomically, so a reader never sees a partial file.
fetch_token() {
    local t
    t=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -er .value) || return 1
    echo "::add-mask::$t"
    printf '%s' "$t" > "$TOKEN.new" && chmod 644 "$TOKEN.new" && mv "$TOKEN.new" "$TOKEN"
}

# setup: the token, the CLI's role chain (the GitHub role from the token, the
# data role from it with the external ID), and the variables the topology and
# the purge read.
setup() {
    fetch_token || { echo "cloud.sh: no OIDC token (id-token: write missing?)" >&2; exit 1; }
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
    export AWS_CONFIG_FILE="$DIR/config" AWS_PROFILE=data COLDFRONT_AWS_DIR="$DIR" COLDFRONT_AWS_TOKEN_FILE="$TOKEN"
    export COLDFRONT_CI_PREFIXES="$DIR/prefixes"
    touch "$COLDFRONT_CI_PREFIXES"
    echo "identity: $(s3cli sts get-caller-identity --query Arn --output text)"
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
    rc=0
    while read -r p; do
        [ -n "$p" ] && { s3_purge "$COLDFRONT_AWS_BUCKET" "$p" || rc=1; }
    done < "$COLDFRONT_CI_PREFIXES"
    exit "$rc";;
  sweep)
    setup
    cutoff=$(date -u -d '-6 hours' +%Y%m%dT%H%M%SZ); n=0
    while read -r p; do
        [ -n "$p" ] || continue
        ts=${p#coldfront-ci/}; ts=${ts%%-*}
        [[ $ts =~ ^[0-9]{8}T[0-9]{6}Z$ ]] && [[ $ts < $cutoff ]] || continue
        echo "::error::sweep: $p is older than 6 hours and still in the bucket"
        s3_purge "$COLDFRONT_AWS_BUCKET" "$p" || exit 1
        n=$((n + 1))
    done < <(LC_ALL=C s3cli s3api list-objects-v2 --bucket "$COLDFRONT_AWS_BUCKET" --prefix coldfront-ci/ --delimiter / \
                --query 'CommonPrefixes[].[Prefix] || `[]`' --output text)
    [ "$n" -eq 0 ] || { echo "sweep: purged $n prefix(es) an earlier run left behind" >&2; exit 1; }
    echo "sweep: nothing older than 6 hours under coldfront-ci/";;
  *) echo "usage: ci/cloud.sh run -- <command...> | finish | sweep" >&2; exit 2;;
esac
