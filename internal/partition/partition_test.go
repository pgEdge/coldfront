package partition

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// mockRow implements pgx.Row.
type mockRow struct {
	scanFunc func(dest ...any) error
}

func (r *mockRow) Scan(dest ...any) error { return r.scanFunc(dest...) }

// mockRows implements pgx.Rows.
type mockRows struct {
	rows   []func(dest ...any) error
	idx    int
	closed bool
}

func (r *mockRows) Next() bool {
	return r.idx < len(r.rows)
}

func (r *mockRows) Scan(dest ...any) error {
	fn := r.rows[r.idx]
	r.idx++
	return fn(dest...)
}

func (r *mockRows) Close()                                       { r.closed = true }
func (r *mockRows) Err() error                                   { return nil }
func (r *mockRows) CommandTag() pgconn.CommandTag                { return pgconn.NewCommandTag("SELECT") }
func (r *mockRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *mockRows) RawValues() [][]byte                          { return nil }
func (r *mockRows) Conn() *pgx.Conn                              { return nil }
func (r *mockRows) Values() ([]any, error)                       { return nil, nil }

// mockDB implements DBTX.
type mockDB struct {
	execSQL  []string
	execArgs [][]any
	execFunc func(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	rowFunc  func(ctx context.Context, sql string, args ...any) pgx.Row
	rowsFunc func(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

func (m *mockDB) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	m.execSQL = append(m.execSQL, sql)
	m.execArgs = append(m.execArgs, args)
	if m.execFunc != nil {
		return m.execFunc(ctx, sql, args...)
	}
	return pgconn.NewCommandTag("OK"), nil
}

func (m *mockDB) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	m.execSQL = append(m.execSQL, sql)
	if m.rowFunc != nil {
		return m.rowFunc(ctx, sql, args...)
	}
	return &mockRow{scanFunc: func(dest ...any) error { return pgx.ErrNoRows }}
}

func (m *mockDB) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	m.execSQL = append(m.execSQL, sql)
	if m.rowsFunc != nil {
		return m.rowsFunc(ctx, sql, args...)
	}
	return &mockRows{}, nil
}

func TestParseBoundExpr(t *testing.T) {
	tests := []struct {
		name     string
		expr     string
		wantLow  time.Time
		wantHigh time.Time
		wantErr  bool
	}{
		{
			name:     "monthly partition",
			expr:     "FOR VALUES FROM ('2025-11-01 00:00:00+00') TO ('2025-12-01 00:00:00+00')",
			wantLow:  time.Date(2025, 11, 1, 0, 0, 0, 0, time.UTC),
			wantHigh: time.Date(2025, 12, 1, 0, 0, 0, 0, time.UTC),
		},
		{
			name:     "daily partition",
			expr:     "FOR VALUES FROM ('2026-03-15 00:00:00+00') TO ('2026-03-16 00:00:00+00')",
			wantLow:  time.Date(2026, 3, 15, 0, 0, 0, 0, time.UTC),
			wantHigh: time.Date(2026, 3, 16, 0, 0, 0, 0, time.UTC),
		},
		{
			name:     "date only format",
			expr:     "FOR VALUES FROM ('2025-11-01') TO ('2025-12-01')",
			wantLow:  time.Date(2025, 11, 1, 0, 0, 0, 0, time.UTC),
			wantHigh: time.Date(2025, 12, 1, 0, 0, 0, 0, time.UTC),
		},
		{
			name:    "invalid format",
			expr:    "not a valid expression",
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			low, high, err := ParseBoundExpr(tt.expr)
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.wantLow, low)
			assert.Equal(t, tt.wantHigh, high)
		})
	}
}

func TestPartitionName(t *testing.T) {
	assert.Equal(t, "p_2026_03", PartitionName(time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC), "monthly"))
	assert.Equal(t, "p_2026_03_15", PartitionName(time.Date(2026, 3, 15, 0, 0, 0, 0, time.UTC), "daily"))
}

func TestPartitionBounds(t *testing.T) {
	lower, upper := PartitionBounds(time.Date(2026, 3, 15, 12, 0, 0, 0, time.UTC), "monthly")
	assert.Equal(t, time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC), lower)
	assert.Equal(t, time.Date(2026, 4, 1, 0, 0, 0, 0, time.UTC), upper)

	lower, upper = PartitionBounds(time.Date(2026, 3, 15, 12, 0, 0, 0, time.UTC), "daily")
	assert.Equal(t, time.Date(2026, 3, 15, 0, 0, 0, 0, time.UTC), lower)
	assert.Equal(t, time.Date(2026, 3, 16, 0, 0, 0, 0, time.UTC), upper)
}

