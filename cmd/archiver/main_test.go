package main

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/pgedge/coldfront/internal/config"
	"github.com/pgedge/coldfront/internal/view"
)

func TestColdSecretSQL_S3(t *testing.T) {
	cfg := &config.Config{S3: config.S3Config{
		AccessKey: "admin", SecretKey: "adminsecret", Endpoint: "sw:8333", Region: "us-east-1",
	}}
	sql := coldSecretSQL(cfg)
	assert.Contains(t, sql, "TYPE S3")
	assert.Contains(t, sql, "KEY_ID 'admin'")
	assert.Contains(t, sql, "ENDPOINT 'sw:8333'")
	assert.Contains(t, sql, "URL_STYLE 'path'") // default for a custom (compat) endpoint
	assert.Contains(t, sql, "USE_SSL false")    // default: plain-http compat store (SeaweedFS)
	assert.NotContains(t, sql, "azure")
}

// Real AWS S3: NO endpoint configured. The secret must OMIT ENDPOINT/URL_STYLE/
// USE_SSL so DuckDB uses its native virtual-hosted + https endpoint for the
// Region — REQUIRED for Regions launched after 2019-03-20 (e.g. ap-south-2),
// whose DNS does not route path-style requests (HTTP 400).
func TestColdSecretSQL_S3_AWSNoEndpoint(t *testing.T) {
	cfg := &config.Config{S3: config.S3Config{
		AccessKey: "AKIAEXAMPLE", SecretKey: "awssecret", Region: "ap-south-2",
	}}
	sql := coldSecretSQL(cfg)
	assert.Contains(t, sql, "TYPE S3")
	assert.Contains(t, sql, "REGION 'ap-south-2'")
	assert.NotContains(t, sql, "ENDPOINT")
	assert.NotContains(t, sql, "URL_STYLE")
	assert.NotContains(t, sql, "USE_SSL")
}

// A custom endpoint that requires virtual-hosted addressing (s3.url_style: vhost).
func TestColdSecretSQL_S3_VhostOverride(t *testing.T) {
	cfg := &config.Config{S3: config.S3Config{
		AccessKey: "k", SecretKey: "s", Endpoint: "minio.example.com",
		Region: "us-east-1", URLStyle: "vhost", UseSSL: true,
	}}
	sql := coldSecretSQL(cfg)
	assert.Contains(t, sql, "URL_STYLE 'vhost'")
	assert.NotContains(t, sql, "URL_STYLE 'path'")
	assert.Contains(t, sql, "USE_SSL true")
}

// GCS is an S3-compatible store reached via its interop endpoint over TLS — no
// separate backend, just the s3 path with a custom endpoint + use_ssl: true.
func TestColdSecretSQL_S3_GCS(t *testing.T) {
	cfg := &config.Config{S3: config.S3Config{
		AccessKey: "GOOGHMAC", SecretKey: "hmacsecret",
		Endpoint: "storage.googleapis.com", Region: "us-east-1", UseSSL: true,
	}}
	sql := coldSecretSQL(cfg)
	assert.Contains(t, sql, "TYPE S3")
	assert.Contains(t, sql, "ENDPOINT 'storage.googleapis.com'")
	assert.Contains(t, sql, "USE_SSL true")
	assert.NotContains(t, sql, "USE_SSL false")
}

func TestColdSecretSQL_Azure(t *testing.T) {
	cfg := &config.Config{Azure: config.AzureConfig{
		ConnectionString: "DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=Zm9v;EndpointSuffix=core.windows.net",
	}}
	sql := coldSecretSQL(cfg)
	assert.Contains(t, sql, "TYPE azure")
	assert.Contains(t, sql, "CONNECTION_STRING 'DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=Zm9v;EndpointSuffix=core.windows.net'")
	assert.NotContains(t, sql, "TYPE S3")
}

