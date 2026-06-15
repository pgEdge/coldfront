package partition

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Supported partition cadences. Both `partition` and `config` reference
// these so the valid set lives in one place.
const (
	PeriodMonthly = "monthly"
	PeriodDaily   = "daily"
)

// Retention strategies for a partition past its retention window (standalone
// partitioner only; the tiered archiver always drops after exporting to cold).
// The valid set lives here so config validation references one source.
const (
	StrategyDrop   = "drop"   // DETACH CONCURRENTLY + DROP TABLE — destroy (default)
	StrategyDetach = "detach" // DETACH CONCURRENTLY only — preserve as a standalone table
)

// DBTX abstracts *pgx.Conn and pgx.Tx for testability.
type DBTX interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// Info holds metadata about a partition.
type Info struct {
	Name       string
	LowerBound time.Time
	UpperBound time.Time
}

// Manager handles partition lifecycle operations.
type Manager struct {
	db DBTX
}

// NewManager creates a new partition Manager.
func NewManager(db DBTX) *Manager {
	return &Manager{db: db}
}

// ParseBoundExpr extracts lower and upper time bounds from a
// pg_get_expr(relpartbound) string for a time-keyed partition. It is the
// time-mode special case of parseBoundPair, kept as a package-level helper for
// callers that only ever deal with time columns.
func ParseBoundExpr(expr string) (lower, upper time.Time, err error) {
	return parseBoundPair(expr, TimeBoundary{})
}

// parseTimestamp parses a pg_get_expr-style bound value (the quoted string
// inside FOR VALUES FROM/TO) into a UTC time. Accepts the common layouts
// PostgreSQL emits.
func parseTimestamp(s string) (time.Time, error) {
	for _, layout := range []string{
		"2006-01-02 15:04:05+00",
		"2006-01-02 15:04:05-07",
		"2006-01-02",
	} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("unrecognized timestamp format: %q", s)
}

// PartitionName generates a partition table name for the given date and period.
func PartitionName(t time.Time, period string) string {
	if period == PeriodDaily {
		return fmt.Sprintf("p_%04d_%02d_%02d", t.Year(), t.Month(), t.Day())
	}
	return fmt.Sprintf("p_%04d_%02d", t.Year(), t.Month())
}

// PartitionBounds returns the lower (inclusive) and upper (exclusive) bounds for the period containing t.
func PartitionBounds(t time.Time, period string) (lower, upper time.Time) {
	if period == PeriodDaily {
		lower = time.Date(t.Year(), t.Month(), t.Day(), 0, 0, 0, 0, time.UTC)
		upper = lower.AddDate(0, 0, 1)
	} else {
		lower = time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
		upper = lower.AddDate(0, 1, 0)
	}
	return
}

// FuturePartitionDates returns the start dates of count future partitions after now.
func FuturePartitionDates(now time.Time, period string, count int) []time.Time {
	dates := make([]time.Time, count)
	_, next := PartitionBounds(now, period)
	for i := range count {
		dates[i] = next
		_, next = PartitionBounds(next, period)
	}
	return dates
}

// EnsureFuture creates future partitions if they don't exist. The Boundary
// renders the FROM/TO bound values, so the same time-stepped schedule serves a
// time column (TimeBoundary) or a time-ordered id column (UUIDv7/Snowflake).
// leafPrefix is prepended to each partition name; "" yields the flat single-level
// names (p_2026_06), while a 2-level sub-tree passes its child name so leaves are
// unique across siblings (events_eu_p_2026_06).
func (m *Manager) EnsureFuture(ctx context.Context, parent, schema, column, period string, count int, now time.Time, b Boundary, leafPrefix string) error {
	for _, d := range FuturePartitionDates(now, period, count) {
		if err := m.createPartition(ctx, parent, schema, period, d, b, leafPrefix); err != nil {
			return err
		}
	}
	return nil
}

// EnsureCurrent creates the partition covering `now` (idempotent) and reports
// whether the table had already fallen behind: a PAST partition exists, yet none
// covers `now` — meaning the table has been in use but live inserts now have no
// home, so the premake cadence is too slow. The past-partition test matters
// because RunReconcile premakes the forward window (EnsureFuture) BEFORE this
// check, so a fresh table always has future partitions by now; keying "behind"
// off `len(parts) > 0` would spuriously fire on a freshly-bootstrapped table.
// Only future partitions present (a fresh table, or a newly provisioned sub-tree)
// is NOT behind; its current partition is simply created. Callers fail loud on a
// true return.
func (m *Manager) EnsureCurrent(ctx context.Context, parent, schema, period string, now time.Time, b Boundary, leafPrefix string) (bool, error) {
	parts, err := m.listPartitions(ctx, parent, schema, b)
	if err != nil {
		return false, err
	}
	covered := false
	hasPast := false
	for _, p := range parts {
		if p.LowerBound.After(now) {
			continue // future partition: irrelevant to coverage or to "behind"
		}
		if p.UpperBound.After(now) {
			covered = true // lower <= now < upper: covers now
			break
		}
		hasPast = true // lower <= now and upper <= now: a fully-past partition
	}
	behind := hasPast && !covered
	if !covered {
		if err := m.createPartition(ctx, parent, schema, period, now, b, leafPrefix); err != nil {
			return behind, err
		}
	}
	return behind, nil
}