func TestFuturePartitionDates(t *testing.T) {
	now := time.Date(2026, 4, 8, 12, 0, 0, 0, time.UTC)
	dates := FuturePartitionDates(now, "monthly", 3)
	require.Len(t, dates, 3)
	assert.Equal(t, time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC), dates[0])
	assert.Equal(t, time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC), dates[1])
	assert.Equal(t, time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC), dates[2])

	dates = FuturePartitionDates(now, "daily", 2)
	require.Len(t, dates, 2)
	assert.Equal(t, time.Date(2026, 4, 9, 0, 0, 0, 0, time.UTC), dates[0])
	assert.Equal(t, time.Date(2026, 4, 10, 0, 0, 0, 0, time.UTC), dates[1])
}

// attachedRow models the verify-attach guard's pg_inherits check: `attached`
// controls whether the just-created partition is reported as attached to our parent.
func attachedRow(attached bool) func(context.Context, string, ...any) pgx.Row {
	return func(_ context.Context, _ string, _ ...any) pgx.Row {
		return &mockRow{scanFunc: func(dest ...any) error { *(dest[0].(*bool)) = attached; return nil }}
	}
}

func TestEnsureFuture(t *testing.T) {
	db := &mockDB{rowFunc: attachedRow(true)}
	m := NewManager(db)
	now := time.Date(2026, 4, 8, 0, 0, 0, 0, time.UTC)
	err := m.EnsureFuture(context.Background(), "events", "public", "time", "monthly", 2, now, TimeBoundary{}, "")
	require.NoError(t, err)
	// 2 partitions × (CREATE + verify-attach) = 4 statements.
	assert.Len(t, db.execSQL, 4)
	assert.Contains(t, db.execSQL[0], "CREATE TABLE IF NOT EXISTS")
	// Table-scoped name (issue #11): the leaf is prefixed with the parent table.
	assert.Contains(t, db.execSQL[0], `"public"."events_p_2026_05"`)
	assert.Contains(t, db.execSQL[0], "PARTITION OF")
	// Time-mode bounds stay single-quoted timestamps (byte-for-byte legacy SQL).
	assert.Contains(t, db.execSQL[0], "FOR VALUES FROM ('2026-05-01 00:00:00+00') TO ('2026-06-01 00:00:00+00')")
}

// Issue #11, bug 1: two independent flat tables in the SAME schema must get
// DISTINCT, table-scoped partition names — never a shared p_2026_07 that the
// second table's CREATE … IF NOT EXISTS would silently skip.
func TestEnsureFuture_TableScopedPerTable(t *testing.T) {
	now := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	dbA := &mockDB{rowFunc: attachedRow(true)}
	require.NoError(t, NewManager(dbA).EnsureFuture(context.Background(), "table_a", "public", "ts", "monthly", 1, now, TimeBoundary{}, ""))
	dbB := &mockDB{rowFunc: attachedRow(true)}
	require.NoError(t, NewManager(dbB).EnsureFuture(context.Background(), "table_b", "public", "ts", "monthly", 1, now, TimeBoundary{}, ""))
	assert.Contains(t, dbA.execSQL[0], `"public"."table_a_p_2026_07"`)
	assert.Contains(t, dbB.execSQL[0], `"public"."table_b_p_2026_07"`)
	// Neither uses the un-scoped name that caused the collision.
	assert.NotContains(t, dbA.execSQL[0], `"public"."p_2026_07"`)
	assert.NotContains(t, dbB.execSQL[0], `"public"."p_2026_07"`)
}

// Issue #11, bug 2: if the scoped name already exists under a DIFFERENT parent,
// CREATE … IF NOT EXISTS no-ops; the verify-attach guard must fail loud rather
// than report success on a partition-less table.
func TestEnsureFuture_CollisionFailsLoud(t *testing.T) {
	db := &mockDB{rowFunc: attachedRow(false)} // pg_inherits: NOT attached to us
	now := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	err := NewManager(db).EnsureFuture(context.Background(), "table_b", "public", "ts", "monthly", 1, now, TimeBoundary{}, "")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not attached")
}

