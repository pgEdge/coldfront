package config

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const validConfig = `
postgres:
  dsn: "host=localhost dbname=mydb user=myuser"

iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lakekeeper:8181/catalog"

s3:
  endpoint: "seaweedfs:8333"
  access_key: "admin"
  secret_key: "secret"

archiver:
  tables:
    - source_table: "events"
      partition_period: "monthly"
      hot_period: "3 months"
`

func writeConfig(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(path, []byte(content), 0644))
	return path
}

func TestLoad_ValidConfig(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	require.NoError(t, err)
	assert.Equal(t, "host=localhost dbname=mydb user=myuser", cfg.Postgres.DSN)
	assert.Equal(t, "wh", cfg.Iceberg.Warehouse)
	assert.Equal(t, "http://lakekeeper:8181/catalog", cfg.Iceberg.LakekeeperEndpoint)
	assert.Equal(t, "seaweedfs:8333", cfg.S3.Endpoint)
	assert.Equal(t, "admin", cfg.S3.AccessKey)
	require.Len(t, cfg.Archiver.Tables, 1)
	assert.Equal(t, "events", cfg.Archiver.Tables[0].SourceTable)
}

func TestLoad_Defaults(t *testing.T) {
	cfg, err := Load(writeConfig(t, validConfig))
	require.NoError(t, err)
	assert.Equal(t, "default", cfg.Iceberg.Namespace)
	assert.Equal(t, "us-east-1", cfg.S3.Region)
	assert.Equal(t, "public", cfg.Archiver.Tables[0].SourceSchema)
	assert.Equal(t, 3, cfg.Archiver.Tables[0].FuturePartitions)
}

func TestLoad_MultipleTables(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost"
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lk:8181/catalog"
s3:
  endpoint: "sw:8333"
  access_key: "a"
  secret_key: "s"
archiver:
  tables:
    - source_table: "events"
      partition_period: "monthly"
      hot_period: "3 months"
    - source_table: "analytics.logs"
      partition_period: "daily"
      hot_period: "7 days"
`
	c, err := Load(writeConfig(t, cfg))
	require.NoError(t, err)
	require.Len(t, c.Archiver.Tables, 2)
	assert.Equal(t, "events", c.Archiver.Tables[0].SourceTable)
	assert.Equal(t, "public", c.Archiver.Tables[0].SourceSchema)
	assert.Equal(t, "logs", c.Archiver.Tables[1].SourceTable)
	assert.Equal(t, "analytics", c.Archiver.Tables[1].SourceSchema)
}

func TestLoad_FileNotFound(t *testing.T) {
	_, err := Load("/nonexistent/path/config.yaml")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "read config")
}

func TestLoad_InvalidYAML(t *testing.T) {
	_, err := Load(writeConfig(t, "{{invalid yaml"))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "parse config")
}

func TestValidate_MissingDSN(t *testing.T) {
	cfg := `
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lk:8181/catalog"
s3:
  endpoint: "sw:8333"
  access_key: "a"
  secret_key: "s"
archiver:
  tables:
    - source_table: "t"
      partition_period: "monthly"
      retention_period: "1 month"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "postgres.dsn")
}

func TestValidate_MissingS3Endpoint(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost"
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lk:8181/catalog"
s3:
  access_key: "a"
  secret_key: "s"
archiver:
  tables:
    - source_table: "t"
      partition_period: "monthly"
      retention_period: "1 month"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "s3.endpoint")
}

func TestValidate_MissingWarehouse(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost"
iceberg:
  lakekeeper_endpoint: "http://lk:8181/catalog"
s3:
  endpoint: "sw:8333"
  access_key: "a"
  secret_key: "s"
archiver:
  tables:
    - source_table: "t"
      partition_period: "monthly"
      retention_period: "1 month"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "iceberg.warehouse")
}

func TestValidate_InvalidPartitionPeriod(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost"
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lk:8181/catalog"
s3:
  endpoint: "sw:8333"
  access_key: "a"
  secret_key: "s"
archiver:
  tables:
    - source_table: "t"
      partition_period: "weekly"
      retention_period: "1 month"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "partition_period")
}

func TestValidate_NoTables(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost"
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lk:8181/catalog"
s3:
  endpoint: "sw:8333"
  access_key: "a"
  secret_key: "s"
archiver:
  tables: []
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "at least one")
}

func tieredCfg(tail string) string {
	return `
postgres:
  dsn: "host=localhost"
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lk:8181/catalog"
s3:
  endpoint: "sw:8333"
  access_key: "a"
  secret_key: "s"
archiver:
  tables:
    - source_table: "t"
      partition_period: "monthly"
` + tail
}