func TestStaticCredsConfigured(t *testing.T) {
	s3 := &config.Config{S3: config.S3Config{AccessKey: "a", SecretKey: "s"}}
	assert.True(t, staticCredsConfigured(s3), "s3 access key ⇒ static")

	azure := &config.Config{Azure: config.AzureConfig{
		ConnectionString: "AccountName=acct;AccountKey=Zm9v"}}
	assert.True(t, staticCredsConfigured(azure), "azure connection string ⇒ static")

	vended := &config.Config{Iceberg: config.IcebergConfig{
		Warehouse: "wh", LakekeeperEndpoint: "http://lk:8181/catalog"}}
	assert.False(t, staticCredsConfigured(vended), "no creds ⇒ vended")
}

// mockRow / mockRows / mockQuerier mirror the pattern in
// internal/partition/partition_test.go. Hand-written, no mock framework.
type mockRow struct {
	scanFunc func(dest ...any) error
}

func (r *mockRow) Scan(dest ...any) error { return r.scanFunc(dest...) }

type mockRows struct {
	rows []func(dest ...any) error
	idx  int
	err  error
}

func (r *mockRows) Next() bool                                   { return r.idx < len(r.rows) }
func (r *mockRows) Scan(dest ...any) error                       { fn := r.rows[r.idx]; r.idx++; return fn(dest...) }
func (r *mockRows) Close()                                       {}
func (r *mockRows) Err() error                                   { return r.err }
func (r *mockRows) CommandTag() pgconn.CommandTag                { return pgconn.NewCommandTag("SELECT") }
func (r *mockRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *mockRows) RawValues() [][]byte                          { return nil }
func (r *mockRows) Conn() *pgx.Conn                              { return nil }
func (r *mockRows) Values() ([]any, error)                       { return nil, nil }

type mockQuerier struct {
	rowFunc  func(ctx context.Context, sql string, args ...any) pgx.Row
	rowsFunc func(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	execFunc func(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func (m *mockQuerier) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	if m.execFunc != nil {
		return m.execFunc(ctx, sql, args...)
	}
	return pgconn.NewCommandTag("OK"), nil
}

func (m *mockQuerier) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	if m.rowFunc != nil {
		return m.rowFunc(ctx, sql, args...)
	}
	return &mockRow{scanFunc: func(dest ...any) error { return pgx.ErrNoRows }}
}

func (m *mockQuerier) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	if m.rowsFunc != nil {
		return m.rowsFunc(ctx, sql, args...)
	}
	return &mockRows{}, nil
}

func TestPgFormatTypeToDuckDB(t *testing.T) {
	tests := []struct {
		pg              string
		wantStorage     string
		wantViewCastTyp string
		wantErr         bool
	}{
		// Storage matches surface — no view cast.
		{pg: "bigint", wantStorage: "BIGINT"},
		{pg: "integer", wantStorage: "INTEGER"},
		{pg: "smallint", wantStorage: "INTEGER"}, // widened; INTEGER is its own surface
		{pg: "real", wantStorage: "REAL"},
		{pg: "double precision", wantStorage: "DOUBLE", wantViewCastTyp: "double precision"}, // ::double is a PG shell type
		{pg: "boolean", wantStorage: "BOOLEAN"},
		{pg: "timestamp with time zone", wantStorage: "TIMESTAMPTZ"},
		{pg: "timestamp without time zone", wantStorage: "TIMESTAMP"},
		{pg: "date", wantStorage: "DATE"},
		{pg: "time without time zone", wantStorage: "TIME"},
		{pg: "uuid", wantStorage: "UUID"},
		{pg: "text", wantStorage: "VARCHAR"},
		{pg: "character varying(255)", wantStorage: "VARCHAR"},
		{pg: "character varying", wantStorage: "VARCHAR"},
		{pg: "character(10)", wantStorage: "VARCHAR"},
		{pg: "bytea", wantStorage: "BLOB", wantViewCastTyp: "bytea"}, // BLOB not PG-parseable
		{pg: "numeric(20,5)", wantStorage: "DECIMAL(20,5)"},
		{pg: "numeric(38, 10)", wantStorage: "DECIMAL(38,10)"},

		// Storage + surface differ — view casts on both branches.
		{pg: "jsonb", wantStorage: "VARCHAR", wantViewCastTyp: "json"},
		{pg: "json", wantStorage: "VARCHAR", wantViewCastTyp: "json"},
		{pg: "interval", wantStorage: "VARCHAR", wantViewCastTyp: "interval"},

		// Errors. inet/cidr/oid are rejected: pg_duckdb cannot process them in
		// an Iceberg-backed query, and every tiered read is planned by pg_duckdb,
		// so there is no cast that makes them readable (oid would archive fine but
		// its column becomes unreadable through the view after cutover).
		{pg: "inet", wantErr: true},
		{pg: "cidr", wantErr: true},
		{pg: "oid", wantErr: true},
		{pg: "numeric", wantErr: true},
		{pg: "time with time zone", wantErr: true},
		{pg: "tsvector", wantErr: true},
		{pg: "xml", wantErr: true},
		{pg: "ltree", wantErr: true},
		{pg: "some_custom_type", wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.pg, func(t *testing.T) {
			storage, viewCastType, err := pgFormatTypeToDuckDB(tt.pg)
			if tt.wantErr {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.wantStorage, storage)
			assert.Equal(t, tt.wantViewCastTyp, viewCastType)
		})
	}
}

