package main

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/apache/iceberg-go"
	"github.com/apache/iceberg-go/catalog"
	"github.com/apache/iceberg-go/table"
)

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

// deleteFile builds a position-delete manifest entry in the given partition.
func deleteFile(t *testing.T, spec iceberg.PartitionSpec, path string, partition map[int]any) iceberg.DataFile {
	t.Helper()
	b, err := iceberg.NewDataFileBuilder(spec, iceberg.EntryContentPosDeletes, path, iceberg.ParquetFile,
		partition, nil, nil, 1, 100)
	if err != nil {
		t.Fatal(err)
	}
	return b.Build()
}

// dataFile builds a data-file manifest entry in the given partition.
func dataFile(t *testing.T, spec iceberg.PartitionSpec, path string, partition map[int]any) iceberg.DataFile {
	t.Helper()
	b, err := iceberg.NewDataFileBuilder(spec, iceberg.EntryContentData, path, iceberg.ParquetFile,
		partition, nil, nil, 10, 1000)
	if err != nil {
		t.Fatal(err)
	}
	return b.Build()
}

// The engine writes a position-delete file's file_path bounds under DuckDB's own
// field id, which iceberg-go does not read, so to the planner those files have
// no bounds. PlanFiles must then attach each one to the data files of its own
// partition alone, the scope the Iceberg spec gives a position delete. A delete
// file attached across partitions sits in two rewrite groups, which the rewrite
// commit refuses, and rewriting one partition would remove the other's delete
// file and bring its deleted rows back.
func TestPlanFiles_ScopesPositionDeletesToPartition(t *testing.T) {
	byList := iceberg.NewPartitionSpec(iceberg.PartitionField{SourceIDs: []int{2}, FieldID: 1000,
		Name: "list", Transform: iceberg.IdentityTransform{}})
	ctx, tbl, _ := localTable(t, nil, catalog.WithPartitionSpec(&byList))
	spec := tbl.Spec()
	key := spec.Field(0).FieldID

	txn := tbl.NewTransaction()
	rd := txn.NewRowDelta(nil)
	for _, list := range []int32{1, 2} {
		dir := fmt.Sprintf("%s/data/list=%d/", tbl.Location(), list)
		rd.AddRows(dataFile(t, spec, dir+"data.parquet", map[int]any{key: list}))
		rd.AddDeletes(deleteFile(t, spec, dir+"deletes.parquet", map[int]any{key: list}))
	}
	if err := rd.Commit(ctx); err != nil {
		t.Fatalf("stage row delta: %v", err)
	}
	committed, err := txn.Commit(ctx)
	if err != nil {
		t.Fatalf("commit row delta: %v", err)
	}

	tasks, err := committed.Scan().PlanFiles(ctx)
	if err != nil {
		t.Fatalf("plan files: %v", err)
	}
	if len(tasks) != 2 {
		t.Fatalf("planned %d tasks, want 2", len(tasks))
	}
	for _, task := range tasks {
		want := strings.TrimSuffix(task.File.FilePath(), "data.parquet") + "deletes.parquet"
		if len(task.DeleteFiles) != 1 || task.DeleteFiles[0].FilePath() != want {
			t.Errorf("%s has %d delete files, want %s alone", task.File.FilePath(), len(task.DeleteFiles), want)
		}
	}
}

// duckdb-iceberg writes no referenced_data_file for a delete file, so iceberg-go
// attaches the delete file of the large file below to the five small files of
// its partition as well. Rewriting the small files must keep it, or the large
// file's deleted rows come back; rewriting every file may drop it.
func TestKeptDeletes_KeepsADeleteFileThatAppliesToAFileLeftOut(t *testing.T) {
	spec := *iceberg.UnpartitionedSpec
	del := deleteFile(t, spec, "s3://b/t/data/deletes.parquet", nil)
	task := func(name string) table.FileScanTask {
		return table.FileScanTask{File: dataFile(t, spec, "s3://b/t/data/"+name+".parquet", nil),
			DeleteFiles: []iceberg.DataFile{del}}
	}
	small := []table.FileScanTask{task("s1"), task("s2"), task("s3"), task("s4"), task("s5")}
	all := append([]table.FileScanTask{task("large")}, small...)

	if kept := keptDeletes(all, []table.CompactionTaskGroup{{Tasks: small}}); !kept[del.FilePath()] {
		t.Error("the delete file of the large file left out of the rewrite was not kept")
	}
	if kept := keptDeletes(all, []table.CompactionTaskGroup{{Tasks: all}}); len(kept) != 0 {
		t.Errorf("kept %v with every data file rewritten, want none", kept)
	}
}
