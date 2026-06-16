package main

import (
	"os/exec"
	"strings"
	"testing"
)

// TestNoIcebergImports asserts the standalone partitioner's transitive import
// graph contains no iceberg-layer Go package. This is the mechanical guard for
// the one-way dependency rule (iceberg -> partition-core, never the reverse)
// that keeps the partition manager strippable: it resolves the REAL resolved
// import graph via `go list -deps`, not a hand-maintained deny-list that could
// drift as packages are added.
func TestNoIcebergImports(t *testing.T) {
	out, err := exec.Command("go", "list", "-deps", ".").Output()
	if err != nil {
		t.Fatalf("go list -deps: %v", err)
	}
	forbidden := []string{
		"coldfront/internal/view",      // iceberg UNION/wrapper view generation
		"coldfront/internal/watermark", // hot/cold cutoff store
	}
	for _, dep := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		for _, f := range forbidden {
			if strings.HasSuffix(dep, f) {
				t.Errorf("partitioner transitively imports iceberg-layer package %q — breaks the one-way dependency rule", dep)
			}
		}
	}
}