// partitionRows builds a mockDB.rowsFunc emitting (relname, relpartbound) pairs.
func partitionRows(pairs ...[2]string) func(context.Context, string, ...any) (pgx.Rows, error) {
	return func(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
		rows := make([]func(dest ...any) error, len(pairs))
		for i, p := range pairs {
			p := p
			rows[i] = func(dest ...any) error {
				*(dest[0].(*string)) = p[0]
				*(dest[1].(*string)) = p[1]
				return nil
			}
		}
		return &mockRows{rows: rows}, nil
	}
}

func hasCreate(sqls []string) bool {
	for _, s := range sqls {
		if strings.Contains(s, "CREATE TABLE IF NOT EXISTS") {
			return true
		}
	}
	return false
}

func TestEnsureCurrent_FreshCreatesNotBehind(t *testing.T) {
	db := &mockDB{rowsFunc: partitionRows(), rowFunc: attachedRow(true)} // no existing partitions
	m := NewManager(db)
	now := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	behind, err := m.EnsureCurrent(context.Background(), "events", "public", "monthly", now, TimeBoundary{}, "")
	require.NoError(t, err)
	assert.False(t, behind, "a fresh table is not behind")
	assert.True(t, hasCreate(db.execSQL), "current partition must be created")
}

func TestEnsureCurrent_CoveredNoCreateNotBehind(t *testing.T) {
	db := &mockDB{rowsFunc: partitionRows(
		[2]string{"p_2026_06", "FOR VALUES FROM ('2026-06-01 00:00:00+00') TO ('2026-07-01 00:00:00+00')"},
	)}
	m := NewManager(db)
	now := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	behind, err := m.EnsureCurrent(context.Background(), "events", "public", "monthly", now, TimeBoundary{}, "")
	require.NoError(t, err)
	assert.False(t, behind)
	assert.False(t, hasCreate(db.execSQL), "already covered: must not create")
}

func TestEnsureCurrent_GapIsBehindAndHeals(t *testing.T) {
	db := &mockDB{rowsFunc: partitionRows(
		[2]string{"p_2026_03", "FOR VALUES FROM ('2026-03-01 00:00:00+00') TO ('2026-04-01 00:00:00+00')"},
	), rowFunc: attachedRow(true)}
	m := NewManager(db)
	now := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	behind, err := m.EnsureCurrent(context.Background(), "events", "public", "monthly", now, TimeBoundary{}, "")
	require.NoError(t, err)
	assert.True(t, behind, "partitions exist but none covers now -> behind")
	assert.True(t, hasCreate(db.execSQL), "must heal by creating the current partition")
}

func TestEnsureCurrent_FutureOnlyNotBehind(t *testing.T) {
	// After EnsureFuture premakes the forward window on a FRESH table, the only
	// partitions present are future ones: none covers now, but the table never had
	// a current/past partition, so this is bootstrap — NOT a lagging cron. This is
	// the real-flow ordering (EnsureFuture before EnsureCurrent) that made a fresh
	// table's first reconcile spuriously report ErrBehind.
	db := &mockDB{rowsFunc: partitionRows(
		[2]string{"p_2026_07", "FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00')"},
		[2]string{"p_2026_08", "FOR VALUES FROM ('2026-08-01 00:00:00+00') TO ('2026-09-01 00:00:00+00')"},
		[2]string{"p_2026_09", "FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00')"},
	), rowFunc: attachedRow(true)}
	m := NewManager(db)
	now := time.Date(2026, 6, 15, 0, 0, 0, 0, time.UTC)
	behind, err := m.EnsureCurrent(context.Background(), "events", "public", "monthly", now, TimeBoundary{}, "")
	require.NoError(t, err)
	assert.False(t, behind, "only future partitions exist (fresh bootstrap) -> not behind")
	assert.True(t, hasCreate(db.execSQL), "current partition must still be created")
}

