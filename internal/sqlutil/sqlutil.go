// Package sqlutil holds tiny SQL string helpers shared between the archiver
// and the view generator. Anything bigger than a one-liner belongs in its own
// package.
package sqlutil

import "strings"

// Literal returns s as a single-quoted SQL string literal, escaping embedded
// apostrophes per the SQL standard (doubled). Use for values interpolated into
// SQL (PG or DuckDB) where parameter binding is unavailable — e.g. inside DO
// blocks, format() templates, or duckdb.raw_query payloads.
func Literal(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}