func TestValidate_TieredRequiresHotPeriod(t *testing.T) {
	// Tiered mode: hot_period (tier-to-cold age) is mandatory; retention is not.
	_, err := Load(writeConfig(t, tieredCfg("")))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "hot_period")
}

func TestValidate_TieredRetentionOptional(t *testing.T) {
	// hot_period alone is valid — cold data is kept forever (no cold expiry).
	c, err := Load(writeConfig(t, tieredCfg(`      hot_period: "1 month"`)))
	require.NoError(t, err)
	assert.Equal(t, "1 month", c.Archiver.Tables[0].HotPeriod)
	assert.Empty(t, c.Archiver.Tables[0].RetentionPeriod)
}

func TestValidate_TieredColdRetentionOK(t *testing.T) {
	c, err := Load(writeConfig(t, tieredCfg("      hot_period: \"1 month\"\n      retention_period: \"12 months\"")))
	require.NoError(t, err)
	assert.Equal(t, "1 month", c.Archiver.Tables[0].HotPeriod)
	assert.Equal(t, "12 months", c.Archiver.Tables[0].RetentionPeriod)
}

func TestValidate_TieredRetentionMustExceedHot(t *testing.T) {
	// retention_period <= hot_period would destroy data before it ever tiers.
	_, err := Load(writeConfig(t, tieredCfg("      hot_period: \"3 months\"\n      retention_period: \"1 month\"")))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "must exceed hot_period")
}

func TestValidate_TieredRejectsIdMode(t *testing.T) {
	// id mode is a partition-only feature; the cold tier is time-only.
	_, err := Load(writeConfig(t, tieredCfg("      hot_period: \"1 month\"\n      part_mode: id\n      id_scheme: snowflake")))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "part_mode")
}

func TestValidate_PartitionOnlyRejectsHotPeriod(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: "events"
      partition_period: "monthly"
      retention_period: "12 months"
      hot_period: "1 month"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "hot_period")
}

func TestValidate_PartitionOnly_NoIcebergOK(t *testing.T) {
	// No iceberg/s3 sections at all: a partition-only run (premake + retention,
	// no cold-tier archival). Must load and validate cleanly.
	cfg := `
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: "events"
      partition_period: "monthly"
      retention_period: "12 months"
`
	c, err := Load(writeConfig(t, cfg))
	require.NoError(t, err)
	assert.Empty(t, c.Iceberg.Warehouse)
	require.Len(t, c.Archiver.Tables, 1)
	assert.Equal(t, "events", c.Archiver.Tables[0].SourceTable)
}

func TestValidate_IdModeSnowflakeOK(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: "events"
      partition_column: "id"
      partition_period: "monthly"
      retention_period: "12 months"
      part_mode: "id"
      id_scheme: "snowflake"
`
	c, err := Load(writeConfig(t, cfg))
	require.NoError(t, err)
	assert.Equal(t, "id", c.Archiver.Tables[0].PartMode)
	assert.Equal(t, "snowflake", c.Archiver.Tables[0].IDScheme)
}

func TestValidate_IdModeBadScheme(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: "events"
      partition_period: "monthly"
      retention_period: "12 months"
      part_mode: "id"
      id_scheme: "bogus"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "id_scheme")
}

func TestValidate_BadPartMode(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: "events"
      partition_period: "monthly"
      retention_period: "12 months"
      part_mode: "bogus"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "part_mode")
}

func TestValidate_SubPartitionOK(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: "events"
      partition_column: "ts"
      partition_period: "monthly"
      retention_period: "12 months"
      sub_partition:
        values_source: "SELECT code FROM regions"
`
	c, err := Load(writeConfig(t, cfg))
	require.NoError(t, err)
	require.NotNil(t, c.Archiver.Tables[0].SubPartition)
	assert.Equal(t, "SELECT code FROM regions", c.Archiver.Tables[0].SubPartition.ValuesSource)
}

func TestValidate_SubPartitionRequiresValuesSource(t *testing.T) {
	cfg := `
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: "events"
      partition_column: "ts"
      partition_period: "monthly"
      retention_period: "12 months"
      sub_partition: {}
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "values_source")
}

func TestValidate_PartialIcebergIsLoud(t *testing.T) {
	// A warehouse but no endpoint/s3: a half-configured cold setup, which must
	// fail loudly rather than be silently treated as partition-only.
	cfg := `
postgres:
  dsn: "host=localhost"
iceberg:
  warehouse: "wh"
archiver:
  tables:
    - source_table: "t"
      partition_period: "monthly"
      retention_period: "1 month"
`
	_, err := Load(writeConfig(t, cfg))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "lakekeeper_endpoint")
}
