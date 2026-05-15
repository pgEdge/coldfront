package watermark

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// mockRow implements pgx.Row for testing.
type mockRow struct {
	scanFunc func(dest ...any) error
}

func (r *mockRow) Scan(dest ...any) error { return r.scanFunc(dest...) }

// mockDB implements DBTX for testing.
type mockDB struct {
	execSQL  []string
	execFunc func(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	rowFunc  func(ctx context.Context, sql string, args ...any) pgx.Row
}

func (m *mockDB) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	m.execSQL = append(m.execSQL, sql)
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

func TestEnsureTable(t *testing.T) {
	db := &mockDB{}
	s := NewStore(db)
	err := s.EnsureTable(context.Background())
	require.NoError(t, err)
	require.Len(t, db.execSQL, 2)
	assert.Contains(t, db.execSQL[0], "CREATE SCHEMA")
	assert.Contains(t, db.execSQL[1], "CREATE TABLE")
	assert.Contains(t, db.execSQL[1], "archive_watermark")
}

func TestGet_Found(t *testing.T) {
	cutoff := time.Date(2025, 12, 1, 0, 0, 0, 0, time.UTC)
	db := &mockDB{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				*(dest[0].(*time.Time)) = cutoff
				return nil
			}}
		},
	}
	s := NewStore(db)
	got, found, err := s.Get(context.Background(), "events")
	require.NoError(t, err)
	assert.True(t, found)
	assert.Equal(t, cutoff, got)
}

func TestGet_NotFound(t *testing.T) {
	db := &mockDB{} // default rowFunc returns ErrNoRows
	s := NewStore(db)
	_, found, err := s.Get(context.Background(), "events")
	require.NoError(t, err)
	assert.False(t, found)
}

func TestGet_Error(t *testing.T) {
	db := &mockDB{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				return errors.New("db error")
			}}
		},
	}
	s := NewStore(db)
	_, _, err := s.Get(context.Background(), "events")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "get watermark")
}

func TestSet(t *testing.T) {
	cutoff := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	db := &mockDB{}
	s := NewStore(db)
	err := s.Set(context.Background(), "events", cutoff)
	require.NoError(t, err)
	require.Len(t, db.execSQL, 1)
	assert.Contains(t, db.execSQL[0], "INSERT INTO")
	assert.Contains(t, db.execSQL[0], "ON CONFLICT")
}

func TestSet_Error(t *testing.T) {
	db := &mockDB{
		execFunc: func(_ context.Context, _ string, _ ...any) (pgconn.CommandTag, error) {
			return pgconn.CommandTag{}, errors.New("write error")
		},
	}
	s := NewStore(db)
	err := s.Set(context.Background(), "events", time.Now())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "set watermark")
}
