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

// DBTX abstracts pgxpool.Pool and pgx.Tx for testability.
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
func (m *Manager) EnsureFuture(ctx context.Context, parent, schema, column, period string, count int, now time.Time, b Boundary) error {
	dates := FuturePartitionDates(now, period, count)
	fqParent := pgx.Identifier{schema, parent}.Sanitize()

	for _, d := range dates {
		name := PartitionName(d, period)
		_, upper := PartitionBounds(d, period)
		fqName := pgx.Identifier{schema, name}.Sanitize()

		sql := fmt.Sprintf(
			`CREATE TABLE IF NOT EXISTS %s PARTITION OF %s FOR VALUES FROM (%s) TO (%s)`,
			fqName, fqParent, b.Literal(d), b.Literal(upper))
		if _, err := m.db.Exec(ctx, sql); err != nil {
			return fmt.Errorf("create partition %s: %w", name, err)
		}
	}
	return nil
}

// FindExpired returns partitions whose upper bound is at or before the cutoff.
// The Boundary converts each partition's stored bound value back to time, so id
// bounds compare against a time cutoff just like time bounds.
func (m *Manager) FindExpired(ctx context.Context, parent, schema string, cutoff time.Time, b Boundary) ([]Info, error) {
	query := `
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

	var expired []Info
	for rows.Next() {
		var name, boundExpr string
		if err := rows.Scan(&name, &boundExpr); err != nil {
			return nil, fmt.Errorf("scan partition: %w", err)
		}
		lower, upper, err := parseBoundPair(boundExpr, b)
		if err != nil {
			return nil, fmt.Errorf("parse bounds for %s: %w", name, err)
		}
		if !upper.After(cutoff) {
			expired = append(expired, Info{Name: name, LowerBound: lower, UpperBound: upper})
		}
	}
	return expired, rows.Err()
}

// Detach detaches a partition from its parent concurrently.
func (m *Manager) Detach(ctx context.Context, parent, schema, partName string) error {
	sql := fmt.Sprintf(`ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY`,
		pgx.Identifier{schema, parent}.Sanitize(),
		pgx.Identifier{schema, partName}.Sanitize())
	if _, err := m.db.Exec(ctx, sql); err != nil {
		return fmt.Errorf("detach partition %s: %w", partName, err)
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
