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

// keptPaths runs scopeDeletes over one data file and returns the paths of the
// delete files it kept.
func keptPaths(data iceberg.DataFile, deletes ...iceberg.DataFile) []string {
	tasks := scopeDeletes([]table.FileScanTask{{File: data, DeleteFiles: deletes}})
	got := make([]string, 0, len(deletes))
	for _, df := range tasks[0].DeleteFiles {
		got = append(got, df.FilePath())
	}
	return got
}

// A data file keeps only the position-delete files of its own partition, spec
// id and values both, as the Iceberg spec scopes them. Every other delete file is
// one iceberg-go attached by sequence number alone.
func TestScopeDeletes(t *testing.T) {
	month := iceberg.PartitionField{SourceIDs: []int{2}, FieldID: 1000, Name: "month_ts_2",
		Transform: iceberg.MonthTransform{}}
	spec, later := iceberg.NewPartitionSpecID(1, month), iceberg.NewPartitionSpecID(2, month)
	march, april := map[int]any{1000: int32(674)}, map[int]any{1000: int32(675)}
	data := dataFile(t, spec, "data/month_ts_2=674/d.parquet", march)

	got := keptPaths(data,
		deleteFile(t, spec, "data/month_ts_2=675/other-month.parquet", april),
		deleteFile(t, spec, "data/month_ts_2=674/own.parquet", march),
		deleteFile(t, spec, "data/no-partition.parquet", map[int]any{}),
		deleteFile(t, later, "data/month_ts_2=674/other-spec.parquet", march))
	if len(got) != 1 || got[0] != "data/month_ts_2=674/own.parquet" {
		t.Fatalf("kept %v, want the own-partition delete file alone", got)
	}
}

// An unpartitioned table is one partition: its delete files apply to its data
// files whether the partition map is nil or empty.
func TestScopeDeletes_Unpartitioned(t *testing.T) {
	spec := iceberg.NewPartitionSpecID(0)
	got := keptPaths(dataFile(t, spec, "data/d.parquet", nil),
		deleteFile(t, spec, "data/deletes.parquet", map[int]any{}))
	if len(got) != 1 {
		t.Fatalf("kept %v, want the delete file", got)
	}
}
