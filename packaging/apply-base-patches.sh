#!/usr/bin/env bash
# apply-base-patches.sh <family> <checkout>: apply to the git checkout every
# docker/<family>-*.patch that docker/Dockerfile.duckdb15-base copies in, in the
# recipe's order, so a package is built from the same patch list as the base
# image. git apply --check fails loudly on patch rot.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
patches="$(sed -n "s#^COPY \(docker/$1-[^[:space:]]*\.patch\).*#\1#p" "$root/docker/Dockerfile.duckdb15-base")"
[ -n "$patches" ] || { echo "no docker/$1-*.patch in the base recipe" >&2; exit 1; }
for p in $patches; do
    git -C "$2" apply --check "$root/$p"
    git -C "$2" apply         "$root/$p"
done
