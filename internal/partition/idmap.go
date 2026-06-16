package partition

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// idmap converts between time and the leading-timestamp bytes of a UUIDv7, for
// id-mode partitioning: a table partitioned by RANGE on a time-ordered id, where
// the partition bounds are id VALUES derived from the time boundaries.
//
// UUIDv7 (RFC 9562) carries a 48-bit big-endian Unix-ms timestamp in its leading
// bytes, so id-order is time-order and its bound is constructed here in Go from
// the standard format (no extension needed). A snowflake bigint uses the pgEdge
// snowflake extension's layout (epoch + shift below, read from its source); its
// bounds are computed here from those constants and cross-checked against the
// extension's snowflake.get_epoch() by an integration test.

// MinUUIDv7Bound returns the canonical uuid string that lower-bounds every
// UUIDv7 generated at or after t: the 48-bit ms timestamp in the leading bytes,
// all remaining bits zero. It is a partition-boundary value — smaller than any
// real v7 at t, larger than any before t — not itself a valid UUIDv7.
func MinUUIDv7Bound(t time.Time) string {
	ms := uint64(t.UnixMilli())
	return fmt.Sprintf("%08x-%04x-0000-0000-000000000000", uint32(ms>>16), uint16(ms&0xFFFF))
}

// TimeFromUUIDv7 reads the embedded ms timestamp from a uuid string's leading
// 48 bits (works for a real v7 or a MinUUIDv7Bound value).
func TimeFromUUIDv7(s string) (time.Time, error) {
	h := strings.ReplaceAll(s, "-", "")
	if len(h) < 12 {
		return time.Time{}, fmt.Errorf("not a uuid: %q", s)
	}
	ms, err := strconv.ParseInt(h[:12], 16, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("parse uuid timestamp from %q: %w", s, err)
	}
	return time.UnixMilli(ms).UTC(), nil
}

// Snowflake int8 layout, read from the pgEdge snowflake extension source
// (github.com/pgEdge/snowflake, snowflake.c):
//
//	bit 63   : unused (int8 sign)
//	bits 22-62 (SNOWFLAKE_MSEC_SHIFT=22): 41-bit ms timestamp, from SNOWFLAKE_EPOCH_OFFSET
//	bits 12-21 (NODE_SHIFT=12)          : 10-bit node
//	bits 0-11  (COUNT_SHIFT=0)          : 12-bit counter
//
// SNOWFLAKE_EPOCH_OFFSET = 1672531200 s (2023-01-01T00:00:00Z). The extension
// decodes via snowflake.get_epoch() but exposes no encode, so the lower bound
// for a time is computed here from the same constants. (The node/counter sub-
// fields are irrelevant to the lower bound — they are zero in it.)
const (
	snowflakeEpochMs int64 = 1672531200000 // 1672531200 s * 1000
	snowflakeMsShift uint  = 22
)

// MinSnowflakeBound returns the smallest snowflake generatable at or after t:
// the ms-timestamp field set, node and counter zero. Lower bound of the
// RANGE(id) partition holding all snowflakes from t onward.
func MinSnowflakeBound(t time.Time) int64 {
	return (t.UnixMilli() - snowflakeEpochMs) << snowflakeMsShift
}

// TimeFromSnowflake recovers the time a snowflake encodes — the Go mirror of the
// extension's snowflake.get_epoch() (verified equal by an integration test).
func TimeFromSnowflake(v int64) time.Time {
	return time.UnixMilli((v >> snowflakeMsShift) + snowflakeEpochMs).UTC()
}
