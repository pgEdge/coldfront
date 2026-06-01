package main

import (
	"testing"
	"time"

	"github.com/pgedge/coldfront/internal/config"
	"github.com/pgedge/coldfront/internal/partition"
)

func TestSpecFromTable(t *testing.T) {
	got, err := specFromTable(config.TableConfig{
		SourceTable:      "events",
		SourceSchema:     "public",
		PartitionColumn:  "ts",
		PartitionPeriod:  partition.PeriodMonthly,
		RetentionPeriod:  "12 months",
		FuturePartitions: 3,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Parent != "events" || got.Schema != "public" || got.Column != "ts" ||
		got.Period != partition.PeriodMonthly || got.Premake != 3 {
		t.Fatalf("unexpected spec: %+v", got)
	}
	if want := 12 * 30 * 24 * time.Hour; got.Retention != want {
		t.Fatalf("retention = %v, want %v", got.Retention, want)
	}
}

func TestSpecFromTable_BadRetention(t *testing.T) {
	if _, err := specFromTable(config.TableConfig{RetentionPeriod: "soon"}); err == nil {
		t.Fatal("expected error for bad retention string")
	}
}

func TestSpecFromTable_IdModeSnowflake(t *testing.T) {
	got, err := specFromTable(config.TableConfig{
		SourceTable: "events", SourceSchema: "public", PartitionColumn: "id",
		PartitionPeriod: partition.PeriodMonthly, RetentionPeriod: "12 months",
		FuturePartitions: 3, PartMode: partition.PartModeID, IDScheme: partition.IDSchemeSnowflake,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, ok := got.Boundary.(partition.SnowflakeBoundary); !ok {
		t.Fatalf("Boundary = %T, want partition.SnowflakeBoundary", got.Boundary)
	}
}

func TestSpecFromTable_TimestampDefaultBoundary(t *testing.T) {
	got, err := specFromTable(config.TableConfig{
		SourceTable: "events", PartitionPeriod: partition.PeriodMonthly, RetentionPeriod: "3 months",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, ok := got.Boundary.(partition.TimeBoundary); !ok {
		t.Fatalf("Boundary = %T, want partition.TimeBoundary", got.Boundary)
	}
}