// createPartition creates the single partition for the period containing d
// (idempotent). Shared by EnsureFuture and EnsureCurrent so name, bound and
// leaf-prefix handling live in one place.
func (m *Manager) createPartition(ctx context.Context, parent, schema, period string, d time.Time, b Boundary, leafPrefix string) error {
	lower, upper := PartitionBounds(d, period)
	name := leafPrefix + PartitionName(lower, period)
	if err := checkIdent(name); err != nil {
		return err
	}
	sql := fmt.Sprintf(
		`CREATE TABLE IF NOT EXISTS %s PARTITION OF %s FOR VALUES FROM (%s) TO (%s)`,
		pgx.Identifier{schema, name}.Sanitize(),
		pgx.Identifier{schema, parent}.Sanitize(),
		b.Literal(lower), b.Literal(upper))
	if _, err := m.db.Exec(ctx, sql); err != nil {
		return fmt.Errorf("create partition %s: %w", name, err)
	}
	return nil
}

// FindExpired returns partitions whose upper bound is at or before the cutoff.
func (m *Manager) FindExpired(ctx context.Context, parent, schema string, cutoff time.Time, b Boundary) ([]Info, error) {
	parts, err := m.listPartitions(ctx, parent, schema, b)
	if err != nil {
		return nil, err
	}
	var expired []Info
	for _, p := range parts {
		if !p.UpperBound.After(cutoff) {
			expired = append(expired, p)
		}
	}
	return expired, nil
}

// listPartitions enumerates every direct partition of parent with its bounds
// decoded to time via the Boundary. Shared by FindExpired and EnsureCurrent.
func (m *Manager) listPartitions(ctx context.Context, parent, schema string, b Boundary) ([]Info, error) {
	const query = `
		SELECT c.relname, pg_get_expr(c.relpartbound, c.oid)
		FROM pg_inherits i
		JOIN pg_class c ON c.oid = i.inhrelid
		JOIN pg_class p ON p.oid = i.inhparent
		JOIN pg_namespace n ON n.oid = p.relnamespace
		WHERE p.relname = $1 AND n.nspname = $2
		ORDER BY c.relname`

	rows, err := m.db.Query(ctx, query, parent, schema)
	if err != nil {
		return nil, fmt.Errorf("find partitions: %w", err)
	}
	defer rows.Close()

	var parts []Info
	for rows.Next() {
		var name, boundExpr string
		if err := rows.Scan(&name, &boundExpr); err != nil {
			return nil, fmt.Errorf("scan partition: %w", err)
		}
		lower, upper, err := parseBoundPair(boundExpr, b)
		if err != nil {
			return nil, fmt.Errorf("parse bounds for %s: %w", name, err)
		}
		parts = append(parts, Info{Name: name, LowerBound: lower, UpperBound: upper})
	}
	return parts, rows.Err()
}

// Detach detaches a partition from its parent concurrently. CONCURRENTLY avoids
// an ACCESS EXCLUSIVE lock on the parent, but it cannot run in a transaction
// block, so Spock's DDL replication silently skips it — on a mesh the partition
// would stay attached on every peer. We therefore detach locally (top-level on
// the pool, autocommit) and then fan the identical concurrent detach to each
// peer via coldfront._detach_partition_peers (a no-op on a non-mesh node).
func (m *Manager) Detach(ctx context.Context, parent, schema, partName string) error {
	qParent := pgx.Identifier{schema, parent}.Sanitize()
	qPart := pgx.Identifier{schema, partName}.Sanitize()
	if _, err := m.db.Exec(ctx, fmt.Sprintf(`ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY`, qParent, qPart)); err != nil {
		return fmt.Errorf("detach partition %s: %w", partName, err)
	}
	// Mesh fan-out: replicate the concurrent detach to every other node. Spock
	// cannot carry DETACH … CONCURRENTLY itself (it is non-transactional).
	if _, err := m.db.Exec(ctx, `SELECT coldfront._detach_partition_peers($1, $2)`, qParent, qPart); err != nil {
		return fmt.Errorf("detach partition %s on peers: %w", partName, err)
	}
	return nil
}

// Drop drops a partition table.
func (m *Manager) Drop(ctx context.Context, schema, partName string) error {
	sql := fmt.Sprintf(`DROP TABLE IF EXISTS %s`,
		pgx.Identifier{schema, partName}.Sanitize())
	if _, err := m.db.Exec(ctx, sql); err != nil {
		return fmt.Errorf("drop partition %s: %w", partName, err)
	}
	return nil
}

// RowCount returns the number of rows in a table.
func (m *Manager) RowCount(ctx context.Context, schema, tableName string) (int64, error) {
	var count int64
	sql := fmt.Sprintf(`SELECT count(*) FROM %s`,
		pgx.Identifier{schema, tableName}.Sanitize())
	if err := m.db.QueryRow(ctx, sql).Scan(&count); err != nil {
		return 0, fmt.Errorf("row count %s: %w", tableName, err)
	}
	return count, nil
}
