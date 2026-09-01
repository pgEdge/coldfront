package partcfg

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/pgedge/coldfront/internal/config"
)

func TestLit(t *testing.T) {
	if got := lit(""); got != "NULL" {
		t.Errorf("lit(\"\") = %q, want NULL", got)
	}
	if got := lit("monthly"); got != "'monthly'" {
		t.Errorf("lit(monthly) = %q", got)
	}
	if got := lit("o'brien"); got != "'o''brien'" {
		t.Errorf("lit escaping = %q", got)
	}
}

func TestRowFrom_AppliesDefaults(t *testing.T) {
	// A minimal TableConfig (as from YAML) gets the same defaults the loader applies.
	r := rowFrom(config.TableConfig{SourceTable: "events", PartitionPeriod: "monthly", RetentionPeriod: "1 year"})
	if r.schema != "public" || r.premake != 3 || r.partMode != "timestamp" {
		t.Fatalf("defaults not applied: %+v", r)
	}
	if r.table != "events" || r.retention != "1 year" {
		t.Fatalf("fields not mapped: %+v", r)
	}
}

func TestRowFrom_SubPartition(t *testing.T) {
	r := rowFrom(config.TableConfig{
		SourceTable: "regional", PartitionPeriod: "monthly", PartitionColumn: "ts",
		HotPeriod: "1 month", FuturePartitions: 5,
		SubPartition: &config.SubPartitionConfig{ValuesSource: "SELECT region FROM regions"},
	})
	if r.subValues != "SELECT region FROM regions" || r.hot != "1 month" || r.premake != 5 {
		t.Fatalf("2-level/tiered mapping wrong: %+v", r)
	}
}

func TestIsCommand(t *testing.T) {
	for _, c := range []string{"register", "list"} {
		if !IsCommand(c) {
			t.Errorf("IsCommand(%q) = false, want true", c)
		}
	}
	for _, c := range []string{"reconcile", "archive", "--config", "bogus", ""} {
		if IsCommand(c) {
			t.Errorf("IsCommand(%q) = true, want false", c)
		}
	}
}

func TestInsertSQL_PartitionOnly(t *testing.T) {
	got := configRow{
		schema: "public", table: "events", period: "monthly",
		premake: 3, partMode: "timestamp", retention: "12 months",
	}.insertSQL()
	// quoted values, NULL for the empty optional columns
	for _, want := range []string{
		"INSERT INTO coldfront.partition_config",
		"'public', 'events', 'monthly', NULL, 3, 'timestamp', NULL, NULL, '12 months', NULL",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("insertSQL missing %q:\n%s", want, got)
		}
	}
}

func TestInsertSQL_IDModeAndSub(t *testing.T) {
	got := configRow{
		schema: "public", table: "regional", period: "daily", column: "id",
		premake: 5, partMode: "id", idScheme: "snowflake",
		retention: "7 days", subValues: "SELECT region FROM regions",
	}.insertSQL()
	if !strings.Contains(got, "'id', 'snowflake'") {
		t.Errorf("id-mode not rendered:\n%s", got)
	}
	if !strings.Contains(got, "'SELECT region FROM regions'") {
		t.Errorf("sub-values not rendered:\n%s", got)
	}
}

func TestInsertSQL_EscapesQuotes(t *testing.T) {
	got := configRow{
		schema: "public", table: "events", period: "monthly", retention: "1 year",
		subValues: "SELECT code FROM o'brien",
	}.insertSQL()
	if !strings.Contains(got, "'SELECT code FROM o''brien'") {
		t.Errorf("single quote not doubled:\n%s", got)
	}
}

// Re-registering an existing (schema, table) upserts: the INSERT carries an
// ON CONFLICT (schema_name, table_name) DO UPDATE clause.
func TestInsertSQL_Upsert(t *testing.T) {
	got := configRow{
		schema: "myapp", table: "events", period: "monthly",
		premake: 3, partMode: "timestamp", hot: "30 days",
	}.insertSQL()
	for _, want := range []string{
		"ON CONFLICT (schema_name, table_name) DO UPDATE SET",
		"partition_period = EXCLUDED.partition_period",
		"hot_period = EXCLUDED.hot_period",
		"retention_period = EXCLUDED.retention_period",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("insertSQL missing %q:\n%s", want, got)
		}
	}
}