func TestFindExpired(t *testing.T) {
	db := &mockDB{
		rowsFunc: func(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
			return &mockRows{
				rows: []func(dest ...any) error{
					func(dest ...any) error {
						*(dest[0].(*string)) = "p_2025_11"
						*(dest[1].(*string)) = "FOR VALUES FROM ('2025-11-01 00:00:00+00') TO ('2025-12-01 00:00:00+00')"
						return nil
					},
					func(dest ...any) error {
						*(dest[0].(*string)) = "p_2025_12"
						*(dest[1].(*string)) = "FOR VALUES FROM ('2025-12-01 00:00:00+00') TO ('2026-01-01 00:00:00+00')"
						return nil
					},
				},
			}, nil
		},
	}
	m := NewManager(db)
	cutoff := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	parts, err := m.FindExpired(context.Background(), "events", "public", cutoff, TimeBoundary{})
	require.NoError(t, err)
	require.Len(t, parts, 2)
	assert.Equal(t, "p_2025_11", parts[0].Name)
	assert.Equal(t, time.Date(2025, 12, 1, 0, 0, 0, 0, time.UTC), parts[0].UpperBound)
	assert.Equal(t, "p_2025_12", parts[1].Name)
}

// TestEnsureFuture_SnowflakeBounds locks that an id-mode (snowflake) premake
// emits bare-integer RANGE bounds — and that those bounds decode back to the
// expected month, so the partition really does hold that month's snowflakes.
func TestEnsureFuture_SnowflakeBounds(t *testing.T) {
	db := &mockDB{rowFunc: attachedRow(true)}
	m := NewManager(db)
	now := time.Date(2026, 4, 8, 0, 0, 0, 0, time.UTC)
	err := m.EnsureFuture(context.Background(), "events", "public", "id", "monthly", 1, now, SnowflakeBoundary{}, "")
	require.NoError(t, err)
	require.Len(t, db.execSQL, 2) // CREATE + verify-attach
	lo := MinSnowflakeBound(time.Date(2026, 5, 1, 0, 0, 0, 0, time.UTC))
	hi := MinSnowflakeBound(time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC))
	assert.Contains(t, db.execSQL[0], fmt.Sprintf("FOR VALUES FROM (%d) TO (%d)", lo, hi))
	// No quotes around the integer bounds.
	assert.NotContains(t, db.execSQL[0], fmt.Sprintf("'%d'", lo))
}

// boolRow returns a rowFunc that scans a single bool (the Spock-presence probe).
func boolRow(v bool) func(context.Context, string, ...any) pgx.Row {
	return func(_ context.Context, _ string, _ ...any) pgx.Row {
		return &mockRow{scanFunc: func(dest ...any) error {
			*(dest[0].(*bool)) = v
			return nil
		}}
	}
}

// After the archiver's first-run swap "_events" is the partitioned table and
// "events" is a view over it; ResolveSourceTable probes for the "_"+source
// partitioned relation and returns it. It also confirms the EXISTS probe is run
// against the prefixed name.
func TestResolveSourceTable_AfterSwap(t *testing.T) {
	db := &mockDB{
		rowFunc: func(_ context.Context, _ string, args ...any) pgx.Row {
			assert.Equal(t, "_events", args[1])
			return &mockRow{scanFunc: func(dest ...any) error {
				*(dest[0].(*bool)) = true
				return nil
			}}
		},
	}
	assert.Equal(t, "_events", ResolveSourceTable(context.Background(), db, "public", "events"))
}

// Before any swap (or for a partition-only table) the "_"+source relation does
// not exist, so the source name is returned unchanged.
func TestResolveSourceTable_BeforeSwap(t *testing.T) {
	db := &mockDB{rowFunc: boolRow(false)}
	assert.Equal(t, "events", ResolveSourceTable(context.Background(), db, "public", "events"))
}

// A probe failure is treated as not-yet-swapped: fall back to the source name.
func TestResolveSourceTable_QueryError(t *testing.T) {
	db := &mockDB{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(_ ...any) error { return errors.New("boom") }}
		},
	}
	assert.Equal(t, "events", ResolveSourceTable(context.Background(), db, "public", "events"))
}

