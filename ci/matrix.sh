#!/bin/bash
# ci/matrix.sh — the ColdFront CI gate.
#
# Runs the host-side preflight ONCE (gofmt, go vet, golangci-lint, unit tests, build),
# then exercises the canonical user journey (ci/journey.sh) across deployment
# cells. The journey is the single spec; a "cell" is one
# PG-major × topology × mode × target combination. Per-cell the topology script
# brings the stack up, runs the pg_regress unit layer + the journey, and tears
# down.
#
# Usage:
#   ci/matrix.sh --quick   one verified cell (PG18 · vanilla · tiered · primary)
#                          plus the pg_regress unit layer — the fast pre-commit
#                          gate. run-ci-local.sh is a thin wrapper over this.
#   ci/matrix.sh --full    the whole matrix. Cells without a verified topology
#                          yet are listed as PENDING with the reason — never
#                          skipped silently — so coverage is always explicit.
#
# Matrix dimensions (beta target):
#   PG major : 16 · 17 · 18
#   topology : vanilla (single node) · mesh (3-node Spock)
#   mode     : tiered (hot PG + cold Iceberg) · decoupled (all-Iceberg)
#   target   : primary (read+write) · standby (read-only physical replica)
# Failover is delegated to Patroni and is out of scope (see ci/runbooks/).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=ci/lib.sh
source "$SCRIPT_DIR/lib.sh"
cd "$ROOT"

SCOPE=""
while [ $# -gt 0 ]; do case "$1" in
  --quick) SCOPE="quick"; shift;;
  --full)  SCOPE="full";  shift;;
  *) echo "matrix.sh: unknown arg $1"; exit 2;;
esac; done
[ -n "$SCOPE" ] || { echo "usage: ci/matrix.sh --quick|--full"; exit 2; }

# ── Preflight (host-side, once) ──────────────────────────────────────────────
preflight() {
    step "preflight 1: gofmt"
    if [ -n "$(gofmt -l .)" ]; then gofmt -d .; fail "code is not formatted"; exit 1; fi
    pass "formatting ok"

    step "preflight 2: go vet"
    if ! go vet ./...; then fail "go vet found issues"; exit 1; fi
    pass "vet clean"

    step "preflight 3: golangci-lint"
    local linter="${GOLANGCI_LINT:-$(command -v golangci-lint || echo "$HOME/go/bin/golangci-lint")}"
    if [ ! -x "$linter" ]; then
        fail "golangci-lint not found (go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest or set GOLANGCI_LINT)"
        exit 1
    fi
    if ! "$linter" run ./...; then fail "golangci-lint found issues"; exit 1; fi
    pass "lint clean"

    step "preflight 4: unit tests"
    if ! make test 2>&1; then fail "unit tests"; exit 1; fi
    pass "unit tests"

    step "preflight 5: build"
    if ! make build 2>&1; then fail "build"; exit 1; fi
    pass "build ($(ls -lh bin/archiver 2>/dev/null | awk '{print $5}'))"
}

# ── Cells ────────────────────────────────────────────────────────────────────
CELL_FAIL=0
# run_cell <name> <command...>  — run one cell; aggregate its exit code.
run_cell() {
    local name="$1"; shift
    step "CELL ▶ $name"
    if "$@"; then pass "cell: $name"; else fail "cell: $name"; CELL_FAIL=$((CELL_FAIL + 1)); fi
}

