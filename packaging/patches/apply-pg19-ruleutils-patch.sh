#!/usr/bin/env bash
# Apply pg_duckdb-pg19-ruleutils.patch to a pg_duckdb checkout. Shared by
# packaging/pg_duckdb/build-rpm.sh and build-deb.sh so both formats agree on
# when the patch is needed.
#
# Usage: apply-pg19-ruleutils-patch.sh <pg_duckdb-checkout> <pg-major>
#
# Exits 0 leaving the tree untouched below PG 19 (the vendored file is #if'd to
# 19, so 16/17/18 builds must not be held hostage to it) and when the change is
# already in the tree — a re-run, or upstream refreshed its vendored copy.
# Anything else is patch rot: exit 1, so the build fails loudly instead of
# compiling a deparser that does not match PG 19.
set -euo pipefail

SRC="${1:?usage: $0 <pg_duckdb-checkout> <pg-major>}"
PG_MAJOR="${2:?usage: $0 <pg_duckdb-checkout> <pg-major>}"
PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pg_duckdb-pg19-ruleutils.patch"

if [ "$PG_MAJOR" -lt 19 ]; then
    echo "pg19-ruleutils: PG ${PG_MAJOR} — not needed, skipped"
    exit 0
fi

if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
    git -C "$SRC" apply "$PATCH"
    echo "pg19-ruleutils: applied"
elif git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "pg19-ruleutils: already present — skipped (if upstream refreshed the vendored copy, drop the patch)"
else
    echo "pg19-ruleutils: no longer applies to $(git -C "$SRC" rev-parse --short HEAD) — refresh or drop it" >&2
    exit 1
fi
