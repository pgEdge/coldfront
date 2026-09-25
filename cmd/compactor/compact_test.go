package main

import (
	"errors"
	"testing"

	"github.com/apache/iceberg-go"
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

// A data file keeps only the position-delete files that can reference its rows:
// those of its own partition, and those of no partition at all. Every other
// delete file is one iceberg-go attached by sequence number alone.
func TestScopeDeletes(t *testing.T) {
	spec := iceberg.NewPartitionSpec(iceberg.PartitionField{
		SourceIDs: []int{2}, FieldID: 1000, Name: "month_ts_2", Transform: iceberg.MonthTransform{}})
	march, april := map[int]any{1000: int32(674)}, map[int]any{1000: int32(675)}
	data, err := iceberg.NewDataFileBuilder(spec, iceberg.EntryContentData, "data/month_ts_2=674/d.parquet",
		iceberg.ParquetFile, march, nil, nil, 10, 1000)
	if err != nil {
		t.Fatal(err)
	}
	own := deleteFile(t, spec, "data/month_ts_2=674/own-deletes.parquet", march)
	other := deleteFile(t, spec, "data/month_ts_2=675/other-deletes.parquet", april)
	global := deleteFile(t, spec, "data/global-deletes.parquet", map[int]any{})

	tasks := scopeDeletes([]table.FileScanTask{{File: data.Build(), DeleteFiles: []iceberg.DataFile{other, own, global}}})

	got := make([]string, 0, 2)
	for _, df := range tasks[0].DeleteFiles {
		got = append(got, df.FilePath())
	}
	want := []string{"data/month_ts_2=674/own-deletes.parquet", "data/global-deletes.parquet"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("kept %v, want %v", got, want)
	}
}
