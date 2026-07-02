package partcfg

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type mockRows struct {
	rows []func(dest ...any) error
	idx  int
}

func (r *mockRows) Next() bool { return r.idx < len(r.rows) }
func (r *mockRows) Scan(dest ...any) error {
	fn := r.rows[r.idx]
	r.idx++
	return fn(dest...)
}
func (r *mockRows) Close()                                       {}
func (r *mockRows) Err() error                                   { return nil }
func (r *mockRows) CommandTag() pgconn.CommandTag                { return pgconn.NewCommandTag("SELECT") }
func (r *mockRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *mockRows) Values() ([]any, error)                       { return nil, nil }
func (r *mockRows) RawValues() [][]byte                          { return nil }
func (r *mockRows) Conn() *pgx.Conn                              { return nil }

type mockDB struct {
	execSQL   []string
	rowsFunc  func() (pgx.Rows, error)
	querySQL  string // last Query SQL — lets tests assert the ownership filter
	queryArgs []any  // last Query args — $1 is the owner selector
}

func (m *mockDB) Exec(_ context.Context, sql string, _ ...any) (pgconn.CommandTag, error) {
	m.execSQL = append(m.execSQL, sql)
	return pgconn.NewCommandTag("OK"), nil
}
func (m *mockDB) Query(_ context.Context, sql string, args ...any) (pgx.Rows, error) {
	m.querySQL, m.queryArgs = sql, args
	return m.rowsFunc()
}

func sp(s string) *string { return &s }

func TestEnsureTable(t *testing.T) {
	db := &mockDB{}
	if err := EnsureTable(context.Background(), db); err != nil {
		t.Fatal(err)
	}
	if len(db.execSQL) != 4 {
		t.Fatalf("expected schema + table DDL + add-column + repset, got %d execs", len(db.execSQL))
	}
	if !strings.Contains(db.execSQL[0], "CREATE SCHEMA IF NOT EXISTS coldfront") {
		t.Errorf("missing schema DDL: %s", db.execSQL[0])
	}
	if !strings.Contains(db.execSQL[1], "coldfront.partition_config") ||
		!strings.Contains(db.execSQL[1], "CREATE TABLE IF NOT EXISTS") {
		t.Errorf("missing table DDL: %s", db.execSQL[1])
	}
	// Idempotent upgrade for an existing table missing the newer column.
	if !strings.Contains(db.execSQL[2], "ADD COLUMN IF NOT EXISTS expiration_strategy") {
		t.Errorf("missing add-column upgrade step: %s", db.execSQL[2])
	}
	// The replication step is spock-gated and idempotent.
	if !strings.Contains(db.execSQL[3], "repset_add_table") ||
		!strings.Contains(db.execSQL[3], "pg_extension WHERE extname = 'spock'") {
		t.Errorf("missing spock-gated repset step: %s", db.execSQL[3])
	}
}

func emptyRows() (pgx.Rows, error) { return &mockRows{}, nil }

func TestResolveTables_ReturnsDBRows(t *testing.T) {
	db := &mockDB{rowsFunc: func() (pgx.Rows, error) {
		return &mockRows{rows: []func(dest ...any) error{
			func(dest ...any) error {
				*(dest[0].(*string)) = "public"
				*(dest[1].(*string)) = "events"
				*(dest[2].(*string)) = "monthly"
				*(dest[3].(**string)) = sp("ts")
				*(dest[4].(*int)) = 3
				*(dest[5].(*string)) = "timestamp"
				*(dest[8].(**string)) = sp("12 months")
				return nil
			},
		}}, nil
	}}
	// The row is partition-only (hot NULL), so the partitioner owns it.
	got, err := ResolveTables(context.Background(), db, PartitionOnly)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].SourceTable != "events" {
		t.Fatalf("expected the DB row, got %+v", got)
	}
}

