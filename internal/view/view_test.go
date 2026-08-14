package view

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type mockDB struct {
	execSQL []string
}

func (m *mockDB) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	m.execSQL = append(m.execSQL, sql)
	return pgconn.NewCommandTag("OK"), nil
}

func (m *mockDB) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row { return nil }

// Canonical test config: id is GENERATED ALWAYS AS IDENTITY and is the PK.
var testCfg = ViewConfig{
	SourceSchema:    "public",
	SourceTable:     "events",
	IcebergTable:    "ice.default.events",
	CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
	PartitionColumn: "ts",
	Columns: []Column{
		{Name: "id", Type: "BIGINT", IsIdentity: true, IsPK: true},
		{Name: "ts", Type: "TIMESTAMPTZ"},
		{Name: "status", Type: "VARCHAR"},
		{Name: "data", Type: "VARCHAR", ViewCastType: "json"},
	},
}

// A tiered table carrying an embedding. The view exposes the column as real[],
// so that is what NEW.embedding is inside the INSTEAD OF trigger.
var vectorCfg = ViewConfig{
	SourceSchema:    "public",
	SourceTable:     "chunks",
	IcebergTable:    "ice.default.chunks",
	CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
	PartitionColumn: "ts",
	Columns: []Column{
		{Name: "id", Type: "BIGINT", IsPK: true},
		{Name: "ts", Type: "TIMESTAMPTZ"},
		{Name: "embedding", Type: "FLOAT[]", ViewCastType: "real[]"},
	},
}

// pg_duckdb rejects a pgvector column while it builds the plan, before any cast in
// the projection can apply, so the hot table carries a generated real[] companion
// and the hot branch reads that under the user's own column name. The view still
// exposes one embedding column, and the companion is never a column of the view.
func TestGenerateViewSQL_VectorHotSourceIsTheCompanion(t *testing.T) {
	cfg := vectorCfg
	cfg.Columns = []Column{
		{Name: "id", Type: "BIGINT", IsPK: true},
		{Name: "ts", Type: "TIMESTAMPTZ"},
		{Name: "embedding", Type: "FLOAT[]", ViewCastType: "real[]", HotSource: "_cf_vec_embedding"},
	}
	sql := GenerateViewSQL(cfg)
	assert.Contains(t, sql, `"_cf_vec_embedding"::real[] AS "embedding"`,
		"hot branch reads the companion, aliased to the user's column name")
	assert.NotContains(t, sql, `"embedding"::real[] FROM`,
		"the pgvector column itself must not be scanned")
	assert.Contains(t, sql, "r['embedding']::real[]", "the cold branch is unchanged")
}

// A column without a HotSource is read by its own name, which is every column that
// is not a vector.
func TestGenerateViewSQL_NoHotSourceReadsItsOwnName(t *testing.T) {
	assert.Contains(t, GenerateViewSQL(testCfg), `"status"::VARCHAR`)
}

// The distance operators are installed only for a table that carries a vector.
func TestGenerateVectorOpsSQL(t *testing.T) {
	cfg := vectorCfg
	assert.Equal(t, "SELECT coldfront.install_vector_ops()", GenerateVectorOpsSQL(cfg))
	assert.Equal(t, "", GenerateVectorOpsSQL(testCfg), "no vector column, no operators")
}

// The companion is added to the renamed hot table, idempotently, and only for a
// column that needs one.
func TestGenerateVecCompanionSQL(t *testing.T) {
	cfg := vectorCfg
	cfg.Columns = []Column{
		{Name: "id", Type: "BIGINT"},
		{Name: "embedding", Type: "FLOAT[]", ViewCastType: "real[]", HotSource: "_cf_vec_embedding"},
	}
	sql := GenerateVecCompanionSQL(cfg)
	assert.Contains(t, sql, `ALTER TABLE "public"."_chunks" ADD COLUMN IF NOT EXISTS "_cf_vec_embedding" real[]`)
	assert.Contains(t, sql, `GENERATED ALWAYS AS ("embedding"::real[]) STORED`)
	assert.Equal(t, "", GenerateVecCompanionSQL(testCfg), "no vector column, no companion")
}

