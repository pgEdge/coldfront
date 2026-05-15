package partition

import (
	"context"
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

func TestEnsureFuture(t *testing.T) {
	db := &mockDB{}
	m := NewManager(db)
	now := time.Date(2026, 4, 8, 0, 0, 0, 0, time.UTC)
	err := m.EnsureFuture(context.Background(), "events", "public", "time", "monthly", 2, now)
	require.NoError(t, err)
	// 2 partitions × 1 statement each (CREATE TABLE ... PARTITION OF)
	assert.Len(t, db.execSQL, 2)
	assert.Contains(t, db.execSQL[0], "CREATE TABLE IF NOT EXISTS")
	assert.Contains(t, db.execSQL[0], "p_2026_05")
	assert.Contains(t, db.execSQL[0], "PARTITION OF")
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
	parts, err := m.FindExpired(context.Background(), "events", "public", cutoff)
	require.NoError(t, err)
	require.Len(t, parts, 2)
	assert.Equal(t, "p_2025_11", parts[0].Name)
	assert.Equal(t, time.Date(2025, 12, 1, 0, 0, 0, 0, time.UTC), parts[0].UpperBound)
	assert.Equal(t, "p_2025_12", parts[1].Name)
}

func TestDetach(t *testing.T) {
	db := &mockDB{}
	m := NewManager(db)
	err := m.Detach(context.Background(), "events", "public", "p_2025_11")
	require.NoError(t, err)
	require.Len(t, db.execSQL, 1)
	assert.Contains(t, db.execSQL[0], "DETACH PARTITION")
	assert.Contains(t, db.execSQL[0], "CONCURRENTLY")
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
