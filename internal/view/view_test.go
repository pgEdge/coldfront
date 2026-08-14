package view

import (
	"context"
	"strings"
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

// The cold INSERT crosses into DuckDB as text, and PG spells an array
// {1,2,3} while DuckDB's list cast only accepts [1,2,3]. translate is the whole
// conversion; the placeholder then casts to the Iceberg column's FLOAT[].
func TestGenerateTriggerFuncSQL_ColdInsertVectorBracketsAndCasts(t *testing.T) {
	sql := GenerateTriggerFuncSQL(vectorCfg)
	assert.Contains(t, sql, `translate(NEW."embedding"::text,'{}','[]')`,
		"PG array text must become a DuckDB list literal")
	assert.Contains(t, sql, "CAST(%L AS FLOAT[])",
		"the literal is cast to the Iceberg column type")
	assert.NotContains(t, sql, `NEW."embedding",`,
		"a bare real[] reaches DuckDB as {…} and fails to cast")
}

// The Iceberg schema leads with the cluster column, and this INSERT is positional
// because it is assembled positionally, so the value list leads with it too.
func TestGenerateTriggerFuncSQL_ColdInsertLeadsWithClusterColumn(t *testing.T) {
	sql := GenerateTriggerFuncSQL(vectorCfg)
	assert.Contains(t, sql, "VALUES (NULL, %L, %L, CAST(%L AS FLOAT[]))",
		"with no expression fetched the column is written unassigned")
}

// With the extension's expression fetched, the trigger emits it and repeats the
// vector's value for the placeholder inside it, so the two pair up positionally.
// The expression is not spelled here: one definition, in the extension.
func TestGenerateTriggerFuncSQL_ColdInsertAssignsTheCluster(t *testing.T) {
	cfg := vectorCfg
	cfg.VecListExpr = "(SELECT arg_min(c.centroid_id, list_cosine_distance(c.centroid, CAST(%L AS FLOAT[]))) FROM pglocal.coldfront.vector_centroids c)"
	sql := GenerateTriggerFuncSQL(cfg)
	// Doubled apostrophes: the template is itself a single-quoted string, so the
	// expression's own literals have to survive PostgreSQL's scan of it.
	assert.Contains(t, sql,
		"VALUES ("+strings.ReplaceAll(cfg.VecListExpr, "'", "''")+", %L, %L, CAST(%L AS FLOAT[]))",
		"the cluster expression leads the positional cold INSERT")
	assert.Contains(t, sql, `translate(NEW."embedding"::text,'{}','[]'), NEW."id"`,
		"the vector's value leads the argument list, feeding the expression")
	assert.Contains(t, sql, "PERFORM coldfront.ensure_pg_attached();",
		"the lookup reads the centroids over pglocal")
}

// A table with no vector never attaches pglocal: only the lookup reads it.
func TestGenerateTriggerFuncSQL_NoVectorNoPglocalAttach(t *testing.T) {
	assert.NotContains(t, GenerateTriggerFuncSQL(testCfg), "ensure_pg_attached")
}

// A table with no vector has no cluster column anywhere, so its generated SQL is
// exactly what it was. Asserted on a config with no identity column, since an
// identity already contributes a leading NULL of its own.
func TestGenerateTriggerFuncSQL_NoVectorNoClusterColumn(t *testing.T) {
	cfg := testCfg
	cfg.Columns = []Column{{Name: "ts", Type: "TIMESTAMPTZ"}, {Name: "status", Type: "VARCHAR"}}
	assert.Contains(t, GenerateTriggerFuncSQL(cfg), "VALUES (%L, %L)",
		"a table without a vector must not gain a leading placeholder")
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

// Trigger is INSERT-only: the C extension handles UPDATE/DELETE via CTE rewrite.
func TestGenerateTriggerFuncSQL_InsertOnly(t *testing.T) {
	sql := GenerateTriggerFuncSQL(testCfg)
	assert.Contains(t, sql, `CREATE OR REPLACE FUNCTION "coldfront"."events_write"`)
	assert.Contains(t, sql, "RETURNS trigger")
	assert.Contains(t, sql, "TG_OP = 'INSERT'")
	assert.NotContains(t, sql, "TG_OP = 'UPDATE'")
	assert.NotContains(t, sql, "TG_OP = 'DELETE'")
}

// Cold INSERT routes to duckdb.raw_query, not RAISE EXCEPTION.
func TestGenerateTriggerFuncSQL_ColdInsertRoutesToRawQuery(t *testing.T) {
	sql := GenerateTriggerFuncSQL(testCfg)
	assert.Contains(t, sql, "duckdb.raw_query")
	assert.NotContains(t, sql, "RAISE EXCEPTION")
	assert.NotContains(t, sql, "Cannot insert into archived range")
	// Cold INSERT must reference the Iceberg table
	assert.Contains(t, sql, "ice.default.events")
	// jsonb must be serialized to text on the cold-INSERT path (Iceberg
	// stores jsonb as VARCHAR). Independent of the view's read-side cast.
	assert.Contains(t, sql, `NEW."data"::text`)
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

// Cold-INSERT serialises each value through format()'s %L. bytea must go
// through from_hex(encode(NEW.col,'hex')) — %L renders a bytea as PG's '\xcafe'
// text which DuckDB mis-parses into a BLOB; round-tripping the hex string
// rebuilds the exact bytes. double precision round-trips fine as '2.5' text, so
// it stays native (no ::text). Only VARCHAR-backed json is ::text-serialised.
func TestGenerateTriggerFuncSQL_ColdInsertBlobViaFromHex(t *testing.T) {
	sql := GenerateTriggerFuncSQL(nativeCfg)
	assert.Contains(t, sql, "from_hex(%L)", "bytea placeholder rebuilds bytes in DuckDB")
	assert.Contains(t, sql, `encode(NEW."blob",'hex')`, "bytea value is sent as hex")
	assert.NotContains(t, sql, `NEW."blob"::text`, "bytea must not be ::text-stringified")
	assert.Contains(t, sql, `NEW."amt"`, "double inserted as-is (text round-trips)")
	assert.NotContains(t, sql, `NEW."amt"::text`, "double needs no ::text")
	assert.Contains(t, sql, `NEW."doc"::text`, "json IS VARCHAR-backed; serialise to text")
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

// Cold INSERT checks the watermark before routing.
func TestGenerateTriggerFuncSQL_ColdInsertWatermarkCheck(t *testing.T) {
	sql := GenerateTriggerFuncSQL(testCfg)
	assert.Contains(t, sql, "archive_watermark")
	assert.Contains(t, sql, "schema_name = 'public'") // watermark lookup is schema-scoped
	assert.Contains(t, sql, `NEW."ts" < cutoff`)
}

// Hot INSERT still goes to _events.
func TestGenerateTriggerFuncSQL_HotInsert(t *testing.T) {
	sql := GenerateTriggerFuncSQL(testCfg)
	assert.Contains(t, sql, `INSERT INTO "public"."_events"`)
	// INSERT column list excludes the identity column
	assert.Contains(t, sql, `"ts", "status", "data"`)
	// NEW.data arrives as jsonb natively (view exposes jsonb now), so no
	// cast is needed on the hot-INSERT path.
	assert.Contains(t, sql, `NEW."ts", NEW."status", NEW."data"`)
	assert.NotContains(t, sql, `NEW."data"::jsonb`, "NEW.data already jsonb, redundant cast removed")
	assert.NotContains(t, sql, `NEW."id"`)
}

// Non-identity, non-PK column named `id`: included in INSERT col list.
func TestGenerateTriggerFuncSQL_IdIsNotIdentity(t *testing.T) {
	cfg := ViewConfig{
		SourceSchema:    "public",
		SourceTable:     "events",
		IcebergTable:    "ice.default.events",
		CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		PartitionColumn: "ts",
		Columns: []Column{
			{Name: "event_id", Type: "UUID", IsPK: true},
			{Name: "id", Type: "BIGINT"},
			{Name: "ts", Type: "TIMESTAMPTZ"},
			{Name: "status", Type: "VARCHAR"},
		},
	}
	sql := GenerateTriggerFuncSQL(cfg)
	assert.Contains(t, sql, `"event_id", "id", "ts", "status"`)
	assert.Contains(t, sql, `NEW."event_id", NEW."id", NEW."ts", NEW."status"`)
}

// Composite PK: identity column excluded from INSERT col list.
func TestGenerateTriggerFuncSQL_CompositePK(t *testing.T) {
	cfg := ViewConfig{
		SourceSchema:    "public",
		SourceTable:     "events",
		IcebergTable:    "ice.default.events",
		CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		PartitionColumn: "ts",
		Columns: []Column{
			{Name: "tenant_id", Type: "INTEGER", IsPK: true},
			{Name: "event_id", Type: "BIGINT", IsPK: true, IsIdentity: true},
			{Name: "ts", Type: "TIMESTAMPTZ"},
			{Name: "status", Type: "VARCHAR"},
		},
	}
	sql := GenerateTriggerFuncSQL(cfg)
	assert.Contains(t, sql, `"tenant_id", "ts", "status"`)
	assert.NotContains(t, sql, `NEW."event_id"`)
}

// No PK: all non-identity columns in INSERT col list.
func TestGenerateTriggerFuncSQL_NoPK(t *testing.T) {
	cfg := ViewConfig{
		SourceSchema:    "public",
		SourceTable:     "events",
		IcebergTable:    "ice.default.events",
		CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		PartitionColumn: "ts",
		Columns: []Column{
			{Name: "ts", Type: "TIMESTAMPTZ"},
			{Name: "status", Type: "VARCHAR"},
		},
	}
	sql := GenerateTriggerFuncSQL(cfg)
	assert.Contains(t, sql, `"ts", "status"`)
	assert.NotContains(t, sql, `"id"`)
}

// Identity without PK: excluded from INSERT, trigger is still INSERT-only.
func TestGenerateTriggerFuncSQL_IdentityNoPK(t *testing.T) {
	cfg := ViewConfig{
		SourceSchema:    "public",
		SourceTable:     "events",
		IcebergTable:    "ice.default.events",
		CutoffTime:      time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC),
		PartitionColumn: "ts",
		Columns: []Column{
			{Name: "id", Type: "BIGINT", IsIdentity: true},
			{Name: "ts", Type: "TIMESTAMPTZ"},
			{Name: "status", Type: "VARCHAR"},
			{Name: "data", Type: "VARCHAR", ViewCastType: "json"},
		},
	}
	sql := GenerateTriggerFuncSQL(cfg)
	assert.NotContains(t, sql, `NEW."id"`)
	assert.Contains(t, sql, `"ts", "status", "data"`)
}

// Trigger fires on INSERT only — no UPDATE or DELETE.
func TestGenerateTriggerSQL_InsertOnly(t *testing.T) {
	sql := GenerateTriggerSQL(testCfg)
	assert.Contains(t, sql, `DROP TRIGGER IF EXISTS "events_write_trigger" ON "public"."events"`)
	assert.Contains(t, sql, `CREATE TRIGGER "events_write_trigger"`)
	assert.Contains(t, sql, `INSTEAD OF INSERT ON "public"."events"`)
	assert.NotContains(t, sql, "UPDATE")
	assert.NotContains(t, sql, "DELETE")
}

func TestRecreate(t *testing.T) {
	db := &mockDB{}
	g := NewGenerator(db)
	err := g.Recreate(context.Background(), testCfg)
	require.NoError(t, err)
	require.Len(t, db.execSQL, 4)
	assert.Contains(t, db.execSQL[0], `ALTER TABLE "public"."events" RENAME TO "_events"`)
	assert.Contains(t, db.execSQL[1], `"public"."_events"`)
	assert.Contains(t, db.execSQL[1], "iceberg_scan")
	assert.Contains(t, db.execSQL[2], "CREATE OR REPLACE FUNCTION")
	assert.Contains(t, db.execSQL[3], "CREATE TRIGGER")
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