func TestParsePartitionKeyDef(t *testing.T) {
	tests := []struct {
		name string
		def  string
		want []string
		err  bool
	}{
		{"single column", "RANGE (ts)", []string{"ts"}, false},
		{"single column with whitespace", "RANGE ( ts )", []string{"ts"}, false},
		{"composite 2 columns", "RANGE (tenant_id, ts)", []string{"tenant_id", "ts"}, false},
		{"composite 3 columns", "RANGE (a, b, c)", []string{"a", "b", "c"}, false},
		{"uppercase strategy", "LIST (branch_id)", []string{"branch_id"}, false},
		{"quoted identifier preserved", `RANGE ("Ts")`, []string{`"Ts"`}, false},
		{"missing open paren", "RANGE ts)", nil, true},
		{"missing close paren", "RANGE (ts", nil, true},
		{"empty parens", "RANGE ()", nil, true},
		{"empty component", "RANGE (a,,b)", nil, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parsePartitionKeyDef(tt.def)
			if tt.err {
				require.Error(t, err)
				return
			}
			require.NoError(t, err)
			assert.Equal(t, tt.want, got)
		})
	}
}

func TestDetectPartitionColumns_Single(t *testing.T) {
	calls := 0
	db := &mockQuerier{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				calls++
				if calls == 1 {
					// resolveTableName: not yet swapped.
					*(dest[0].(*bool)) = false
					return nil
				}
				*(dest[0].(*string)) = "RANGE (ts)"
				return nil
			}}
		},
	}
	cols, err := detectPartitionColumns(context.Background(), db, "public", "events")
	require.NoError(t, err)
	assert.Equal(t, []string{"ts"}, cols)
}

func TestDetectPartitionColumns_NotPartitioned(t *testing.T) {
	calls := 0
	db := &mockQuerier{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				calls++
				if calls == 1 {
					*(dest[0].(*bool)) = false
					return nil
				}
				return pgx.ErrNoRows
			}}
		},
	}
	_, err := detectPartitionColumns(context.Background(), db, "public", "events")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not partitioned or does not exist")
}

func TestDetectPartitionColumns_RejectsCompositeKey(t *testing.T) {
	calls := 0
	db := &mockQuerier{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				calls++
				if calls == 1 {
					*(dest[0].(*bool)) = false
					return nil
				}
				*(dest[0].(*string)) = "RANGE (tenant_id, ts)"
				return nil
			}}
		},
	}
	_, err := detectPartitionColumns(context.Background(), db, "public", "events")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "multi-column partition keys are not supported")
}

func TestValidateFlatPartitioning_OK(t *testing.T) {
	calls := 0
	db := &mockQuerier{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				calls++
				if calls == 1 {
					*(dest[0].(*bool)) = false
					return nil
				}
				return pgx.ErrNoRows
			}}
		},
	}
	require.NoError(t, validateFlatPartitioning(context.Background(), db, "public", "events"))
}

func TestValidateFlatPartitioning_RejectsSubPartitioned(t *testing.T) {
	calls := 0
	db := &mockQuerier{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				calls++
				if calls == 1 {
					*(dest[0].(*bool)) = false
					return nil
				}
				*(dest[0].(*string)) = "by_tenant"
				return nil
			}}
		},
	}
	err := validateFlatPartitioning(context.Background(), db, "public", "events")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "multi-level (sub-partitioned) partitioning is not supported")
}

