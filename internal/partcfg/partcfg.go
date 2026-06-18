// Package partcfg is the in-DB store for per-table partition lifecycle config —
// coldfront.partition_config, the unified source of truth that drives both the
// standalone partitioner and the tiered archiver. On a Spock mesh the table is
// replicated by value (name-keyed), so every node reads identical config; on
// vanilla stock PG the partitioner self-materializes it via EnsureTable. Rows
// map onto the existing config.TableConfig, so every downstream consumer
// (runCycle, specFromTable) is unchanged. Connection config (DSN, iceberg/S3
// creds) is deliberately NOT stored here — it is per-node and must never ride
// the replication stream.
package partcfg

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/pgedge/coldfront/internal/config"
)

// DBTX is the slice of *pgx.Conn partcfg needs.
type DBTX interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// createTableSQL mirrors the coldfront.partition_config DDL in the C extension
// (coldfront--1.0.sql) so the vanilla partitioner — stock PG, no extension —
// can self-materialize the same table. Keep the two in sync (same pattern as
// archive_watermark / watermark.EnsureTable).
const createTableSQL = `
CREATE TABLE IF NOT EXISTS coldfront.partition_config (
    schema_name            text    NOT NULL DEFAULT 'public',
    table_name             text    NOT NULL,
    partition_period       text    NOT NULL,
    partition_column       text,
    future_partitions      int     NOT NULL DEFAULT 3,
    part_mode              text    NOT NULL DEFAULT 'timestamp',
    id_scheme              text,
    hot_period             interval,
    retention_period       interval,
    sub_part_values_source text,
    expiration_strategy     text    NOT NULL DEFAULT 'drop',
    enabled                boolean NOT NULL DEFAULT true,
    PRIMARY KEY (schema_name, table_name),
    CONSTRAINT pc_period_enum   CHECK (partition_period IN ('monthly','daily')),
    CONSTRAINT pc_partmode_enum CHECK (part_mode IN ('timestamp','id')),
    CONSTRAINT pc_id_scheme     CHECK ((part_mode = 'id') = (id_scheme IS NOT NULL)),
    CONSTRAINT pc_scheme_enum   CHECK (id_scheme IS NULL OR id_scheme IN ('uuidv7','snowflake')),
    CONSTRAINT pc_future_pos    CHECK (future_partitions >= 1),
    CONSTRAINT pc_destroy       CHECK (hot_period IS NOT NULL OR retention_period IS NOT NULL),
    CONSTRAINT pc_cold_timeonly CHECK (hot_period IS NULL OR part_mode = 'timestamp'),
    CONSTRAINT pc_2level_col    CHECK (sub_part_values_source IS NULL OR partition_column IS NOT NULL),
    CONSTRAINT pc_strategy_enum CHECK (expiration_strategy IN ('drop','detach')),
    CONSTRAINT pc_strategy_part CHECK (expiration_strategy = 'drop' OR hot_period IS NULL)
)`

// addColumnsSQL idempotently brings an existing partition_config table (created
// by an older version, before expiration_strategy existed) up to date. CREATE
// TABLE IF NOT EXISTS skips an existing table, so a new column needs an explicit
// ADD COLUMN IF NOT EXISTS — otherwise LoadTables' SELECT would fail on upgrade.
const addColumnsSQL = `
ALTER TABLE coldfront.partition_config
    ADD COLUMN IF NOT EXISTS expiration_strategy text NOT NULL DEFAULT 'drop'`

// ensureReplicatedSQL adds partition_config to Spock's default replication set
// so the per-table config replicates by value across the mesh — the same
// spock-gated, idempotent pattern as coldfront._ensure_claims_replicated. It is
// a no-op without the spock extension (vanilla single node), and is safe under
// pg_duckdb (no EXCEPTION block ⇒ no subtransaction). The nested IFs ensure the
// spock.* relations are only referenced when spock is actually installed.
const ensureReplicatedSQL = `
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock') THEN
    IF NOT EXISTS (
      SELECT 1 FROM spock.replication_set rs
        JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
       WHERE rs.set_name = 'default'
         AND rst.set_reloid = 'coldfront.partition_config'::regclass
    ) THEN
      PERFORM spock.repset_add_table('default', 'coldfront.partition_config'::regclass, false);
    END IF;
  END IF;
END $$`

