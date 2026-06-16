package partition

import (
	"testing"
	"time"
)

func TestMinUUIDv7Bound_Format(t *testing.T) {
	got := MinUUIDv7Bound(time.UnixMilli(0x18BCFE56800).UTC())
	// 36 chars, 8-4-4-4-12 with the trailing groups zeroed (it's a boundary
	// value, not a real v7 — version/variant nibbles are not set).
	if len(got) != 36 {
		t.Fatalf("len = %d, want 36 (%q)", len(got), got)
	}
	if got[8] != '-' || got[13] != '-' || got[18] != '-' || got[23] != '-' {
		t.Fatalf("not dash-delimited at uuid positions: %q", got)
	}
	if got[14:] != "0000-0000-000000000000" {
		t.Fatalf("trailing groups not zero: %q", got)
	}
}

func TestUUIDv7_RoundTrip(t *testing.T) {
	for _, ms := range []int64{0, 1, 1700000000000, 1893456000000} {
		in := time.UnixMilli(ms).UTC()
		got, err := TimeFromUUIDv7(MinUUIDv7Bound(in))
		if err != nil {
			t.Fatalf("ms=%d: %v", ms, err)
		}
		if !got.Equal(in) {
			t.Fatalf("ms=%d: round-trip = %v, want %v", ms, got, in)
		}
	}
}

func TestUUIDv7Bound_MonotonicWithTime(t *testing.T) {
	// id-order must equal time-order, or RANGE(id) bounds wouldn't be time ranges.
	a := MinUUIDv7Bound(time.UnixMilli(1700000000000).UTC())
	b := MinUUIDv7Bound(time.UnixMilli(1700000001000).UTC())
	if a >= b { // lexical compare of fixed-width hex == byte order
		t.Fatalf("expected %q < %q", a, b)
	}
}

func TestTimeFromUUIDv7_Bad(t *testing.T) {
	if _, err := TimeFromUUIDv7("not-a-uuid"); err == nil {
		t.Fatal("expected error for malformed uuid")
	}
}

func TestSnowflake_RoundTrip(t *testing.T) {
	for _, ms := range []int64{snowflakeEpochMs, snowflakeEpochMs + 5000, 1780285802608} {
		in := time.UnixMilli(ms).UTC()
		if got := TimeFromSnowflake(MinSnowflakeBound(in)); !got.Equal(in) {
			t.Fatalf("ms=%d: round-trip = %v, want %v", ms, got, in)
		}
	}
}

func TestSnowflake_AgainstLiveSample(t *testing.T) {
	// Anchored to a real snowflake from the pgEdge extension (probed live):
	// id=451955560737148928, ts=2026-06-01T03:50:02.608Z, node=1, count=0.
	// Cross-checked against the snowflake 2.4 extension's get_epoch across four
	// literal ids: get_epoch returns SECONDS (numeric), and get_epoch*1000 equals
	// (id>>22)+1672531200000 exactly — confirming the source-read epoch/shift.
	const sampleID = int64(451955560737148928)
	sampleTime := time.UnixMilli(1780285802608).UTC()

	if got := TimeFromSnowflake(sampleID); !got.Equal(sampleTime) {
		t.Fatalf("decode(sample) = %v, want %v", got, sampleTime)
	}
	// node=1 sits at bit 12, count=0 -> the min bound is the sample minus the node bits.
	if got, want := MinSnowflakeBound(sampleTime), sampleID-(1<<12); got != want {
		t.Fatalf("MinSnowflakeBound = %d, want %d", got, want)
	}
}

func TestSnowflake_MonotonicWithTime(t *testing.T) {
	a := MinSnowflakeBound(time.UnixMilli(1780285802000).UTC())
	b := MinSnowflakeBound(time.UnixMilli(1780285803000).UTC())
	if a >= b {
		t.Fatalf("expected %d < %d", a, b)
	}
}