// On vanilla single-node PostgreSQL (no Spock) Detach does the local concurrent
// detach and then SKIPS the peer fan-out entirely — so the binary needs neither
// Spock nor the coldfront extension. This is the no-dependency path.
func TestDetach_VanillaNoSpock(t *testing.T) {
	db := &mockDB{rowFunc: boolRow(false)} // pg_extension probe: spock absent
	m := NewManager(db)
	err := m.Detach(context.Background(), "events", "public", "p_2025_11")
	require.NoError(t, err)
	// [0] local concurrent detach, [1] the Spock probe — and nothing else.
	require.Len(t, db.execSQL, 2)
	assert.Contains(t, db.execSQL[0], "DETACH PARTITION")
	assert.Contains(t, db.execSQL[0], "CONCURRENTLY")
	assert.Contains(t, db.execSQL[1], "pg_extension")
	assert.Contains(t, db.execSQL[1], "spock")
	for _, sql := range db.execSQL {
		assert.NotContains(t, sql, "_detach_partition_peers",
			"the binary must not depend on the coldfront extension")
	}
}

// On a Spock node Detach does the local detach, probes Spock, then enumerates
// peers from spock.node to fan the concurrent detach out itself. (Zero peers
// here keeps it connection-free; real peer fan-out is covered by the live mesh
// test.) No coldfront extension is ever referenced.
func TestDetach_SpockEnumeratesPeers(t *testing.T) {
	db := &mockDB{
		rowFunc:  boolRow(true),                                                                       // spock present
		rowsFunc: func(context.Context, string, ...any) (pgx.Rows, error) { return &mockRows{}, nil }, // no peers
	}
	m := NewManager(db)
	err := m.Detach(context.Background(), "events", "public", "p_2025_11")
	require.NoError(t, err)
	// [0] local detach, [1] Spock probe, [2] peer enumeration over spock.node.
	require.Len(t, db.execSQL, 3)
	assert.Contains(t, db.execSQL[0], "DETACH PARTITION")
	assert.Contains(t, db.execSQL[2], "spock.node")
	for _, sql := range db.execSQL {
		assert.NotContains(t, sql, "_detach_partition_peers")
	}
}

func TestDrop(t *testing.T) {
	db := &mockDB{}
	m := NewManager(db)
	err := m.Drop(context.Background(), "public", "p_2025_11")
	require.NoError(t, err)
	require.Len(t, db.execSQL, 1)
	assert.Contains(t, db.execSQL[0], "DROP TABLE")
	// Identifiers are always double-quoted (pgx.Identifier behavior).
	assert.Contains(t, db.execSQL[0], `"public"."p_2025_11"`)
}

// ExpiryCutoff resolves the cutoff in Postgres (now - interval) so calendar
// months/years are exact — never Go duration math. White-box: assert the SQL
// shape, that the interval is a bound parameter (not concatenated), and that the
// scanned timestamptz is returned. (Calendar correctness itself is PostgreSQL's,
// exercised live in ci/journey.sh.)
func TestExpiryCutoff(t *testing.T) {
	want := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	var gotSQL string
	var gotArgs []any
	db := &mockDB{rowFunc: func(_ context.Context, sql string, args ...any) pgx.Row {
		gotSQL = sql
		gotArgs = args
		return &mockRow{scanFunc: func(dest ...any) error { *(dest[0].(*time.Time)) = want; return nil }}
	}}
	m := NewManager(db)
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	got, err := m.ExpiryCutoff(context.Background(), now, "3 months")
	require.NoError(t, err)
	assert.True(t, got.Equal(want), "cutoff = %v, want %v", got, want)
	assert.Contains(t, gotSQL, "::timestamptz")
	assert.Contains(t, gotSQL, "::interval")
	require.Len(t, gotArgs, 2)
	assert.Equal(t, now, gotArgs[0])
	assert.Equal(t, "3 months", gotArgs[1]) // interval is parameterized, not concatenated
}

// Complex identifiers: hyphens in schema / partition name must be quoted;
// locks in the contract that partition.Manager uses pgx.Identifier end-to-end.
func TestDrop_ComplexIdentifiers(t *testing.T) {
	db := &mockDB{}
	m := NewManager(db)
	err := m.Drop(context.Background(), "my-schema", "p_2025-11")
	require.NoError(t, err)
	require.Len(t, db.execSQL, 1)
	assert.Contains(t, db.execSQL[0], `DROP TABLE IF EXISTS "my-schema"."p_2025-11"`)
}

func TestRowCount(t *testing.T) {
	db := &mockDB{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				*(dest[0].(*int64)) = 42
				return nil
			}}
		},
	}
	m := NewManager(db)
	count, err := m.RowCount(context.Background(), "public", "p_2025_11")
	require.NoError(t, err)
	assert.Equal(t, int64(42), count)
}
