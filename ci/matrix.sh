#!/bin/bash
# ci/matrix.sh — the ColdFront CI gate.
#
# Runs the host-side preflight ONCE (gofmt, golangci-lint, unit tests, build),
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

    step "preflight 2: golangci-lint"
    local linter="${GOLANGCI_LINT:-$(command -v golangci-lint || echo "$HOME/go/bin/golangci-lint")}"
    if [ ! -x "$linter" ]; then
        fail "golangci-lint not found (go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest or set GOLANGCI_LINT)"
        exit 1
    fi
    if ! "$linter" run ./...; then fail "golangci-lint found issues"; exit 1; fi
    pass "lint clean"

    step "preflight 3: unit tests"
    if ! make test 2>&1; then fail "unit tests"; exit 1; fi
    pass "unit tests"

    step "preflight 4: build"
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

# Verified cells. The topology script owns bring-up, the journey, and teardown;
# --regress runs the pg_regress unit layer (extension SQL/hook tests, mode-
# independent) so it only needs to run on one cell per PG major.
cell_pg18_vanilla_tiered() {
    "$SCRIPT_DIR/topo/vanilla.sh" --mode tiered --regress
}
cell_pg18_vanilla_decoupled() {
    "$SCRIPT_DIR/topo/vanilla.sh" --mode decoupled
}
# Mesh cells: 3-node Spock on the same image (MESH=on). topo/mesh.sh forms the
# mesh and runs the journey + mesh-only stories (cross-node visibility / R-A
# bakery) against db1. Tiered before decoupled, matching vanilla.
cell_pg18_mesh_tiered() {
    "$SCRIPT_DIR/topo/mesh.sh" --mode tiered
}
cell_pg18_mesh_decoupled() {
    "$SCRIPT_DIR/topo/mesh.sh" --mode decoupled
}
# Standby cells: topo --standby base-backs a read-only physical replica, then the
# journey's story_standby_reads exercises cross-tier reads (iceberg_scan on the
# replica), the catalog/secret/GUCs arriving via the base backup, and a clean
# read-only cold-write rejection. Gated by ci/probe-standby.sh (verified green).
# Mesh adds a standby of db1, where story_standby_reads also asserts a
# peer-originated row surfaces on the replica (Spock → db1 → physical).
cell_pg18_vanilla_tiered_standby() {
    "$SCRIPT_DIR/topo/vanilla.sh" --mode tiered --standby
}
cell_pg18_vanilla_decoupled_standby() {
    "$SCRIPT_DIR/topo/vanilla.sh" --mode decoupled --standby
}
cell_pg18_mesh_tiered_standby() {
    "$SCRIPT_DIR/topo/mesh.sh" --mode tiered --standby
}
cell_pg18_mesh_decoupled_standby() {
    "$SCRIPT_DIR/topo/mesh.sh" --mode decoupled --standby
}

# coverage_table  — print every matrix cell with RUN / PENDING(reason). No
# cell is ever silently omitted; PENDING states what is still required.
coverage_table() {
    step "MATRIX COVERAGE"
    local pending_img="needs pg16/17 image build (one build-arg)"
    local pg topo mode tgt status
    for pg in 16 17 18; do
      for topo in vanilla mesh; do
        for mode in tiered decoupled; do
          for tgt in primary standby; do
            # All pg18 cells run (primary + standby, vanilla + mesh); standby is
            # gated by ci/probe-standby.sh, verified green. pg16/17 await an image.
            if [ "$pg" != 18 ]; then status="PENDING ($pending_img)"; else status="RUN"; fi
            printf '    pg%-2s · %-7s · %-9s · %-7s : %s\n' "$pg" "$topo" "$mode" "$tgt" "$status"
          done
        done
      done
    done
}

# ── Drive ─────────────────────────────────────────────────────────────────────
preflight

case "$SCOPE" in
  quick)
    run_cell "pg18·vanilla·tiered·primary" cell_pg18_vanilla_tiered
    ;;
  full)
    run_cell "pg18·vanilla·tiered·primary"    cell_pg18_vanilla_tiered
    run_cell "pg18·vanilla·decoupled·primary" cell_pg18_vanilla_decoupled
    run_cell "pg18·mesh·tiered·primary"       cell_pg18_mesh_tiered
    run_cell "pg18·mesh·decoupled·primary"    cell_pg18_mesh_decoupled
    run_cell "pg18·vanilla·tiered·standby"    cell_pg18_vanilla_tiered_standby
    run_cell "pg18·vanilla·decoupled·standby" cell_pg18_vanilla_decoupled_standby
    run_cell "pg18·mesh·tiered·standby"       cell_pg18_mesh_tiered_standby
    run_cell "pg18·mesh·decoupled·standby"    cell_pg18_mesh_decoupled_standby
    coverage_table
    echo -e "\n  NOTE: only verified cells RUN. PENDING cells are tracked, not skipped silently."
    ;;
esac

echo -e "\n${YELLOW}========================================${NC}"
echo -e "  Preflight + cell-level — Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo -e "${YELLOW}========================================${NC}"
[ "$FAIL" -eq 0 ] && [ "$CELL_FAIL" -eq 0 ]