func TestGetColumns_PopulatesIdentityAndPK(t *testing.T) {
	queryCalls := 0
	db := &mockQuerier{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			// resolveTableName lookup.
			return &mockRow{scanFunc: func(dest ...any) error {
				*(dest[0].(*bool)) = false
				return nil
			}}
		},
		rowsFunc: func(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
			queryCalls++
			if queryCalls == 1 {
				// Column metadata.
				return &mockRows{rows: []func(dest ...any) error{
					func(dest ...any) error {
						*(dest[0].(*string)) = "id"
						*(dest[1].(*string)) = "bigint" // format_type output
						*(dest[2].(*string)) = "a"
						return nil
					},
					func(dest ...any) error {
						*(dest[0].(*string)) = "ts"
						*(dest[1].(*string)) = "timestamp with time zone"
						*(dest[2].(*string)) = ""
						return nil
					},
					func(dest ...any) error {
						*(dest[0].(*string)) = "data"
						*(dest[1].(*string)) = "jsonb"
						*(dest[2].(*string)) = ""
						return nil
					},
				}}, nil
			}
			// Primary key column names.
			return &mockRows{rows: []func(dest ...any) error{
				func(dest ...any) error { *(dest[0].(*string)) = "id"; return nil },
			}}, nil
		},
	}
	cols, err := getColumns(context.Background(), db, "public", "events")
	require.NoError(t, err)
	require.Len(t, cols, 3)
	assert.Equal(t, "id", cols[0].Name)
	assert.Equal(t, "BIGINT", cols[0].Type)
	assert.True(t, cols[0].IsIdentity)
	assert.True(t, cols[0].IsPK)
	assert.Equal(t, "ts", cols[1].Name)
	assert.Equal(t, "TIMESTAMPTZ", cols[1].Type)
	assert.False(t, cols[1].IsIdentity)
	assert.False(t, cols[1].IsPK)
	assert.Equal(t, "data", cols[2].Name)
	assert.Equal(t, "VARCHAR", cols[2].Type)
	assert.Equal(t, "json", cols[2].ViewCastType)
}

func TestGetColumns_PropagatesQueryError(t *testing.T) {
	db := &mockQuerier{
		rowFunc: func(_ context.Context, _ string, _ ...any) pgx.Row {
			return &mockRow{scanFunc: func(dest ...any) error {
				*(dest[0].(*bool)) = false
				return nil
			}}
		},
		rowsFunc: func(_ context.Context, _ string, _ ...any) (pgx.Rows, error) {
			return nil, errors.New("relation missing")
		},
	}
	_, err := getColumns(context.Background(), db, "public", "events")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "relation missing")
}

// Only VARCHAR-backed rich types (Type=="VARCHAR" + a ViewCastType) are
// ::text-cast for the export stage. bytea (BLOB) and double precision (DOUBLE)
// carry a ViewCastType only for the view's hot-side cast; Iceberg stores them
// natively, so they must export AS-IS — ::text-casting bytea would corrupt the
// binary column.
func TestStageSelectList(t *testing.T) {
	cols := []view.Column{
		{Name: "i", Type: "INTEGER"},
		{Name: "j", Type: "VARCHAR", ViewCastType: "json"},
		{Name: "iv", Type: "VARCHAR", ViewCastType: "interval"},
		{Name: "b", Type: "BLOB", ViewCastType: "bytea"},
		{Name: "d", Type: "DOUBLE", ViewCastType: "double precision"},
	}
	got := stageSelectList(cols)
	assert.Equal(t, `"i", "j"::text AS "j", "iv"::text AS "iv", "b", "d"`, got)
}

func TestStageSelectList_Empty(t *testing.T) {
	assert.Equal(t, "*", stageSelectList(nil))
}

