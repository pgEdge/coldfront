package partition

import (
	"fmt"
	"testing"
	"time"
)

func TestTimeBoundary_LiteralPreservesLegacyFormat(t *testing.T) {
	// Behavior-preservation lock: the time-mode literal must be byte-for-byte
	// what EnsureFuture emitted before the Boundary refactor — a single-quoted
	// "2006-01-02 15:04:05+00" — so the cold-tier archiver's CREATE TABLE SQL
	// is unchanged.
	in := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	if got, want := (TimeBoundary{}).Literal(in), "'2026-06-01 00:00:00+00'"; got != want {
		t.Fatalf("Literal = %q, want %q", got, want)
	}
}

func TestTimeBoundary_RoundTrip(t *testing.T) {
	in := time.Date(2025, 11, 1, 0, 0, 0, 0, time.UTC)
	got, err := TimeBoundary{}.Parse(TimeBoundary{}.Literal(in))
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(in) {
		t.Fatalf("round-trip = %v, want %v", got, in)
	}
}

func TestUUIDv7Boundary_LiteralIsQuoted(t *testing.T) {
	got := UUIDv7Boundary{}.Literal(time.UnixMilli(1700000000000).UTC())
	if got[0] != '\'' || got[len(got)-1] != '\'' {
		t.Fatalf("uuid literal must be single-quoted: %q", got)
	}
}

func TestUUIDv7Boundary_RoundTrip(t *testing.T) {
	in := time.UnixMilli(1700000000000).UTC()
	got, err := UUIDv7Boundary{}.Parse(UUIDv7Boundary{}.Literal(in))
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(in) {
		t.Fatalf("round-trip = %v, want %v", got, in)
	}
}

func TestSnowflakeBoundary_LiteralIsBareInteger(t *testing.T) {
	// A bigint RANGE bound is an integer literal — no quotes.
	got := SnowflakeBoundary{}.Literal(time.UnixMilli(1780285802608).UTC())
	if got[0] == '\'' {
		t.Fatalf("snowflake literal must be a bare integer, got quoted: %q", got)
	}
}

func TestSnowflakeBoundary_RoundTrip(t *testing.T) {
	in := time.UnixMilli(1780285802000).UTC()
	got, err := SnowflakeBoundary{}.Parse(SnowflakeBoundary{}.Literal(in))
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(in) {
		t.Fatalf("round-trip = %v, want %v", got, in)
	}
}

func TestSnowflakeBoundary_ParseIsQuoteAgnostic(t *testing.T) {
	// pg_get_expr may or may not quote a bigint bound depending on PG version;
	// Parse must accept both renderings identically.
	bare, err := SnowflakeBoundary{}.Parse("451955560737148928")
	if err != nil {
		t.Fatal(err)
	}
	quoted, err := SnowflakeBoundary{}.Parse("'451955560737148928'")
	if err != nil {
		t.Fatal(err)
	}
	if !bare.Equal(quoted) {
		t.Fatalf("quoted/bare disagree: %v vs %v", bare, quoted)
	}
}

func TestBoundaryFor(t *testing.T) {
	tests := []struct {
		mode, scheme string
		want         Boundary
		wantErr      bool
	}{
		{"", "", TimeBoundary{}, false},
		{PartModeTimestamp, "", TimeBoundary{}, false},
		{PartModeID, IDSchemeUUIDv7, UUIDv7Boundary{}, false},
		{PartModeID, IDSchemeSnowflake, SnowflakeBoundary{}, false},
		{PartModeID, "weird", nil, true},
		{"weird", "", nil, true},
	}
	for _, tt := range tests {
		got, err := BoundaryFor(tt.mode, tt.scheme)
		if tt.wantErr {
			if err == nil {
				t.Errorf("BoundaryFor(%q,%q): expected error", tt.mode, tt.scheme)
			}
			continue
		}
		if err != nil {
			t.Errorf("BoundaryFor(%q,%q): %v", tt.mode, tt.scheme, err)
			continue
		}
		if got != tt.want {
			t.Errorf("BoundaryFor(%q,%q) = %T, want %T", tt.mode, tt.scheme, got, tt.want)
		}
	}
}

func TestParseBoundPair_UnquotedBigint(t *testing.T) {
	// FindExpired feeds whatever pg_get_expr renders straight into parseBoundPair;
	// an unquoted bigint range (as PG renders bigint bounds) must parse via the
	// SnowflakeBoundary and decode back to the months that produced it.
	may := time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC)
	jun := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	expr := fmt.Sprintf("FOR VALUES FROM (%d) TO (%d)",
		MinSnowflakeBound(may), MinSnowflakeBound(jun))

	lo, hi, err := parseBoundPair(expr, SnowflakeBoundary{})
	if err != nil {
		t.Fatal(err)
	}
	if !lo.Equal(may) {
		t.Fatalf("lo = %v, want %v", lo, may)
	}
	if !hi.Equal(jun) {
		t.Fatalf("hi = %v, want %v", hi, jun)
	}
}
