#!/bin/bash
# ci/base-ref.sh [pg]: the base image the tree's recipe maps to.
#
# The recipe is docker/Dockerfile.duckdb15-base plus every file its COPY lines
# take from the tree. Their blob ids (git hash-object on the working tree, so an
# uncommitted edit already counts) are hashed together into an 8-hex suffix.
# With no argument prints the suffix, r<hash>; with a PG major prints the full
# image ref, ghcr.io/pgedge/coldfront-duckdb-base:pg<major>-r<hash>.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
recipe=docker/Dockerfile.duckdb15-base
files=("$recipe")
while read -r f; do files+=("$f"); done < <(sed -n 's/^COPY \([^-][^[:space:]]*\).*/\1/p' "$recipe")
hash="$(git hash-object "${files[@]}" | git hash-object --stdin | cut -c1-8)"
case "${1:-}" in
    "") echo "r$hash";;
    *)  echo "ghcr.io/pgedge/coldfront-duckdb-base:pg$1-r$hash";;
esac
