package partition

import (
	"context"
	"fmt"
	"strings"
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

// ResolveSourceTable returns the real partitioned table for a registered source
// name: "_"+source once the archiver's first-run hot-table swap has happened
// (source is then a unified VIEW over "_"+source), else source unchanged. Both
// the archiver and the standalone partitioner use this so they premake against
// the actual partitioned table rather than the post-swap view. A query failure
// falls back to source (treated as not-yet-swapped).
func ResolveSourceTable(ctx context.Context, db DBTX, schema, source string) string {
	var exists bool
	err := db.QueryRow(ctx /* nosemgrep */, `SELECT EXISTS (
		SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'p')`,
		schema, "_"+source).Scan(&exists)
	if err == nil && exists {
		return "_" + source
	}
	return source
}

// ResolveSourceTable resolves source against the Manager's connection.
func (m *Manager) ResolveSourceTable(ctx context.Context, schema, source string) string {
	return ResolveSourceTable(ctx, m.db, schema, source)
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
// leafPrefix is prepended to each partition name. "" means "scope to the parent
// table" (createPartition defaults it to parent_, e.g. events_p_2026_06), so two
// flat tables in one schema never collide; a 2-level sub-tree passes its child
// name so leaves are unique across siblings (events_eu_p_2026_06).
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
	// Table-scope the leaf name. The date suffix alone (p_2026_06) is not unique
	// within a schema, so two flat tables in the same schema would generate the
	// SAME partition name and the second's CREATE … IF NOT EXISTS would silently
	// no-op (issue #11). Prefixing with the parent table makes every leaf unique
	// per schema — the same scheme the 2-level path already uses (child_p_2026_06).
	// The leading "_" of a tiered hot table is stripped so the prefix is STABLE
	// across the archiver's events→_events rename: premake (pre-swap, parent
	// "events") and a later run (post-swap, parent "_events") must produce the
	// SAME leaf name, or the second run overlaps the first. "events" and "_events"
	// are one logical table, so they correctly share a partition namespace.
	if leafPrefix == "" {
		leafPrefix = strings.TrimPrefix(parent, "_") + "_"
	}
	name := leafPrefix + PartitionName(lower, period)
	if err := checkIdent(name); err != nil {
		return err
	}
	qname := pgx.Identifier{schema, name}.Sanitize()
	qparent := pgx.Identifier{schema, parent}.Sanitize()
	sql := fmt.Sprintf(
		`CREATE TABLE IF NOT EXISTS %s PARTITION OF %s FOR VALUES FROM (%s) TO (%s)`,
		qname, qparent, b.Literal(lower), b.Literal(upper))
	if _, err := m.db.Exec(ctx, sql); err != nil { // nosemgrep
		return fmt.Errorf("create partition %s: %w", name, err)
	}
	// CREATE … IF NOT EXISTS no-ops if a relation with this name already exists —
	// even one attached to a DIFFERENT parent (a name collision, or identifier
	// truncation). Verify the partition is actually attached to OUR parent, so a
	// collision fails loud instead of silently leaving the table partition-less
	// and the run reporting success (issue #11, bug 2).
	var attached bool
	if err := m.db.QueryRow(ctx,
		`SELECT EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid = to_regclass($1) AND inhparent = to_regclass($2))`,
		qname, qparent).Scan(&attached); err != nil {
		return fmt.Errorf("verify partition %s attached to %s.%s: %w", name, schema, parent, err)
	}
	if !attached {
		return fmt.Errorf("partition %q is not attached to %s.%s — a relation with that name already exists under a different parent; partition names must be unique within a schema", name, schema, parent)
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
// the pool, autocommit) and then, ONLY when Spock is present, fan the identical
// concurrent detach out to each peer ourselves. The fan-out is gated on Spock,
// so on vanilla single-node PostgreSQL it is skipped entirely — the binary
// depends on neither Spock nor the coldfront extension.
func (m *Manager) Detach(ctx context.Context, parent, schema, partName string) error {
	qParent := pgx.Identifier{schema, parent}.Sanitize()
	qPart := pgx.Identifier{schema, partName}.Sanitize()
	if _, err := m.db.Exec(ctx, fmt.Sprintf(`ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY`, qParent, qPart)); err != nil { // nosemgrep
		return fmt.Errorf("detach partition %s: %w", partName, err)
	}
	if err := m.detachOnPeers(ctx, qParent, qPart); err != nil {
		return fmt.Errorf("detach partition %s on peers: %w", partName, err)
	}
	return nil
}

// detachOnPeers re-runs the concurrent detach on every OTHER Spock node. Spock
// cannot replicate DETACH … CONCURRENTLY (non-transactional), so the retention
// detach is fanned out here, natively over a fresh autocommit connection per
// peer — no coldfront extension or dblink required. It is a no-op without Spock
// (vanilla single node has no peers) and idempotent: a peer where the partition
// is already detached or gone is skipped, so a re-run after a partial fan-out
// neither errors nor double-detaches.
func (m *Manager) detachOnPeers(ctx context.Context, qParent, qPart string) error {
	var hasSpock bool
	if err := m.db.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock')`).Scan(&hasSpock); err != nil {
		return fmt.Errorf("probe spock: %w", err)
	}
	if !hasSpock {
		return nil // vanilla single node — no peers, nothing to fan out
	}
	rows, err := m.db.Query(ctx, `
		SELECT nd.node_name, ni.if_dsn
		  FROM spock.node nd
		  JOIN spock.node_interface ni ON ni.if_nodeid = nd.node_id
		 WHERE nd.node_id <> (SELECT node_id FROM spock.local_node)`)
	if err != nil {
		return fmt.Errorf("enumerate spock peers: %w", err)
	}
	type peer struct{ name, dsn string }
	var peers []peer
	for rows.Next() {
		var p peer
		if err := rows.Scan(&p.name, &p.dsn); err != nil {
			rows.Close()
			return fmt.Errorf("scan spock peer: %w", err)
		}
		peers = append(peers, p)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return fmt.Errorf("enumerate spock peers: %w", err)
	}
	for _, p := range peers {
		// Reference the peer by node name, never the DSN (it may carry a secret).
		if err := detachOnPeer(ctx, p.dsn, qParent, qPart); err != nil {
			return fmt.Errorf("peer %q: %w", p.name, err)
		}
	}
	return nil
}

// detachOnPeer opens a fresh autocommit connection to one peer and runs the
// concurrent detach there, but only if the partition is still attached on that
// peer (to_regclass yields NULL for an already-detached/dropped partition, so
// the check returns 0 and the detach is skipped — keeping the fan-out
// idempotent). The DSN is never logged.
func detachOnPeer(ctx context.Context, dsn, qParent, qPart string) error {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	var attached int
	if err := conn.QueryRow(ctx,
		`SELECT count(*) FROM pg_inherits
		   WHERE inhparent = to_regclass($1) AND inhrelid = to_regclass($2)`,
		qParent, qPart).Scan(&attached); err != nil {
		return fmt.Errorf("check attach: %w", err)
	}
	if attached == 0 {
		return nil // already detached or gone on this peer
	}
	if _, err := conn.Exec(ctx, // nosemgrep
		fmt.Sprintf(`ALTER TABLE %s DETACH PARTITION %s CONCURRENTLY`, qParent, qPart)); err != nil {
		return fmt.Errorf("detach: %w", err)
	}
	return nil
}

// ExpiryCutoff resolves now - interval in Postgres so calendar months/years are
// exact (a real month, leap days, DST). The interval is a bound parameter, never
// concatenated. Returns the instant before which a partition has expired.
func (m *Manager) ExpiryCutoff(ctx context.Context, now time.Time, interval string) (time.Time, error) {
	var cutoff time.Time
	if err := m.db.QueryRow(ctx, `SELECT $1::timestamptz - $2::interval`, now, interval).Scan(&cutoff); err != nil {
		return time.Time{}, fmt.Errorf("resolve cutoff (now - %q): %w", interval, err)
	}
	return cutoff, nil
}

// Drop drops a partition table.
func (m *Manager) Drop(ctx context.Context, schema, partName string) error {
	sql := fmt.Sprintf(`DROP TABLE IF EXISTS %s`,
		pgx.Identifier{schema, partName}.Sanitize())
	if _, err := m.db.Exec(ctx, sql); err != nil { // nosemgrep
		return fmt.Errorf("drop partition %s: %w", partName, err)
	}
	return nil
}

// RowCount returns the number of rows in a table.
func (m *Manager) RowCount(ctx context.Context, schema, tableName string) (int64, error) {
	var count int64
	sql := fmt.Sprintf(`SELECT count(*) FROM %s`,
		pgx.Identifier{schema, tableName}.Sanitize())
	if err := m.db.QueryRow(ctx, sql).Scan(&count); err != nil { // nosemgrep
		return 0, fmt.Errorf("row count %s: %w", tableName, err)
	}
	return count, nil
}
