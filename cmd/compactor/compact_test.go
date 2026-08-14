package main

import (
	"errors"
	"fmt"
	"slices"
	"testing"

	"github.com/apache/iceberg-go"
	"github.com/apache/iceberg-go/catalog"
	"github.com/apache/iceberg-go/table"
)

// fakeTask builds the one thing task ordering reads: a data file with a path and
// a set of lower bounds.
func fakeTask(t *testing.T, path string, lowerBounds map[int][]byte) table.FileScanTask {
	t.Helper()
	b, err := iceberg.NewDataFileBuilder(
		iceberg.PartitionSpec{}, iceberg.EntryContentData, path, iceberg.ParquetFile,
		nil, nil, nil, 1000, 1<<20)
	if err != nil {
		t.Fatalf("data file builder for %s: %v", path, err)
	}
	if lowerBounds != nil {
		b = b.LowerBoundValues(lowerBounds)
	}
	return table.FileScanTask{File: b.Build()}
}

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

func testSchema() *iceberg.Schema {
	return iceberg.NewSchema(0,
		iceberg.NestedField{ID: 1, Name: "id", Type: iceberg.PrimitiveTypes.Int64},
		iceberg.NestedField{ID: 2, Name: "list", Type: iceberg.PrimitiveTypes.Int32},
		iceberg.NestedField{ID: 3, Name: "label", Type: iceberg.PrimitiveTypes.String},
	)
}

func TestSortField(t *testing.T) {
	sc := testSchema()
	tests := []struct {
		name    string
		props   iceberg.Properties
		wantID  int
		wantOK  bool
		wantErr bool
	}{
		{name: "absent leaves compaction alone", props: iceberg.Properties{}},
		{name: "nil props", props: nil},
		{name: "blank is absent", props: iceberg.Properties{sortKeyProp: "  "}},
		{name: "single column", props: iceberg.Properties{sortKeyProp: "list"}, wantID: 2, wantOK: true},
		// Only the leading column orders files: within one list value the
		// secondary key never straddles two files.
		{name: "compound key uses the first", props: iceberg.Properties{sortKeyProp: "list, id"}, wantID: 2, wantOK: true},
		// A key naming a column that is not there is a misconfiguration, and
		// rewriting anyway would scramble the layout it was meant to protect.
		{name: "unknown column errors", props: iceberg.Properties{sortKeyProp: "nope"}, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			field, ok, err := sortField(tt.props, sc)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr = %v", err, tt.wantErr)
			}
			if ok != tt.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOK)
			}
			if ok && field.ID != tt.wantID {
				t.Errorf("field.ID = %d, want %d", field.ID, tt.wantID)
			}
		})
	}
}

// bound serialises a lower bound the way a manifest stores one, using the
// library's own encoder so the fixture cannot drift from the real format.
func bound(t *testing.T, lit iceberg.Literal) []byte {
	t.Helper()
	b, err := lit.MarshalBinary()
	if err != nil {
		t.Fatalf("marshal %v: %v", lit, err)
	}
	return b
}

func TestOrderTasksBySortKey(t *testing.T) {
	sc := testSchema()
	list, _ := sc.FindFieldByName("list")

	// Files arrive from the planner in whatever order it produced them. Ordering
	// them by their lower bound is what makes the rewrite's concatenation keep
	// the sort order, so each output row group spans adjacent key values instead
	// of the whole table.
	tasks := []table.FileScanTask{
		fakeTask(t, "c.parquet", map[int][]byte{2: bound(t, iceberg.Int32Literal(20))}),
		fakeTask(t, "a.parquet", map[int][]byte{2: bound(t, iceberg.Int32Literal(0))}),
		fakeTask(t, "b.parquet", map[int][]byte{2: bound(t, iceberg.Int32Literal(10))}),
	}
	if err := orderTasksBySortKey(tasks, list); err != nil {
		t.Fatalf("orderTasksBySortKey: %v", err)
	}
	var got []string
	for _, task := range tasks {
		got = append(got, task.File.FilePath())
	}
	want := []string{"a.parquet", "b.parquet", "c.parquet"}
	if !slices.Equal(got, want) {
		t.Errorf("order = %v, want %v", got, want)
	}
}

func TestOrderTasksBySortKey_RefusesWhatItCannotOrder(t *testing.T) {
	sc := testSchema()
	list, _ := sc.FindFieldByName("list")

	// A file with no lower bound for the sort column cannot be placed. Rewriting
	// the group anyway would scramble the layout, so this must be an error the
	// caller turns into a skip, never a silent best-effort sort.
	tasks := []table.FileScanTask{
		fakeTask(t, "a.parquet", map[int][]byte{2: bound(t, iceberg.Int32Literal(0))}),
		fakeTask(t, "b.parquet", nil),
	}
	if err := orderTasksBySortKey(tasks, list); err == nil {
		t.Error("missing lower bound was accepted; want an error")
	}
}

func TestLessLiteral(t *testing.T) {
	// Every Iceberg type ColdFront can sort by, plus one it cannot, so an
	// unorderable key is refused rather than compared as something else.
	tests := []struct {
		name       string
		lo, hi     iceberg.Literal
		wantOrders bool
	}{
		{"int32", iceberg.Int32Literal(1), iceberg.Int32Literal(2), true},
		{"int64", iceberg.Int64Literal(1), iceberg.Int64Literal(2), true},
		{"date", iceberg.DateLiteral(1), iceberg.DateLiteral(2), true},
		{"timestamp", iceberg.TimestampLiteral(1), iceberg.TimestampLiteral(2), true},
		{"string", iceberg.StringLiteral("a"), iceberg.StringLiteral("b"), true},
		{"float is not ordered here", iceberg.Float64Literal(1), iceberg.Float64Literal(2), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			less, ok := lessLiteral(tt.lo, tt.hi)
			if ok != tt.wantOrders {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOrders)
			}
			if !ok {
				return
			}
			if !less {
				t.Errorf("lessLiteral(lo, hi) = false, want true")
			}
			if rev, _ := lessLiteral(tt.hi, tt.lo); rev {
				t.Errorf("lessLiteral(hi, lo) = true, want false")
			}
			if eq, _ := lessLiteral(tt.lo, tt.lo); eq {
				t.Errorf("lessLiteral(x, x) = true, want false")
			}
		})
	}
}

func TestLessLiteral_MismatchedTypesDoNotOrder(t *testing.T) {
	// Bounds of different types mean the manifest and the schema disagree.
	// Guessing an order there is how a rewrite silently scrambles a table.
	if _, ok := lessLiteral(iceberg.Int32Literal(1), iceberg.Int64Literal(2)); ok {
		t.Error("mismatched literal types were ordered; want a refusal")
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
