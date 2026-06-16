package partcfg

import (
	"strings"
	"testing"

	"github.com/pgedge/coldfront/internal/config"
)

func TestLit(t *testing.T) {
	if got := lit(""); got != "NULL" {
		t.Errorf("lit(\"\") = %q, want NULL", got)
	}
	if got := lit("monthly"); got != "'monthly'" {
		t.Errorf("lit(monthly) = %q", got)
	}
	if got := lit("o'brien"); got != "'o''brien'" {
		t.Errorf("lit escaping = %q", got)
	}
}

func TestRowFrom_AppliesDefaults(t *testing.T) {
	// A minimal TableConfig (as from YAML) gets the same defaults the loader applies.
	r := rowFrom(config.TableConfig{SourceTable: "events", PartitionPeriod: "monthly", RetentionPeriod: "1 year"})
	if r.schema != "public" || r.premake != 3 || r.partMode != "timestamp" {
		t.Fatalf("defaults not applied: %+v", r)
	}
	if r.table != "events" || r.retention != "1 year" {
		t.Fatalf("fields not mapped: %+v", r)
	}
}

func TestRowFrom_SubPartition(t *testing.T) {
	r := rowFrom(config.TableConfig{
		SourceTable: "regional", PartitionPeriod: "monthly", PartitionColumn: "ts",
		HotPeriod: "1 month", FuturePartitions: 5,
		SubPartition: &config.SubPartitionConfig{ValuesSource: "SELECT region FROM regions"},
	})
	if r.subValues != "SELECT region FROM regions" || r.hot != "1 month" || r.premake != 5 {
		t.Fatalf("2-level/tiered mapping wrong: %+v", r)
	}
}

func TestIsCommand(t *testing.T) {
	for _, c := range []string{"register", "list"} {
		if !IsCommand(c) {
			t.Errorf("IsCommand(%q) = false, want true", c)
		}
	}
	for _, c := range []string{"reconcile", "archive", "--config", "bogus", ""} {
		if IsCommand(c) {
			t.Errorf("IsCommand(%q) = true, want false", c)
		}
	}
}

func TestInsertSQL_PartitionOnly(t *testing.T) {
	got := configRow{
		schema: "public", table: "events", period: "monthly",
		premake: 3, partMode: "timestamp", retention: "12 months",
	}.insertSQL()
	// quoted values, NULL for the empty optional columns
	for _, want := range []string{
		"INSERT INTO coldfront.partition_config",
		"'public', 'events', 'monthly', NULL, 3, 'timestamp', NULL, NULL, '12 months', NULL",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("insertSQL missing %q:\n%s", want, got)
		}
	}
}

func TestInsertSQL_IDModeAndSub(t *testing.T) {
	got := configRow{
		schema: "public", table: "regional", period: "daily", column: "id",
		premake: 5, partMode: "id", idScheme: "snowflake",
		retention: "7 days", subValues: "SELECT region FROM regions",
	}.insertSQL()
	if !strings.Contains(got, "'id', 'snowflake'") {
		t.Errorf("id-mode not rendered:\n%s", got)
	}
	if !strings.Contains(got, "'SELECT region FROM regions'") {
		t.Errorf("sub-values not rendered:\n%s", got)
	}
}

func TestInsertSQL_EscapesQuotes(t *testing.T) {
	got := configRow{
		schema: "public", table: "events", period: "monthly", retention: "1 year",
		subValues: "SELECT code FROM o'brien",
	}.insertSQL()
	if !strings.Contains(got, "'SELECT code FROM o''brien'") {
		t.Errorf("single quote not doubled:\n%s", got)
	}
}

func TestPartKeyCols(t *testing.T) {
	cases := []struct {
		def  string
		want []string
	}{
		{"RANGE (ts)", []string{"ts"}},
		{"LIST (region)", []string{"region"}},
		{"RANGE (tenant_id, ts)", []string{"tenant_id", "ts"}},
		{"garbage", nil},
		{"", nil},
	}
	for _, c := range cases {
		got := partKeyCols(c.def)
		if len(got) != len(c.want) {
			t.Errorf("partKeyCols(%q) = %v, want %v", c.def, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("partKeyCols(%q) = %v, want %v", c.def, got, c.want)
				break
			}
		}
	}
}