// The view exposes real[] on both branches: FLOAT[] would parse in PG as
// double precision[] and the two branches would disagree.
func TestGenerateViewSQL_VectorSurfaceIsRealArray(t *testing.T) {
	sql := GenerateViewSQL(vectorCfg)
	assert.Contains(t, sql, `"embedding"::real[]`, "hot side casts to real[]")
	assert.Contains(t, sql, "r['embedding']::real[]", "cold side casts to real[]")
	assert.NotContains(t, sql, "::FLOAT[]", "FLOAT[] is double precision[] in PG")
}

func TestGenerateSwapSQL(t *testing.T) {
	sql := GenerateSwapSQL(testCfg)
	// Identifier positions are double-quoted; literal-string positions keep
	// single-quoted form (they match against pg_class.relname raw values).
	assert.Contains(t, sql, `ALTER TABLE "public"."events" RENAME TO "_events"`)
	assert.Contains(t, sql, "relname = 'events'")
	assert.Contains(t, sql, "relkind = 'p'")
}

func TestGenerateViewSQL_WithCutoff(t *testing.T) {
	sql := GenerateViewSQL(testCfg)
	assert.Contains(t, sql, `CREATE OR REPLACE VIEW "public"."events"`)
	assert.Contains(t, sql, `"public"."_events"`)
	assert.Contains(t, sql, `"ts" >= '2026-03-01`)
	assert.Contains(t, sql, "UNION ALL")
	assert.Contains(t, sql, "iceberg_scan")
	assert.Contains(t, sql, "r['id']::BIGINT")
	// jsonb columns: the view exposes them as `json` on both sides (pg_duckdb
	// takes over the whole query and DuckDB has no jsonb type; json works
	// and pg_duckdb maps it back to PG json).
	assert.Contains(t, sql, `"data"::json`, "hot side casts jsonb→json to unify UNION types")
	assert.NotContains(t, sql, `"data"::text`, "jsonb must not be downcast to text on hot side")
	assert.Contains(t, sql, "r['data']::json")
	assert.NotContains(t, sql, "r['data']::text", "cold side must cast to json, not text")
	assert.NotContains(t, sql, "::jsonb", "jsonb cast fails through pg_duckdb; must use json")
	assert.Contains(t, sql, "r['ts'] < '2026-03-01")
}

func TestGenerateViewSQL_NoCutoff(t *testing.T) {
	cfg := ViewConfig{SourceSchema: "public", SourceTable: "events"}
	sql := GenerateViewSQL(cfg)
	assert.Contains(t, sql, `CREATE OR REPLACE VIEW "public"."events"`)
	assert.Contains(t, sql, `"public"."_events"`)
	assert.NotContains(t, sql, "UNION ALL")
}

// nativeCfg has columns whose Iceberg storage is NATIVE (BLOB / DOUBLE) but
// which carry a ViewCastType only for the view's PG-parseable hot-side cast.
var nativeCfg = ViewConfig{
	SourceSchema:    "public",
	SourceTable:     "ev",
	IcebergTable:    "ice.default.ev",
	CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
	PartitionColumn: "ts",
	Columns: []Column{
		{Name: "ts", Type: "TIMESTAMPTZ"},
		{Name: "blob", Type: "BLOB", ViewCastType: "bytea"},
		{Name: "amt", Type: "DOUBLE", ViewCastType: "double precision"},
		{Name: "doc", Type: "VARCHAR", ViewCastType: "json"},
	},
}

// Only two storage forms need a PG-side cast on the way out to pg_duckdb: the
// VARCHAR-backed rich types and the vector. Everything else exports as-is, and
// a ViewCastType alone does not imply a cast (bytea and double carry one purely
// so the view has a PG-parseable spelling).
func TestColumn_ExportCast(t *testing.T) {
	for _, tt := range []struct {
		name string
		col  Column
		want string
	}{
		{"jsonb is VARCHAR-backed", Column{Type: "VARCHAR", ViewCastType: "json"}, "text"},
		{"interval is VARCHAR-backed", Column{Type: "VARCHAR", ViewCastType: "interval"}, "text"},
		{"plain text needs nothing", Column{Type: "VARCHAR"}, ""},
		{"bytea exports as bytes", Column{Type: "BLOB", ViewCastType: "bytea"}, ""},
		{"double exports as-is", Column{Type: "DOUBLE", ViewCastType: "double precision"}, ""},
		{"integer exports as-is", Column{Type: "INTEGER"}, ""},
		{"vector exports as real[]", Column{Type: "FLOAT[]", ViewCastType: "real[]"}, "real[]"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			assert.Equal(t, tt.want, tt.col.ExportCast())
		})
	}
}

