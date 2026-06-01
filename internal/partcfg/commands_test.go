package partcfg

import (
	"strings"
	"testing"
)

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
