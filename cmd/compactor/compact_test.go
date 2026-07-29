package main

import (
	"errors"
	"fmt"
	"testing"

	"github.com/apache/iceberg-go/catalog"
)

func TestLoadTableErr_NotFound(t *testing.T) {
	// The REST catalog maps a 404 to catalog.ErrNoSuchTable, but its Error()
	// renders the server's wording ("NoSuchTableException: Error getting
	// tabular from catalog"), which says nothing useful to whoever ran the
	// command. Only the identifier they typed matters.
	raw := fmt.Errorf("NoSuchTableException: Error getting tabular from catalog: %w",
		catalog.ErrNoSuchTable)
	got := loadTableErr("public", "no_such_table", raw)
	want := `table "public.no_such_table" not found in catalog`
	if got.Error() != want {
		t.Errorf("got %q, want %q", got.Error(), want)
	}
}

func TestLoadTableErr_OtherErrorsPassThrough(t *testing.T) {
	// Anything else keeps its cause: a connection refused or a 401 must not be
	// reported as a missing table.
	raw := errors.New("connection refused")
	got := loadTableErr("public", "events", raw)
	if !errors.Is(got, raw) {
		t.Errorf("cause not preserved: %v", got)
	}
	if got.Error() == `table "public.events" not found in catalog` {
		t.Error("non-404 error was reported as a missing table")
	}
}
