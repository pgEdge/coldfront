package partition

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/pgedge/coldfront/internal/sqlutil"
)

// Partition key modes and id schemes. The valid set lives here (like the Period
// constants) so config validation and Boundary selection reference one source.
const (
	PartModeTimestamp = "timestamp" // RANGE on a time column; the bound IS the time
	PartModeID        = "id"        // RANGE on a time-ordered id; the bound is an id value

	IDSchemeUUIDv7    = "uuidv7"    // uuid column carrying RFC 9562 v7 values
	IDSchemeSnowflake = "snowflake" // bigint column carrying pgEdge snowflakes
)

// Boundary maps between a partition key's wire literal — the value as it appears
// inside FOR VALUES FROM (…) TO (…) and as pg_get_expr renders it back — and the
// wall-clock time it stands for. It is the single seam that lets RANGE
// partitioning on a time-ordered id reuse the one time-based premake/retention
// schedule: the key column changes, the monthly/daily cadence does not.
type Boundary interface {
	// Literal renders the partition-bound value for time t, ready to drop
	// straight into FOR VALUES FROM (…) TO (…), including any quoting the
	// column type requires.
	Literal(t time.Time) string
	// Parse recovers the time from one bound value as pg_get_expr renders it.
	// It must tolerate the value being quoted or not (PG's rendering of an
	// integer bound is version-dependent).
	Parse(lit string) (time.Time, error)
}

// TimeBoundary partitions by a timestamp/timestamptz/date column: the bound is
// the time itself. This is the default and reproduces the pre-Boundary SQL
// byte-for-byte.
type TimeBoundary struct{}

// Literal renders t as a quoted timestamptz bound.
func (TimeBoundary) Literal(t time.Time) string {
	return "'" + sqlutil.Timestamp(t) + "'"
}

// Parse reads a (possibly quoted) timestamp bound back to its time.
func (TimeBoundary) Parse(lit string) (time.Time, error) { return parseTimestamp(unquote(lit)) }

// UUIDv7Boundary partitions by RANGE on a uuid column holding UUIDv7 values; the
// bound is the canonical uuid that lower-bounds every v7 generated at t.
type UUIDv7Boundary struct{}

// Literal renders the lowest UUIDv7 generated at t as a quoted uuid bound.
func (UUIDv7Boundary) Literal(t time.Time) string { return "'" + MinUUIDv7Bound(t) + "'" }

// Parse recovers the time embedded in a (possibly quoted) UUIDv7 bound.
func (UUIDv7Boundary) Parse(lit string) (time.Time, error) { return TimeFromUUIDv7(unquote(lit)) }

// SnowflakeBoundary partitions by RANGE on a bigint column holding pgEdge
// snowflakes; the bound is the smallest snowflake at t, rendered as a bare
// integer literal.
type SnowflakeBoundary struct{}

// Literal renders the smallest snowflake at t as a bare integer bound.
func (SnowflakeBoundary) Literal(t time.Time) string {
	return strconv.FormatInt(MinSnowflakeBound(t), 10)
}

// Parse recovers the time from a (possibly quoted) snowflake integer bound.
func (SnowflakeBoundary) Parse(lit string) (time.Time, error) {
	v, err := strconv.ParseInt(unquote(lit), 10, 64)
	if err != nil {
		return time.Time{}, fmt.Errorf("parse snowflake bound %q: %w", lit, err)
	}
	return TimeFromSnowflake(v), nil
}

// BoundaryFor selects the Boundary for a (part_mode, id_scheme) pair. An empty
// mode means timestamp (the default), so existing configs need no new field.
func BoundaryFor(mode, scheme string) (Boundary, error) {
	switch mode {
	case "", PartModeTimestamp:
		return TimeBoundary{}, nil
	case PartModeID:
		switch scheme {
		case IDSchemeUUIDv7:
			return UUIDv7Boundary{}, nil
		case IDSchemeSnowflake:
			return SnowflakeBoundary{}, nil
		default:
			return nil, fmt.Errorf("unknown id_scheme %q (want %q or %q)", scheme, IDSchemeUUIDv7, IDSchemeSnowflake)
		}
	default:
		return nil, fmt.Errorf("unknown part_mode %q (want %q or %q)", mode, PartModeTimestamp, PartModeID)
	}
}

// boundRe captures the two bound values inside a pg_get_expr(relpartbound)
// string, with or without surrounding quotes — the per-Boundary Parse handles
// the quoting and the type conversion.
var boundRe = regexp.MustCompile(`FOR VALUES FROM \((.+?)\) TO \((.+?)\)`)

// negInfinity and posInfinity stand for an unbounded partition edge, outside
// PostgreSQL's own range (4713 BC to 5874897 AD) so no real bound equals one.
// The ordinary comparisons then hold: an edge open above is never past the hot
// window, never expires, and still covers the current period.
var (
	negInfinity = time.Date(-5000, 1, 1, 0, 0, 0, 0, time.UTC)
	posInfinity = time.Date(6000000, 1, 1, 0, 0, 0, 0, time.UTC)
)

// openBound maps an unbounded edge token to its sentinel. MINVALUE/MAXVALUE are
// partition-bound keywords; infinity/-infinity are timestamp values.
func openBound(lit string) (time.Time, bool) {
	switch strings.ToLower(unquote(lit)) {
	case "minvalue", "-infinity":
		return negInfinity, true
	case "maxvalue", "infinity":
		return posInfinity, true
	}
	return time.Time{}, false
}

// parseBoundPair extracts the lower and upper bound values from a
// pg_get_expr(relpartbound) string and converts both to time via b.
func parseBoundPair(expr string, b Boundary) (lower, upper time.Time, err error) {
	m := boundRe.FindStringSubmatch(expr)
	if m == nil {
		return time.Time{}, time.Time{}, fmt.Errorf("cannot parse partition bound: %q", expr)
	}
	if lower, err = parseEdge(m[1], b); err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("parse lower bound: %w", err)
	}
	if upper, err = parseEdge(m[2], b); err != nil {
		return time.Time{}, time.Time{}, fmt.Errorf("parse upper bound: %w", err)
	}
	return lower, upper, nil
}

// parseEdge resolves one bound value: a sentinel when the edge is open, else the
// Boundary's own conversion.
func parseEdge(lit string, b Boundary) (time.Time, error) {
	if t, ok := openBound(lit); ok {
		return t, nil
	}
	return b.Parse(lit)
}

// unquote strips one layer of surrounding single quotes, if present.
func unquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && s[0] == '\'' && s[len(s)-1] == '\'' {
		return s[1 : len(s)-1]
	}
	return s
}