// EnsureTable idempotently creates the coldfront schema and partition_config
// table, and (on a Spock node) registers it for replication. Safe to call every
// run; a no-op once the extension (or a prior run) created it.
func EnsureTable(ctx context.Context, db DBTX) error {
	if _, err := db.Exec(ctx, `CREATE SCHEMA IF NOT EXISTS coldfront`); err != nil {
		return fmt.Errorf("create schema: %w", err)
	}
	if _, err := db.Exec(ctx, createTableSQL); err != nil {
		return fmt.Errorf("create partition_config: %w", err)
	}
	if _, err := db.Exec(ctx, addColumnsSQL); err != nil {
		return fmt.Errorf("upgrade partition_config columns: %w", err)
	}
	if _, err := db.Exec(ctx, ensureReplicatedSQL); err != nil {
		return fmt.Errorf("ensure partition_config replicated: %w", err)
	}
	return nil
}

// ResolveTables returns the managed-table set: it ensures the table exists,
// then returns the partition_config rows if there are any, else the supplied
// YAML fallback (the deprecation bridge for not-yet-migrated deployments). The
// bool is true when the YAML fallback was used. Callers fail loud if the result
// is empty (both sources empty).
func ResolveTables(ctx context.Context, db DBTX, yamlFallback []config.TableConfig) ([]config.TableConfig, bool, error) {
	if err := EnsureTable(ctx, db); err != nil {
		return nil, false, err
	}
	rows, err := LoadTables(ctx, db)
	if err != nil {
		return nil, false, err
	}
	if len(rows) > 0 {
		return rows, false, nil
	}
	return yamlFallback, true, nil
}

// LoadTables reads the enabled partition_config rows into the existing
// config.TableConfig shape, so every downstream consumer is unchanged.
func LoadTables(ctx context.Context, db DBTX) ([]config.TableConfig, error) {
	rows, err := db.Query(ctx, `
		SELECT schema_name, table_name, partition_period, partition_column,
		       future_partitions, part_mode, id_scheme, hot_period::text,
		       retention_period::text, sub_part_values_source, expiration_strategy
		FROM coldfront.partition_config
		WHERE enabled
		ORDER BY schema_name, table_name`)
	if err != nil {
		return nil, fmt.Errorf("query partition_config: %w", err)
	}
	defer rows.Close()

	var out []config.TableConfig
	for rows.Next() {
		t, err := scanTableConfig(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

// scanTableConfig maps one partition_config row onto config.TableConfig,
// dereferencing the nullable columns onto their zero-value or pointer fields.
func scanTableConfig(rows pgx.Rows) (config.TableConfig, error) {
	var t config.TableConfig
	var col, idScheme, hot, ret, subVals *string
	if err := rows.Scan(&t.SourceSchema, &t.SourceTable, &t.PartitionPeriod, &col,
		&t.FuturePartitions, &t.PartMode, &idScheme, &hot, &ret, &subVals, &t.ExpirationStrategy); err != nil {
		return t, fmt.Errorf("scan partition_config: %w", err)
	}
	if col != nil {
		t.PartitionColumn = *col
	}
	if idScheme != nil {
		t.IDScheme = *idScheme
	}
	if hot != nil {
		t.HotPeriod = *hot
	}
	if ret != nil {
		t.RetentionPeriod = *ret
	}
	if subVals != nil {
		t.SubPartition = &config.SubPartitionConfig{ValuesSource: *subVals}
	}
	return t, nil
}