// The PG text-stage detour is only needed for types pg_duckdb's reader cannot
// scan natively — now just interval (kept defensively). bytea, jsonb and
// double scan fine and must not trigger it.
func TestNeedsPGTextStage(t *testing.T) {
	assert.True(t, needsPGTextStage([]view.Column{{Name: "iv", Type: "VARCHAR", ViewCastType: "interval"}}))
	assert.False(t, needsPGTextStage([]view.Column{
		{Name: "j", Type: "VARCHAR", ViewCastType: "json"},
		{Name: "b", Type: "BLOB", ViewCastType: "bytea"},
		{Name: "d", Type: "DOUBLE", ViewCastType: "double precision"},
	}))
	assert.False(t, needsPGTextStage(nil))
}

// TestDollarQuote proves the dollar-quote wrapper cannot be broken out of by any
// payload content: the chosen tag is always verified absent from the inner SQL,
// so a payload carrying a static-style tag ("$q$") or even a "$cf…$" lookalike
// can never terminate the quote early. This is the fix for the config-gated
// breakout where an Iceberg identifier or values_source value containing the
// static "$q$" tag would close the quote and inject trailing SQL.
func TestDollarQuote(t *testing.T) {
	cases := []string{
		"",
		`INSERT INTO "ice"."ns"."events" SELECT * FROM pg_temp.duck_stage`,
		`DELETE FROM x WHERE c < '2026-01-01'::timestamptz`,
		`evil$q$); DROP TABLE bar; --`,            // classic static-tag breakout attempt
		`a $cf$ b $cfdeadbeef$ c`,                 // payload mimicking our tag prefix
		strings.Repeat("$cf0000000000000000$", 4), // payload full of cf-style tags
	}
	for _, s := range cases {
		q, err := dollarQuote(s)
		require.NoError(t, err)
		require.GreaterOrEqual(t, len(q), 2)
		tag := q[:strings.IndexByte(q[1:], '$')+2] // opening tag: start .. second '$'
		assert.Equal(t, tag+s+tag, q, "must be tag+payload+tag")
		assert.False(t, strings.Contains(s, tag), "tag must be absent from the payload (unbreakable)")
		assert.True(t, strings.HasPrefix(tag, "$cf") && strings.HasSuffix(tag, "$"), "tag shape $cf…$")
	}
}

// TestIsRetryableCutover verifies that only the transient lock-timeout (55P03)
// is retried and every other error (permanent, or non-Postgres) fails fast.
func TestIsRetryableCutover(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"lock_not_available (55P03) is transient", &pgconn.PgError{Code: "55P03"}, true},
		{"fk violation (23503) is permanent", &pgconn.PgError{Code: "23503"}, false},
		{"deadlock (40P01) not retried — design yields via 55P03 first", &pgconn.PgError{Code: "40P01"}, false},
		{"raise_exception (P0001) is permanent", &pgconn.PgError{Code: "P0001"}, false},
		{"non-Postgres error fails fast", errors.New("boom"), false},
		{"nil fails fast", nil, false},
	}
	for _, c := range cases {
		assert.Equal(t, c.want, isRetryableCutover(c.err), c.name)
	}
}

// TestCutoverFailHint verifies the 23503 hint names the blocking constraint and
// that no hint is emitted for the transient timeout or non-Postgres errors.
func TestCutoverFailHint(t *testing.T) {
	fk := &pgconn.PgError{Code: "23503", ConstraintName: "event_logs_event_id_event_ts_fkey_1"}
	h := cutoverFailHint(fk)
	assert.Contains(t, h, "event_logs_event_id_event_ts_fkey_1", "names the blocking constraint")
	assert.Contains(t, h, "must be dropped", "gives actionable guidance")
	assert.Empty(t, cutoverFailHint(&pgconn.PgError{Code: "55P03"}), "no hint for the transient lock timeout")
	assert.Empty(t, cutoverFailHint(errors.New("boom")), "no hint for non-Postgres errors")
}

// Two tables sharing a name in different PG schemas map to distinct Iceberg
// tables, since the PG schema is the Iceberg namespace (ice.<schema>.<table>).
func TestIcebergRef_SchemaScoped(t *testing.T) {
	a := icebergRef("myapp", "events")
	b := icebergRef("analytics", "events")
	assert.NotEqual(t, a, b, "distinct schemas yield distinct iceberg refs")
	assert.Contains(t, a, "myapp")
	assert.Contains(t, a, "events")
	assert.Contains(t, b, "analytics")
}
