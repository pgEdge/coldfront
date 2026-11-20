#!/bin/bash
# ci/parent-pin.sh: fail when pgEdge has published a newer Postgres image than
# one pinned in docker/Dockerfile.duckdb15-base, and name the newer image.
#
# A pin is an immutable tag, <major>.<minor>-spock<x.y.z>-<flavor>-<epoch>, so
# every build starts from the same image. The floating tag of the same major,
# <major>-spock<x>-<flavor>, follows pgEdge's latest publication. When the two
# differ, pgEdge has published a newer image. Builds keep using the pin until it
# is changed, and the error names the newer image's immutable tag.
#
# Usage: ci/parent-pin.sh
set -euo pipefail
cd "$(dirname "$0")/.."

repo=pgedge/pgedge-postgres
recipe=docker/Dockerfile.duckdb15-base

# The sha256 of an image's raw manifest is its digest.
digest() { docker buildx imagetools inspect --raw "ghcr.io/$repo:$1" | sha256sum; }

# Every tag in the repository, newest version first.
tags() {
    local token
    token=$(curl -fsS "https://ghcr.io/token?scope=repository:$repo:pull" | jq -er .token)
    curl -fsS -H "Authorization: Bearer $token" "https://ghcr.io/v2/$repo/tags/list?n=10000" | jq -er '.tags[]' | sort -rV
}

mapfile -t pins < <(sed -nE "s|^FROM ghcr\.io/$repo:([^ ]+).*|\1|p" "$recipe")
[ "${#pins[@]}" -gt 0 ] || { echo "no pgEdge Postgres pin in $recipe" >&2; exit 1; }

rc=0
for pin in "${pins[@]}"; do
    if ! [[ $pin =~ ^([0-9]+)\.[0-9]+-spock([0-9]+)(\.[0-9]+)*-(.+)-[0-9]+$ ]]; then
        echo "not an immutable tag: $pin" >&2; rc=1; continue
    fi
    major=${BASH_REMATCH[1]} spock=${BASH_REMATCH[2]} flavor=${BASH_REMATCH[4]}
    floating=$major-spock$spock-$flavor
    if ! pinned=$(digest "$pin") || ! latest=$(digest "$floating"); then
        echo "cannot read the digests of $pin and $floating" >&2; rc=1
    elif [ "$pinned" = "$latest" ]; then
        echo "current: $pin"
    else
        # The immutable tags newer than the pin, newest first, hold the floating tag's image.
        newer="an image no immutable tag names"
        for t in $(tags | grep -E "^$major\.[0-9]+-spock$spock(\.[0-9]+)*-$flavor-[0-9]+$"); do
            [ "$t" != "$pin" ] || break
            [ "$(digest "$t")" != "$latest" ] || { newer=$t; break; }
        done
        echo "::error title=newer pgEdge image for PG $major::$floating now points at $newer, and $recipe pins $pin. Builds still use the pin and are unaffected. To move to the newer image, change the pin and publish the base image with base-image.yml."
        rc=1
    fi
done
exit "$rc"
