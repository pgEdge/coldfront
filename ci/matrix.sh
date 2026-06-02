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
cell_vanilla_tiered()            { "$SCRIPT_DIR/topo/vanilla.sh" --pg "$1" --mode tiered --regress; }
cell_vanilla_decoupled()         { "$SCRIPT_DIR/topo/vanilla.sh" --pg "$1" --mode decoupled; }
cell_mesh_tiered()               { "$SCRIPT_DIR/topo/mesh.sh"    --pg "$1" --mode tiered; }
cell_mesh_decoupled()            { "$SCRIPT_DIR/topo/mesh.sh"    --pg "$1" --mode decoupled; }
cell_vanilla_tiered_standby()    { "$SCRIPT_DIR/topo/vanilla.sh" --pg "$1" --mode tiered --standby; }
cell_vanilla_decoupled_standby() { "$SCRIPT_DIR/topo/vanilla.sh" --pg "$1" --mode decoupled --standby; }
cell_mesh_tiered_standby()       { "$SCRIPT_DIR/topo/mesh.sh"    --pg "$1" --mode tiered --standby; }
cell_mesh_decoupled_standby()    { "$SCRIPT_DIR/topo/mesh.sh"    --pg "$1" --mode decoupled --standby; }

# coverage_table  — print every matrix cell with RUN / PENDING(reason). No
# cell is ever silently omitted; PENDING states what is still required.
coverage_table() {
    step "MATRIX COVERAGE"
    # All majors RUN: cold reads/writes resolve their S3 credential from a DuckDB
    # persistent secret (coldfront.set_storage_secret), loaded at instance init,
    # so the lazy first-touch attach works uniformly on 16/17/18 — no version gate.
    local pg topo mode tgt
    for pg in 18 17 16; do
      for topo in vanilla mesh; do
        for mode in tiered decoupled; do
          for tgt in primary standby; do
            printf '    pg%-2s · %-7s · %-9s · %-7s : %s\n' "$pg" "$topo" "$mode" "$tgt" "RUN"
          done
        done
      done
    done
}

# ── Drive ─────────────────────────────────────────────────────────────────────
preflight

case "$SCOPE" in
  quick)
    run_cell "pg18·vanilla·tiered·primary" cell_vanilla_tiered 18
    ;;
  full)
    # PG18 → PG17 → PG16 (reference major first). Same cell set per major; the
    # journey is version-agnostic and the persistent-secret attach path is identical.
    for pg in 18 17 16; do
      run_cell "pg${pg}·vanilla·tiered·primary"    cell_vanilla_tiered            "$pg"
      run_cell "pg${pg}·vanilla·decoupled·primary" cell_vanilla_decoupled         "$pg"
      run_cell "pg${pg}·mesh·tiered·primary"       cell_mesh_tiered               "$pg"
      run_cell "pg${pg}·mesh·decoupled·primary"    cell_mesh_decoupled            "$pg"
      run_cell "pg${pg}·vanilla·tiered·standby"    cell_vanilla_tiered_standby    "$pg"
      run_cell "pg${pg}·vanilla·decoupled·standby" cell_vanilla_decoupled_standby "$pg"
      run_cell "pg${pg}·mesh·tiered·standby"       cell_mesh_tiered_standby       "$pg"
      run_cell "pg${pg}·mesh·decoupled·standby"    cell_mesh_decoupled_standby    "$pg"
    done
    coverage_table
    echo -e "\n  NOTE: only verified cells RUN. PENDING cells are tracked, not skipped silently."
    ;;
esac

echo -e "\n${YELLOW}========================================${NC}"
echo -e "  Preflight + cell-level — Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo -e "${YELLOW}========================================${NC}"
[ "$FAIL" -eq 0 ] && [ "$CELL_FAIL" -eq 0 ]
