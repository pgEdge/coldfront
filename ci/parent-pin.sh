#!/bin/bash
# ci/parent-pin.sh: fail when a pgEdge Postgres image pinned in
# docker/Dockerfile.duckdb15 differs from the image its floating tag points at.
#
# A pin is an immutable tag, <major>.<minor>-spock<x.y.z>-<flavor>-<epoch>, so
# every build starts from the same image. The floating tag of the same major,
# <major>-spock<x>-<flavor>, follows pgEdge's latest publication, and a pin
# that differs from it is behind.
#
# Usage: ci/parent-pin.sh
set -euo pipefail
cd "$(dirname "$0")/.."

digest() { docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$1"; }

mapfile -t pins < <(sed -nE 's/^FROM (ghcr\.io\/pgedge\/pgedge-postgres:[^ ]+).*/\1/p' docker/Dockerfile.duckdb15)
[ "${#pins[@]}" -gt 0 ] || { echo "no pgEdge Postgres pin in docker/Dockerfile.duckdb15" >&2; exit 1; }

rc=0
for pin in "${pins[@]}"; do
    floating=$(sed -E 's/:([0-9]+)\.[0-9]+-spock([0-9]+)[0-9.]*-(.+)-[0-9]+$/:\1-spock\2-\3/' <<<"$pin")
    if [ "$floating" = "$pin" ]; then
        echo "not an immutable tag: $pin" >&2; rc=1
    elif ! pinned=$(digest "$pin") || ! latest=$(digest "$floating"); then
        echo "cannot read the digests of $pin and $floating" >&2; rc=1
    elif [ "$pinned" = "$latest" ]; then
        echo "current: $pin"
    else
        echo "behind:  $pin is not $floating" >&2; rc=1
    fi
done
exit "$rc"
