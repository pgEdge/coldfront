package sqlutil

import (
	"testing"
	"time"
)

func TestLiteral(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", "''"},
		{"hello", "'hello'"},
		{"o'clock", "'o''clock'"},
		{"a'b'c", "'a''b''c'"},
		{"''", "''''''"},
	}
	for _, c := range cases {
		if got := Literal(c.in); got != c.want {
			t.Errorf("Literal(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestTimestamp(t *testing.T) {
	// PostgreSQL rejects Go's negative astronomical year and wants the era
	// suffix instead, where astronomical year Y is 1-Y BC.
	cases := []struct {
		in   time.Time
		want string
	}{
		{time.Date(2026, 6, 1, 12, 30, 15, 0, time.UTC), "2026-06-01 12:30:15+00"},
		{time.Date(10000, 6, 1, 0, 0, 0, 0, time.UTC), "10000-06-01 00:00:00+00"},
		{time.Date(294276, 12, 31, 0, 0, 0, 0, time.UTC), "294276-12-31 00:00:00+00"},
		{time.Date(0, 1, 1, 0, 0, 0, 0, time.UTC), "0001-01-01 00:00:00+00 BC"},
		{time.Date(-42, 3, 15, 0, 0, 0, 0, time.UTC), "0043-03-15 00:00:00+00 BC"},
		{time.Date(-4712, 1, 1, 0, 0, 0, 0, time.UTC), "4713-01-01 00:00:00+00 BC"},
		// The era is decided by the UTC year, not the input's own zone: this is
		// year 1 locally but year 0 (1 BC) once converted.
		{time.Date(1, 1, 1, 0, 30, 0, 0, time.FixedZone("", 3600)), "0001-12-31 23:30:00+00 BC"},
	}
	for _, c := range cases {
		if got := Timestamp(c.in); got != c.want {
			t.Errorf("Timestamp(%v) = %q, want %q", c.in, got, c.want)
		}
	}
}
