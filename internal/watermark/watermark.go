package watermark

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// DBTX abstracts *pgx.Conn and pgx.Tx for testability.
type DBTX interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// Store manages the archive watermark table.
type Store struct {
	db DBTX
}

// NewStore creates a new watermark Store.
func NewStore(db DBTX) *Store {
	return &Store{db: db}
}

// EnsureTable creates the coldfront schema and archive_watermark table if they don't exist.
func (s *Store) EnsureTable(ctx context.Context) error {
	if _, err := s.db.Exec(ctx, `CREATE SCHEMA IF NOT EXISTS coldfront`); err != nil {
		return fmt.Errorf("create schema: %w", err)
	}
	if _, err := s.db.Exec(ctx, `
		CREATE TABLE IF NOT EXISTS coldfront.archive_watermark (
			table_name  text PRIMARY KEY,
			cutoff_time timestamptz NOT NULL
		)`); err != nil {
		return fmt.Errorf("create watermark table: %w", err)
	}
	return nil
}

// Get returns the cutoff time for the given table. If no watermark exists, found is false.
func (s *Store) Get(ctx context.Context, tableName string) (cutoff time.Time, found bool, err error) {
	err = s.db.QueryRow(ctx,
		`SELECT cutoff_time FROM coldfront.archive_watermark WHERE table_name = $1`,
		tableName,
	).Scan(&cutoff)
	if errors.Is(err, pgx.ErrNoRows) {
		return time.Time{}, false, nil
	}
	if err != nil {
		return time.Time{}, false, fmt.Errorf("get watermark: %w", err)
	}
	return cutoff, true, nil
}

// Set upserts the cutoff time for the given table.
func (s *Store) Set(ctx context.Context, tableName string, cutoff time.Time) error {
	if _, err := s.db.Exec(ctx, `
		INSERT INTO coldfront.archive_watermark (table_name, cutoff_time)
		VALUES ($1, $2)
		ON CONFLICT (table_name) DO UPDATE SET cutoff_time = EXCLUDED.cutoff_time`,
		tableName, cutoff,
	); err != nil {
		return fmt.Errorf("set watermark: %w", err)
	}
	return nil
}