func TestSetClauses(t *testing.T) {
	vals := setVals{
		period: "monthly", column: "ts", premake: 6,
		hot: "1 month", retention: "5 years",
		subValues: "SELECT region FROM regions", strategy: "detach",
	}
	cases := []struct {
		flag string
		want string
	}{
		{"period", "partition_period='monthly'"},
		{"column", "partition_column='ts'"},
		{"premake", "future_partitions=6"},
		{"hot-period", "hot_period='1 month'"},
		{"retention", "retention_period='5 years'"},
		{"sub-values-source", "sub_part_values_source='SELECT region FROM regions'"},
		{"strategy", "expiration_strategy='detach'"},
		{"enable", "enabled=true"},
		{"disable", "enabled=false"},
	}
	for _, c := range cases {
		clause, ok := setClauses[c.flag]
		if !ok {
			t.Errorf("setClauses missing %q", c.flag)
			continue
		}
		if got := clause(vals); got != c.want {
			t.Errorf("setClauses[%q] = %q, want %q", c.flag, got, c.want)
		}
	}
	// An empty value clears the column (NULL), which is how --hot-period "" works.
	if got := setClauses["hot-period"](setVals{}); got != "hot_period=NULL" {
		t.Errorf("empty hot-period = %q, want hot_period=NULL", got)
	}
}

func TestPartKeyCols(t *testing.T) {
	cases := []struct {
		def  string
		want []string
	}{
		{"RANGE (ts)", []string{"ts"}},
		{"LIST (region)", []string{"region"}},
		{"RANGE (tenant_id, ts)", []string{"tenant_id", "ts"}},
		{"garbage", nil},
		{"", nil},
	}
	for _, c := range cases {
		got := partKeyCols(c.def)
		if len(got) != len(c.want) {
			t.Errorf("partKeyCols(%q) = %v, want %v", c.def, got, c.want)
			continue
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Errorf("partKeyCols(%q) = %v, want %v", c.def, got, c.want)
				break
			}
		}
	}
}

// mockRow / persistDB: the one-row scalar surface the register guards need.
type mockRow struct{ scan func(dest ...any) error }

func (r *mockRow) Scan(dest ...any) error { return r.scan(dest...) }

type persistDB struct {
	mockDB
	scalar  string
	err     error
	gotArgs []any
}

func (p *persistDB) QueryRow(_ context.Context, _ string, args ...any) pgx.Row {
	p.gotArgs = args
	return &mockRow{scan: func(dest ...any) error {
		if p.err != nil {
			return p.err
		}
		*(dest[0].(*string)) = p.scalar
		return nil
	}}
}

func TestRequireLogged_RejectsUnloggedRelations(t *testing.T) {
	// The error names the offending relations.
	db := &persistDB{scalar: "public.events_p_2026_01, public.events_p_2026_02"}
	err := requireLogged(context.Background(), db, "public", "events")
	if err == nil {
		t.Fatal("expected rejection")
	}
	for _, want := range []string{"unlogged", "events_p_2026_01", "events_p_2026_02"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err.Error(), want)
		}
	}
}

func TestRequireLogged_AcceptsFullyLoggedTree(t *testing.T) {
	db := &persistDB{scalar: ""}
	if err := requireLogged(context.Background(), db, "public", "events"); err != nil {
		t.Fatalf("a permanent tree must pass: %v", err)
	}
	if len(db.gotArgs) != 2 || db.gotArgs[0] != "public" || db.gotArgs[1] != "events" {
		t.Errorf("schema/table not passed as args: %v", db.gotArgs)
	}
}

func TestRequireLogged_PropagatesQueryError(t *testing.T) {
	db := &persistDB{err: errors.New("boom")}
	if err := requireLogged(context.Background(), db, "public", "events"); err == nil {
		t.Fatal("query failure must not be reported as a clean tree")
	}
}

func TestRequireNoCaseCollision_RejectsDifferentCase(t *testing.T) {
	// The error names the row already holding the folded name.
	db := &persistDB{scalar: "public.events"}
	err := requireNoCaseCollision(context.Background(), db, "public", "Events")
	if err == nil {
		t.Fatal("expected rejection")
	}
	for _, want := range []string{"public.events", "case-insensitively", "Events"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err.Error(), want)
		}
	}
}

func TestRequireNoCaseCollision_AllowsExactSameName(t *testing.T) {
	// Re-registering the identical name is an update, not a collision.
	db := &persistDB{scalar: ""}
	if err := requireNoCaseCollision(context.Background(), db, "public", "events"); err != nil {
		t.Fatalf("re-registering the same name must be allowed: %v", err)
	}
	if len(db.gotArgs) != 2 || db.gotArgs[0] != "public" || db.gotArgs[1] != "events" {
		t.Errorf("schema/table not passed as args: %v", db.gotArgs)
	}
}

func TestRequireNoCaseCollision_PropagatesQueryError(t *testing.T) {
	db := &persistDB{err: errors.New("boom")}
	if err := requireNoCaseCollision(context.Background(), db, "public", "events"); err == nil {
		t.Fatal("query failure must not be reported as no collision")
	}
}