func TestLoadTables(t *testing.T) {
	db := &mockDB{rowsFunc: func() (pgx.Rows, error) {
		return &mockRows{rows: []func(dest ...any) error{
			// flat timestamp, partition-only: hot NULL, retention set
			func(dest ...any) error {
				*(dest[0].(*string)) = "public"
				*(dest[1].(*string)) = "events"
				*(dest[2].(*string)) = "monthly"
				*(dest[3].(**string)) = sp("ts")
				*(dest[4].(*int)) = 3
				*(dest[5].(*string)) = "timestamp"
				// dest[6] id_scheme, dest[7] hot_period left NULL (nil)
				*(dest[8].(**string)) = sp("12 months")
				// dest[9] sub_part_values_source left NULL
				return nil
			},
			// 2-level id-mode (partition-only): id_scheme + sub-partition set
			func(dest ...any) error {
				*(dest[0].(*string)) = "public"
				*(dest[1].(*string)) = "regional"
				*(dest[2].(*string)) = "daily"
				*(dest[3].(**string)) = sp("id")
				*(dest[4].(*int)) = 5
				*(dest[5].(*string)) = "id"
				*(dest[6].(**string)) = sp("snowflake")
				*(dest[8].(**string)) = sp("7 days")
				*(dest[9].(**string)) = sp("SELECT region FROM regions")
				return nil
			},
		}}, nil
	}}

	got, err := LoadTables(context.Background(), db, AllOwners)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 tables, got %d", len(got))
	}

	a := got[0]
	if a.SourceSchema != "public" || a.SourceTable != "events" || a.PartitionPeriod != "monthly" ||
		a.PartitionColumn != "ts" || a.FuturePartitions != 3 || a.PartMode != "timestamp" ||
		a.RetentionPeriod != "12 months" {
		t.Fatalf("row 0 mapping wrong: %+v", a)
	}
	if a.IDScheme != "" || a.HotPeriod != "" || a.SubPartition != nil {
		t.Fatalf("row 0 NULLs not handled: idScheme=%q hot=%q sub=%v", a.IDScheme, a.HotPeriod, a.SubPartition)
	}

	b := got[1]
	if b.SourceTable != "regional" || b.PartMode != "id" || b.IDScheme != "snowflake" ||
		b.PartitionColumn != "id" || b.FuturePartitions != 5 || b.RetentionPeriod != "7 days" {
		t.Fatalf("row 1 mapping wrong: %+v", b)
	}
	if b.SubPartition == nil || b.SubPartition.ValuesSource != "SELECT region FROM regions" {
		t.Fatalf("row 1 sub-partition not mapped: %v", b.SubPartition)
	}
	if b.HotPeriod != "" {
		t.Fatalf("row 1 hot_period should be empty (partition-only), got %q", b.HotPeriod)
	}
}

// TestLoadTables_PassesOwnerFilter pins issue #14: each binary must scope its
// load by ownership. The mock ignores the WHERE clause itself, so we assert the
// owner selector reaches the query as $1 (the real Postgres filter is proven
// end-to-end in ci/journey.sh). int(owner): AllOwners=0, Tiered=1, PartitionOnly=2.
func TestLoadTables_PassesOwnerFilter(t *testing.T) {
	for _, tc := range []struct {
		name string
		own  owner
		want int
	}{
		{"export loads all", AllOwners, 0},
		{"archiver loads tiered", Tiered, 1},
		{"partitioner loads partition-only", PartitionOnly, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			db := &mockDB{rowsFunc: emptyRows}
			if _, err := LoadTables(context.Background(), db, tc.own); err != nil {
				t.Fatal(err)
			}
			if len(db.queryArgs) != 1 {
				t.Fatalf("expected 1 query arg (the owner selector), got %v", db.queryArgs)
			}
			if got, ok := db.queryArgs[0].(int); !ok || got != tc.want {
				t.Fatalf("owner selector $1 = %v, want %d", db.queryArgs[0], tc.want)
			}
		})
	}
}

// TestResolveTables_EmptyWhenNoRows — partition_config is the only source: an
// empty table (or a result the owner filter empties out, indistinguishable in
// SQL) yields an empty slice and no error. Callers fail loud on empty.
func TestResolveTables_EmptyWhenNoRows(t *testing.T) {
	db := &mockDB{rowsFunc: emptyRows}
	got, err := ResolveTables(context.Background(), db, Tiered)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 0 {
		t.Fatalf("expected empty result when partition_config has no rows, got %+v", got)
	}
}