# Cells, parameterized by PG major ($1). The topology script owns bring-up, the
# journey, and teardown; --regress runs the pg_regress unit layer (extension
# SQL/hook tests, mode-independent) once per PG major, on the vanilla·tiered
# cell. The journey + assertions are identical across PG majors. Mesh cells run
# a 3-node Spock stack (MESH=on, same image) and add the mesh-only stories
# (cross-node visibility / R-A bakery). Standby cells base-back a read-only
# physical replica and exercise cross-tier reads + clean read-only write
# rejection (gated by ci/probe-standby.sh).
# compose_for <topology> <backend>  — the compose file for a (topology, backend)
# pair. azure has its own composes (the prebuilt coldfront-duckdb15:pg<major>
# image + ADLS storage profile); s3 and gcs share the regular composes, which now
# build docker/Dockerfile.duckdb15 inline — gcs is just the s3 path aimed at
# storage.googleapis.com (HMAC), no image difference. Every cell is 1.5.x.
compose_for() {
    case "$1/$2" in
        vanilla/azure) echo docker-compose.matrix-azure.yml;;
        mesh/azure)    echo docker-compose.mesh-azure.yml;;
        vanilla/*)     echo docker-compose.matrix.yml;;
        mesh/*)        echo docker-compose.mesh.yml;;
    esac
}

# prebuild_duckdb15 <pg>  — the azure composes reference a prebuilt image
# (coldfront-duckdb15:pg<major>), not an inline build, so build it once per PG
# major before any azure cell. Layers are shared with the regular composes' inline
# duckdb15 build, so after the first this just retags. s3/gcs need no prebuild.
prebuild_duckdb15() {
    local pg="$1"
    step "prebuild coldfront-duckdb15:pg${pg} (azure image)"
    if docker build -f docker/Dockerfile.duckdb15 --build-arg PG_MAJOR="$pg" \
           -t "coldfront-duckdb15:pg${pg}" . >/dev/null 2>&1; then
        pass "image coldfront-duckdb15:pg${pg}"
    else
        fail "prebuild coldfront-duckdb15:pg${pg}"; return 1
    fi
}

# vcell <pg> <mode> <backend> <target> [regress]  — one vanilla (single-node) cell.
# --regress runs the pg_regress unit layer on the same bring-up (used once per PG
# major on s3·vanilla·tiered·primary). --standby base-backs a read-only replica.
vcell() {
    local pg="$1" mode="$2" be="$3" tgt="$4" reg="${5:-}"
    local cf; cf="$(compose_for vanilla "$be")"
    local a=(--pg "$pg" --mode "$mode" --backend "$be" --compose "$cf")
    [ "$tgt" = standby ] && a+=(--standby)
    [ "$reg" = regress ] && a+=(--regress)
    "$SCRIPT_DIR/topo/vanilla.sh" "${a[@]}"
}

# mcell <pg> <mode> <backend> <target>  — one mesh (3-node Spock) cell. Adds the
# mesh-only stories (cross-node visibility, R-A bakery). --standby base-backs a
# read-only physical replica of db1.
mcell() {
    local pg="$1" mode="$2" be="$3" tgt="$4"
    local cf; cf="$(compose_for mesh "$be")"
    local a=(--pg "$pg" --mode "$mode" --backend "$be" --compose "$cf")
    [ "$tgt" = standby ] && a+=(--standby)
    "$SCRIPT_DIR/topo/mesh.sh" "${a[@]}"
}

# backend_ready <backend>  — s3 is hermetic (SeaweedFS), always RUN. azure/gcs run
# against real cloud stores and are gated on their creds being present in env.
backend_ready() {
    case "$1" in
        s3)    return 0;;
        azure) [ -n "${COLDFRONT_AZURE_CONNECTION_STRING:-}" ];;
        gcs)   [ -n "${COLDFRONT_GCS_ACCESS_KEY:-}" ];;
        *)     return 1;;
    esac
}

# coverage_table  — print every matrix cell with RUN / PENDING(reason). No cell is
# ever silently omitted; PENDING states what creds would flip it to RUN. The full
# grid is PG{16,17,18} × {vanilla,mesh} × {tiered,decoupled} × {primary,standby} ×
# {s3,azure,gcs} = 72 cells, every one on the DuckDB 1.5.x patched-iceberg image.
coverage_table() {
    step "MATRIX COVERAGE (full grid = 72 cells, all on DuckDB 1.5.x)"
    local pg topo mode tgt be st
    for pg in 18 17 16; do
      for be in s3 azure gcs; do
        if backend_ready "$be"; then st="RUN"; else
          case "$be" in
            azure) st="PENDING (needs COLDFRONT_AZURE_* creds)";;
            gcs)   st="PENDING (needs COLDFRONT_GCS_* creds)";;
            *)     st="PENDING";;
          esac
        fi
        for topo in vanilla mesh; do
          for mode in tiered decoupled; do
            for tgt in primary standby; do
              printf '    pg%-2s · %-7s · %-9s · %-7s · %-5s : %s\n' "$pg" "$topo" "$mode" "$tgt" "$be" "$st"
            done
          done
        done
      done
    done
}

# ── Drive ─────────────────────────────────────────────────────────────────────
preflight

case "$SCOPE" in
  quick)
    run_cell "pg18·vanilla·tiered·primary·s3" vcell 18 tiered s3 primary regress
    ;;
  full)
    # The whole grid: PG{16,17,18} × {vanilla,mesh} × {tiered,decoupled} ×
    # {primary,standby} × {s3,azure,gcs} = 72 cells, every one on the DuckDB 1.5.x
    # patched-iceberg image. PG18 → 17 → 16 (reference major first); the journey is
    # version-agnostic and the persistent-secret attach path is identical. s3 is
    # hermetic (always RUN); azure/gcs are creds-gated — absent creds report the
    # backend PENDING (never silently skipped). pg_regress (the unit layer) runs
    # once per major on s3·vanilla·tiered·primary.
    for pg in 18 17 16; do
      # azure cells consume a prebuilt image; build it once per major (cheap after
      # the regular composes' inline 1.5 build — shared layers).
      backend_ready azure && { prebuild_duckdb15 "$pg" || CELL_FAIL=$((CELL_FAIL + 1)); }
      for be in s3 azure gcs; do
        if ! backend_ready "$be"; then
          step "BACKEND $be (pg${pg}) — PENDING (creds absent; set its COLDFRONT_* env to RUN)"
          continue
        fi
        for mode in tiered decoupled; do
          for tgt in primary standby; do
            reg=""
            [ "$be" = s3 ] && [ "$mode" = tiered ] && [ "$tgt" = primary ] && reg=regress
            run_cell "pg${pg}·vanilla·${mode}·${tgt}·${be}" vcell "$pg" "$mode" "$be" "$tgt" "$reg"
            run_cell "pg${pg}·mesh·${mode}·${tgt}·${be}"     mcell "$pg" "$mode" "$be" "$tgt"
          done
        done
      done
    done
    coverage_table
    echo -e "\n  NOTE: s3 is hermetic and always RUN; azure/gcs RUN when their creds are present, else PENDING (tracked, never skipped silently)."
    ;;
esac

echo -e "\n${YELLOW}========================================${NC}"
echo -e "  Preflight + cell-level — Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo -e "${YELLOW}========================================${NC}"
[ "$FAIL" -eq 0 ] && [ "$CELL_FAIL" -eq 0 ]