func TestRequireNoDefaultPartition_Rejects(t *testing.T) {
	// A DEFAULT partition has no bounds, so its rows never tier and never
	// expire, and PostgreSQL refuses DETACH CONCURRENTLY for every partition of
	// a table that has one, which is how partitions are expired. The error names
	// it and the remedy.
	db := &persistDB{scalar: "public.events_default"}
	err := requireNoDefaultPartition(context.Background(), db, "public", "events")
	if err == nil {
		t.Fatal("expected rejection")
	}
	for _, want := range []string{"events_default", "default partition", "detach"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err.Error(), want)
		}
	}
}

func TestRequireNoDefaultPartition_AcceptsPlainTable(t *testing.T) {
	db := &persistDB{scalar: ""}
	if err := requireNoDefaultPartition(context.Background(), db, "public", "events"); err != nil {
		t.Fatalf("a table with no default must pass: %v", err)
	}
	if len(db.gotArgs) != 2 || db.gotArgs[0] != "public" || db.gotArgs[1] != "events" {
		t.Errorf("schema/table not passed as args: %v", db.gotArgs)
	}
}

func TestRequireNoDefaultPartition_PropagatesQueryError(t *testing.T) {
	db := &persistDB{err: errors.New("boom")}
	if err := requireNoDefaultPartition(context.Background(), db, "public", "events"); err == nil {
		t.Fatal("query failure must not be reported as no default")
	}
}

// coldTierDB answers the two questions the column guard asks: does this database
// have the extension, then what does its type map say about the table's columns.
// checkErr stands in for the RAISE the extension throws on a type Iceberg cannot
// store.
type coldTierDB struct {
	mockDB
	installed bool
	checkErr  error
	asked     []string
	args      []any
}

func (d *coldTierDB) QueryRow(_ context.Context, sql string, args ...any) pgx.Row {
	d.asked = append(d.asked, sql)
	if len(d.asked) == 1 {
		return &mockRow{scan: func(dest ...any) error {
			*(dest[0].(*bool)) = d.installed
			return nil
		}}
	}
	d.args = args
	return &mockRow{scan: func(dest ...any) error {
		if d.checkErr != nil {
			return d.checkErr
		}
		*(dest[0].(*int)) = 3
		return nil
	}}
}

// The message the extension raises for the canonical case: PostgreSQL's
// full-text pattern is a generated tsvector column, and Iceberg has no type
// for it.
var errUnmappable = errors.New("ERROR: coldfront: PG type tsvector has no Iceberg-compatible mapping")

func TestRequireMappableColumns_RejectsUnmappableType(t *testing.T) {
	// The rejection carries the extension's own wording (which type), the table
	// it came from, and the partition-only alternative, which is open at
	// registration and gone by archive time.
	db := &coldTierDB{installed: true, checkErr: errUnmappable}
	err := requireMappableColumns(context.Background(), db, "public", "events", "1 month")
	if err == nil {
		t.Fatal("expected rejection")
	}
	for _, want := range []string{"public.events", "tsvector", "partitions only"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %q", err.Error(), want)
		}
	}
}

func TestRequireMappableColumns_SkipsPartitionOnlyRow(t *testing.T) {
	// No hot period, no cold tier: the column types are PostgreSQL's business
	// alone, and a table that registers today must keep registering. The same
	// unmappable table passes, without the database being asked at all.
	db := &coldTierDB{installed: true, checkErr: errUnmappable}
	if err := requireMappableColumns(context.Background(), db, "public", "events", ""); err != nil {
		t.Fatalf("a partition-only row must not be type-checked: %v", err)
	}
	if len(db.asked) != 0 {
		t.Errorf("a partition-only row queried the database: %v", db.asked)
	}
}

func TestRequireMappableColumns_SkipsDatabaseWithoutTheExtension(t *testing.T) {
	// A stock-PG partitioner node has no cold tier, so there is nothing for the
	// row to be wrong about, and nothing to ask.
	db := &coldTierDB{installed: false, checkErr: errUnmappable}
	if err := requireMappableColumns(context.Background(), db, "public", "events", "1 month"); err != nil {
		t.Fatalf("a database with no cold tier must not be type-checked: %v", err)
	}
	if len(db.asked) != 1 {
		t.Errorf("expected only the extension probe, got %d queries", len(db.asked))
	}
}

func TestRequireMappableColumns_AcceptsMappableTable(t *testing.T) {
	db := &coldTierDB{installed: true}
	if err := requireMappableColumns(context.Background(), db, "public", "events", "1 month"); err != nil {
		t.Fatalf("a fully mappable table must pass: %v", err)
	}
	if len(db.args) != 2 || db.args[0] != "public" || db.args[1] != "events" {
		t.Errorf("schema/table not passed as args: %v", db.args)
	}
	// The extension's map decides, not a second copy in Go, and its companion
	// predicate is what keeps a vector's generated real[] column out of the check.
	for _, want := range []string{"coldfront._iceberg_storage_type", "coldfront._is_vec_companion"} {
		if !strings.Contains(db.asked[1], want) {
			t.Errorf("the check does not go through %s", want)
		}
	}
}
