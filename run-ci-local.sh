#!/bin/bash
# run-ci-local.sh — fast pre-commit gate.
#
# Thin wrapper over the CI matrix's quick cell: PG18 · vanilla · tiered ·
# primary. ci/matrix.sh runs the host-side preflight (gofmt, go vet,
# golangci-lint, shellcheck, hadolint, actionlint, unit tests, build), brings
# up the stack, runs the pg_regress
# unit layer, and
# walks the canonical user journey (ci/journey.sh). The full deployment matrix
# is `ci/matrix.sh --full`.
#
# Per CLAUDE.md, GitHub Actions must run the identical ci/matrix.sh steps.
set -euo pipefail
cd "$(dirname "$0")"
# With no pgEdge repo client cert present, the image build goes without one
# (ci/lib.sh). GitHub Actions calls ci/matrix.sh itself and never sets this.
export REPO_NO_CLIENT_CERT=1
exec ./ci/matrix.sh --quick