// The view casts BLOB→bytea / DOUBLE→double precision on BOTH UNION branches
// so the surface type is PG-parseable and the branches unify.
func TestGenerateViewSQL_NativeSurfaceCast(t *testing.T) {
	sql := GenerateViewSQL(nativeCfg)
	assert.Contains(t, sql, `"blob"::bytea`, "hot side casts BLOB→bytea")
	assert.Contains(t, sql, "r['blob']::bytea", "cold side casts to bytea")
	assert.Contains(t, sql, `"amt"::double precision`, "hot side casts DOUBLE→double precision")
	assert.Contains(t, sql, "r['amt']::double precision")
	assert.NotContains(t, sql, "::BLOB", "BLOB is not a PG-parseable cast name")
	assert.NotContains(t, sql, "::DOUBLE ", "bare ::DOUBLE is not a PG type")
}

// The central invariant of the surface-cast change: the bootstrap (no-cutoff,
// hot-only) view applies the SAME hot-side casts as the post-cutover view, so
// CREATE OR REPLACE VIEW never trips "cannot change data type of view column".
func TestGenerateViewSQL_BootstrapMatchesCutoverHotCasts(t *testing.T) {
	withCutoff := nativeCfg
	bootstrap := nativeCfg
	bootstrap.CutoffTime = time.Time{} // zero → no cold side

	bsql := GenerateViewSQL(bootstrap)
	assert.NotContains(t, bsql, "UNION ALL", "bootstrap is hot-only")
	// Every surface cast present in the cutover view's hot branch must also be
	// present in the bootstrap view.
	for _, frag := range []string{`"blob"::bytea`, `"amt"::double precision`, `"doc"::json`, `"ts"::TIMESTAMPTZ`} {
		assert.Contains(t, bsql, frag, "bootstrap hot cast must match cutover")
		assert.Contains(t, GenerateViewSQL(withCutoff), frag, "cutover hot cast")
	}
}

func TestRecreate(t *testing.T) {
	db := &mockDB{}
	g := NewGenerator(db)
	err := g.Recreate(context.Background(), testCfg)
	require.NoError(t, err)
	// Swap and view only: the write trigger is coldfront._rebuild_write_trigger's,
	// built by the archiver after registration.
	require.Len(t, db.execSQL, 2)
	assert.Contains(t, db.execSQL[0], `ALTER TABLE "public"."events" RENAME TO "_events"`)
	assert.Contains(t, db.execSQL[1], `"public"."_events"`)
	assert.Contains(t, db.execSQL[1], "iceberg_scan")
}

// Complex identifiers: mixed case, hyphens, reserved keywords, embedded
// double-quotes. Locks in the contract that identifier injection points
// go through pgx.Identifier.Sanitize (quoted + escaped) and literal-string
// positions keep single-quoted form.
func TestGenerateViewSQL_ComplexIdentifiers(t *testing.T) {
	cfg := ViewConfig{
		SourceSchema:    "my-Schema",
		SourceTable:     `Weird"Events`,
		IcebergTable:    `ice.default."Weird""Events"`,
		CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		PartitionColumn: "Ts",
		Columns: []Column{
			{Name: "Id", Type: "BIGINT", IsIdentity: true, IsPK: true},
			{Name: `odd"name`, Type: "VARCHAR"},
		},
	}

	sql := GenerateViewSQL(cfg)

	// Schema and view/table identifiers are double-quoted; embedded double
	// quotes doubled per PG rules.
	assert.Contains(t, sql, `CREATE OR REPLACE VIEW "my-Schema"."Weird""Events"`)
	assert.Contains(t, sql, `FROM "my-Schema"."_Weird""Events"`)

	// Column identifiers on the hot side: quoted with embedded-quote doubling,
	// each cast to its surface type (same cast as the cold side) so bootstrap
	// and post-cutover view column types stay identical.
	assert.Contains(t, sql, `"Id"::BIGINT, "odd""name"::VARCHAR`)

	// Partition column on the hot side is a PG identifier.
	assert.Contains(t, sql, `"Ts" >=`)

	// Cold-side column keys inside r['...'] are DuckDB string literals —
	// apostrophe-escaped (no doubles here), NOT double-quoted. The
	// embedded double quote in `odd"name` passes through unchanged.
	assert.Contains(t, sql, `r['odd"name']::VARCHAR`)
	assert.Contains(t, sql, `r['Ts'] <`)
}
