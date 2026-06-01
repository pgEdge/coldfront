package main

import (
	"testing"
	"time"

	"github.com/vyruss/coldfront/internal/config"
	"github.com/vyruss/coldfront/internal/partition"
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
