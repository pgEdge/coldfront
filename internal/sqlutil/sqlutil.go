// Package sqlutil holds tiny SQL string helpers shared between the archiver
// and the view generator. Anything bigger than a one-liner belongs in its own
// package.
package sqlutil

import (
	"fmt"
	"strings"
	"time"
)

// Literal returns s as a single-quoted SQL string literal, escaping embedded
// apostrophes per the SQL standard (doubled). Use for values interpolated into
// SQL (PG or DuckDB) where parameter binding is unavailable — e.g. inside DO
// blocks, format() templates, or duckdb.raw_query payloads.
func Literal(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// Timestamp renders t as PostgreSQL parses it back: ISO, UTC, no surrounding
// quotes (callers supply those). Go prints a non-positive astronomical year as a
// negative number, which PostgreSQL rejects with "time zone displacement out of
// range"; before year 1 it wants the era suffix, where astronomical year Y is
// 1-Y BC. The inverse of the bound parser in internal/partition.
func Timestamp(t time.Time) string {
	u := t.UTC()
	if u.Year() > 0 {
		return u.Format("2006-01-02 15:04:05+00")
	}
	return fmt.Sprintf("%04d-%s BC", 1-u.Year(), u.Format("01-02 15:04:05+00"))
}
