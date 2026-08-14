package main

import (
	"context"
	"testing"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/memory"
	"github.com/apache/iceberg-go"
	"github.com/apache/iceberg-go/catalog"
	"github.com/apache/iceberg-go/catalog/hadoop"
	"github.com/apache/iceberg-go/table"
)

// mergeSchema is the smallest table that can show the difference between a merge
// and an append: a sort column, and a payload column to prove rows travel with it.
func mergeSchema() *iceberg.Schema {
	return iceberg.NewSchema(0,
		iceberg.NestedField{ID: 1, Name: "id", Type: iceberg.PrimitiveTypes.Int64, Required: true},
		iceberg.NestedField{ID: 2, Name: "list", Type: iceberg.PrimitiveTypes.Int32},
	)
}

// localTable creates a real Iceberg table on disk through the filesystem catalog,
// so the merge under test runs against the same read, write and commit paths it
// uses in production rather than against a stub. Filesystem rather than a SQL
// catalog because the sqlite driver would add nineteen modules, one of them CGO,
// to a module whose whole point is to quarantine heavy dependencies.
func localTable(t *testing.T, props iceberg.Properties) (context.Context, *table.Table, catalog.Catalog) {
	t.Helper()
	ctx := context.Background()
	cat, err := hadoop.NewCatalog("test", "file://"+t.TempDir(), nil)
	if err != nil {
		t.Fatalf("load catalog: %v", err)
	}
	if err := cat.CreateNamespace(ctx, catalog.ToIdentifier("ns"), nil); err != nil {
		t.Fatalf("create namespace: %v", err)
	}
	tbl, err := cat.CreateTable(ctx, catalog.ToIdentifier("ns", "t"), mergeSchema(),
		catalog.WithProperties(props))
	if err != nil {
		t.Fatalf("create table: %v", err)
	}
	return ctx, tbl, cat
}

// appendRun commits one data file holding the given rows, in the order given. A
// negative list value stands for NULL, which is what an unassigned row carries.
func appendRun(t *testing.T, ctx context.Context, tbl *table.Table, ids []int64, lists []int32) *table.Table {
	t.Helper()
	arrowSchema, err := table.SchemaToArrowSchema(tbl.Schema(), nil, true, false)
	if err != nil {
		t.Fatalf("arrow schema: %v", err)
	}
	bld := array.NewRecordBuilder(memory.DefaultAllocator, arrowSchema)
	defer bld.Release()
	for i := range ids {
		bld.Field(0).(*array.Int64Builder).Append(ids[i])
		if lists[i] < 0 {
			bld.Field(1).(*array.Int32Builder).AppendNull()
		} else {
			bld.Field(1).(*array.Int32Builder).Append(lists[i])
		}
	}
	rec := bld.NewRecordBatch()
	defer rec.Release()

	at := array.NewTableFromRecords(arrowSchema, []arrow.RecordBatch{rec})
	defer at.Release()

	txn := tbl.NewTransaction()
	if err := txn.AppendTable(ctx, at, int64(len(ids)), nil); err != nil {
		t.Fatalf("append run: %v", err)
	}
	out, err := txn.Commit(ctx)
	if err != nil {
		t.Fatalf("commit run: %v", err)
	}
	return out
}

// readColumn returns the table's list column in the order the scan yields it,
// with NULL rendered as -1 so one slice can express both.
func readColumn(t *testing.T, ctx context.Context, tbl *table.Table) []int32 {
	t.Helper()
	at, err := tbl.Scan().ToArrowTable(ctx)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	defer at.Release()

	var got []int32
	col := at.Column(1).Data()
	for _, chunk := range col.Chunks() {
		vals := chunk.(*array.Int32)
		for i := 0; i < vals.Len(); i++ {
			if vals.IsNull(i) {
				got = append(got, -1)
				continue
			}
			got = append(got, vals.Value(i))
		}
	}
	return got
}

// groupsFor bin-packs every file in the current snapshot into one group, which is
// what the planner produces for a table of small files.
func groupsFor(t *testing.T, ctx context.Context, tbl *table.Table) []table.CompactionTaskGroup {
	t.Helper()
	tasks, err := tbl.Scan().PlanFiles(ctx)
	if err != nil {
		t.Fatalf("plan files: %v", err)
	}
	var total int64
	for _, task := range tasks {
		total += task.File.FileSizeBytes()
	}
	return []table.CompactionTaskGroup{{Tasks: tasks, TotalSizeBytes: total}}
}

