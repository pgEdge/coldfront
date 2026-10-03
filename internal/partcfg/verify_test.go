package partcfg

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"github.com/pgedge/coldfront/internal/config"
)

func verifyCfg() *config.Config {
	cfg := &config.Config{}
	cfg.Iceberg.Warehouse = "wh"
	cfg.Iceberg.LakekeeperEndpoint = "http://lakekeeper:8181/catalog"
	cfg.S3.AccessKey, cfg.S3.SecretKey = "admin", "adminsecret"
	cfg.S3.Endpoint, cfg.S3.Region = "seaweedfs:8333", "us-east-1"
	cfg.Archiver.Tables = []config.TableConfig{{
		SourceSchema: "public", SourceTable: "events", PartitionPeriod: "monthly", HotPeriod: "30 days",
	}}
	return cfg
}

func boolRows(v bool) func() (pgx.Rows, error) {
	return func() (pgx.Rows, error) {
		return &mockRows{rows: []func(dest ...any) error{
			func(dest ...any) error { *(dest[0].(*bool)) = v; return nil },
		}}, nil
	}
}

// Every YAML value with a stored counterpart gets one query that says whether
// they agree: each table against its partition_config row, the cold-store
// stanza against the storage_secret row, each iceberg key against its setting.
func TestVerifyChecks_OnePerStoredValue(t *testing.T) {
	checks := verifyChecks(verifyCfg())
	require.Len(t, checks, 4)
	assert.Equal(t, "archiver.tables[0] (public.events)", checks[0].what)
	assert.Contains(t, checks[0].sql, "coldfront.partition_config")
	assert.Contains(t, checks[0].sql, "hot_period IS NOT DISTINCT FROM '30 days'::interval")
	assert.Equal(t, "s3", checks[1].what)
	assert.Contains(t, checks[1].sql, "coldfront.storage_secret")
	assert.Equal(t, []any{"admin", "adminsecret", "seaweedfs:8333", "us-east-1", "path", false}, checks[1].args)
	assert.Equal(t, "iceberg.warehouse", checks[2].what)
	assert.Equal(t, []any{"wh"}, checks[2].args)
	assert.Equal(t, "iceberg.lakekeeper_endpoint", checks[3].what)
	assert.Equal(t, []any{"http://lakekeeper:8181/catalog"}, checks[3].args)
}

func TestVerifyChecks_AzureAndNothing(t *testing.T) {
	cfg := &config.Config{}
	cfg.Azure.ConnectionString = "AccountName=acct;AccountKey=Zm9v"
	checks := verifyChecks(cfg)
	require.Len(t, checks, 1)
	assert.Equal(t, "azure", checks[0].what)
	assert.Equal(t, []any{"AccountName=acct;AccountKey=Zm9v"}, checks[0].args)
	assert.Empty(t, verifyChecks(&config.Config{}))
}

// A value that differs from what the server holds is refused, and the error
// says where configuration lives.
func TestVerify_RefusesDrift(t *testing.T) {
	err := Verify(context.Background(), &mockDB{rowsFunc: boolRows(false)}, verifyCfg())
	require.Error(t, err)
	assert.Contains(t, err.Error(), "archiver.tables[0] (public.events)")
	assert.Contains(t, err.Error(), "coldfront.partition_config")
	assert.Contains(t, err.Error(), "docs/usage.md")
}

func TestVerify_AgreementPasses(t *testing.T) {
	require.NoError(t, Verify(context.Background(), &mockDB{rowsFunc: boolRows(true)}, verifyCfg()))
}

// import writes the file's cold-store stanza through the extension's setters,
// one bound argument per value, and writes nothing when the file has no stanza.
func TestImportSecret_S3(t *testing.T) {
	db := &mockDB{}
	cfg := verifyCfg()
	require.NoError(t, importSecret(context.Background(), db, cfg))
	require.Len(t, db.execSQL, 1)
	assert.Contains(t, db.execSQL[0], "coldfront.set_storage_secret($1, $2, NULLIF($3, ''), $4, $5, $6)")
	assert.Equal(t, []any{"admin", "adminsecret", "seaweedfs:8333", "us-east-1", "path", false}, db.execArgs[0])
}

func TestImportSecret_Azure(t *testing.T) {
	db := &mockDB{}
	cfg := &config.Config{}
	cfg.Azure.ConnectionString = "AccountName=acct;AccountKey=Zm9v"
	require.NoError(t, importSecret(context.Background(), db, cfg))
	require.Len(t, db.execSQL, 1)
	assert.Contains(t, db.execSQL[0], "coldfront.set_storage_secret_azure($1)")
	assert.Equal(t, []any{"AccountName=acct;AccountKey=Zm9v"}, db.execArgs[0])
}

func TestImportSecret_NoStanza(t *testing.T) {
	db := &mockDB{}
	require.NoError(t, importSecret(context.Background(), db, &config.Config{}))
	assert.Empty(t, db.execSQL)
}

func TestCatalogChecks_OnlyTheSettings(t *testing.T) {
	checks := catalogChecks(verifyCfg())
	require.Len(t, checks, 2)
	assert.Equal(t, "iceberg.warehouse", checks[0].what)
	assert.Equal(t, "iceberg.lakekeeper_endpoint", checks[1].what)
	assert.Contains(t, checks[0].sql, "coldfront.warehouse', true), '') = $1")
	assert.Contains(t, checks[1].sql, "coldfront.lakekeeper_endpoint', true), '') = $1")
	assert.Empty(t, catalogChecks(&config.Config{}))
}