func TestRewriteSorted_MergesOverlappingRuns(t *testing.T) {
	// Two files, each already sorted, whose ranges interleave. This is what a
	// clustered table accumulates: every batch cold write orders its own rows, so
	// each new file spans the whole of key space. Appending them in file order
	// would yield 0,5,10,1,6,11 and leave a probe reading both halves; only a merge
	// on the column produces one ordered run.
	ctx, tbl, cat := localTable(t, iceberg.Properties{sortKeyProp: "list"})
	tbl = appendRun(t, ctx, tbl, []int64{1, 2, 3}, []int32{0, 5, 10})
	tbl = appendRun(t, ctx, tbl, []int64{4, 5, 6}, []int32{1, 6, 11})

	field, ok := tbl.Schema().FindFieldByName("list")
	if !ok {
		t.Fatal("sort column missing from schema")
	}
	if _, err := rewriteSorted(ctx, tbl, groupsFor(t, ctx, tbl), field, 0); err != nil {
		t.Fatalf("rewriteSorted: %v", err)
	}

	merged, err := cat.LoadTable(ctx, catalog.ToIdentifier("ns", "t"))
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	want := []int32{0, 1, 5, 6, 10, 11}
	got := readColumn(t, ctx, merged)
	if len(got) != len(want) {
		t.Fatalf("row count = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("merged order = %v, want %v", got, want)
		}
	}
}

func TestRewriteSorted_UnassignedRowsSortLast(t *testing.T) {
	// A row another engine appended carries no assignment. Keeping those rows
	// together at the end is what lets a probe read them in proportion to their own
	// size rather than meeting them in every row group.
	ctx, tbl, cat := localTable(t, iceberg.Properties{sortKeyProp: "list"})
	tbl = appendRun(t, ctx, tbl, []int64{1, 2}, []int32{-1, 7})
	tbl = appendRun(t, ctx, tbl, []int64{3, 4}, []int32{2, -1})

	field, _ := tbl.Schema().FindFieldByName("list")
	if _, err := rewriteSorted(ctx, tbl, groupsFor(t, ctx, tbl), field, 0); err != nil {
		t.Fatalf("rewriteSorted: %v", err)
	}
	merged, err := cat.LoadTable(ctx, catalog.ToIdentifier("ns", "t"))
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	got := readColumn(t, ctx, merged)
	want := []int32{2, 7, -1, -1}
	if len(got) != len(want) {
		t.Fatalf("row count = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("merged order = %v, want %v (-1 is NULL)", got, want)
		}
	}
}

func TestRewriteSorted_PreservesRowsWithNoSortableOrder(t *testing.T) {
	// One file, already ordered: the merge must be a no-op on content. This is the
	// idempotence a second compaction pass depends on.
	ctx, tbl, cat := localTable(t, iceberg.Properties{sortKeyProp: "list"})
	tbl = appendRun(t, ctx, tbl, []int64{1, 2, 3}, []int32{4, 8, 12})

	field, _ := tbl.Schema().FindFieldByName("list")
	if _, err := rewriteSorted(ctx, tbl, groupsFor(t, ctx, tbl), field, 0); err != nil {
		t.Fatalf("rewriteSorted: %v", err)
	}
	merged, err := cat.LoadTable(ctx, catalog.ToIdentifier("ns", "t"))
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	got := readColumn(t, ctx, merged)
	want := []int32{4, 8, 12}
	if len(got) != len(want) {
		t.Fatalf("row count = %d, want %d (%v)", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("order = %v, want %v", got, want)
		}
	}
}

func TestRewriteSorted_RowsStayIntact(t *testing.T) {
	// The sort permutes every column or none: a reorder that moved the sort column
	// alone would leave each row carrying another row's payload, which no assertion
	// on the sort column's order can see.
	ctx, tbl, cat := localTable(t, iceberg.Properties{sortKeyProp: "list"})
	tbl = appendRun(t, ctx, tbl, []int64{10, 20, 30}, []int32{0, 5, 10})
	tbl = appendRun(t, ctx, tbl, []int64{40, 50, 60}, []int32{1, 6, 11})

	field, _ := tbl.Schema().FindFieldByName("list")
	if _, err := rewriteSorted(ctx, tbl, groupsFor(t, ctx, tbl), field, 0); err != nil {
		t.Fatalf("rewriteSorted: %v", err)
	}
	merged, err := cat.LoadTable(ctx, catalog.ToIdentifier("ns", "t"))
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	at, err := merged.Scan().ToArrowTable(ctx)
	if err != nil {
		t.Fatalf("scan: %v", err)
	}
	defer at.Release()

	// id was seeded as list*... no: each id is paired with one list value, so the
	// pairing is what is asserted, not a formula.
	want := map[int32]int64{0: 10, 5: 20, 10: 30, 1: 40, 6: 50, 11: 60}
	ids := at.Column(0).Data()
	lists := at.Column(1).Data()
	var n int
	for c := range ids.Chunks() {
		idv := ids.Chunk(c).(*array.Int64)
		lsv := lists.Chunk(c).(*array.Int32)
		for i := 0; i < idv.Len(); i++ {
			if got := idv.Value(i); got != want[lsv.Value(i)] {
				t.Errorf("list %d carries id %d, want %d", lsv.Value(i), got, want[lsv.Value(i)])
			}
			n++
		}
	}
	if n != len(want) {
		t.Fatalf("read %d rows, want %d", n, len(want))
	}
}
