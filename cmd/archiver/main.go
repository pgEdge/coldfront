package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/vyruss/coldfront/internal/config"
	"github.com/vyruss/coldfront/internal/partition"
	"github.com/vyruss/coldfront/internal/sqlutil"
	"github.com/vyruss/coldfront/internal/view"
	"github.com/vyruss/coldfront/internal/watermark"
)

// querier is the subset of *pgxpool.Pool that the pg-catalog helpers below use.
// Defined for testability — *pgxpool.Pool satisfies it directly.
type querier interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// main loads the config, connects to PostgreSQL, and runs one archive cycle
// per configured table. Intended to be invoked from cron; exits non-zero on
// any failure so the caller can alert.
func main() {
	configPath := flag.String("config", "config.yaml", "path to config file")
	debugExportDelay := flag.Duration("debug-export-delay", 0,
		"sleep this long after Phase 2 (capture+bulk-export) and before Phase 3 "+
			"(replay+cutover). Test-only knob to widen the window so concurrent "+
			"writes deterministically race into the capture trigger.")
	flag.Parse()

	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	pool, err := pgxpool.New(ctx, cfg.Postgres.DSN)
	if err != nil {
		log.Fatalf("connect pg: %v", err)
	}
	defer pool.Close()

	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("ping pg: %v", err)
	}

	wmStore := watermark.NewStore(pool)
	if err := wmStore.EnsureTable(ctx); err != nil {
		log.Fatalf("ensure watermark table: %v", err)
	}

	for i := range cfg.Archiver.Tables {
		t := &cfg.Archiver.Tables[i]

		// Reject sub-partitioned tables up front with a clear message.
		if err := validateFlatPartitioning(ctx, pool, t.SourceSchema, t.SourceTable); err != nil {
			log.Fatalf("[%s] %v", t.SourceTable, err)
		}

		// Auto-detect partition column if not configured.
		if t.PartitionColumn == "" {
			cols, err := detectPartitionColumns(ctx, pool, t.SourceSchema, t.SourceTable)
			if err != nil {
				log.Fatalf("auto-detect partition column for %s: %v", t.SourceTable, err)
			}
			if len(cols) == 0 {
				log.Fatalf("[%s] no partition column detected", t.SourceTable)
			}
			t.PartitionColumn = cols[0]
			log.Printf("[%s] auto-detected partition column: %s", t.SourceTable, cols[0])
		}

		log.Printf("[%s] starting archive cycle", t.SourceTable)
		if err := runCycle(ctx, cfg, t, pool, wmStore, *debugExportDelay); err != nil {
			log.Fatalf("[%s] archive cycle: %v", t.SourceTable, err)
		}
		log.Printf("[%s] archive cycle complete", t.SourceTable)
	}
}

// execDuckDB executes a DuckDB SQL statement via duckdb.raw_query().
func execDuckDB(ctx context.Context, pool *pgxpool.Pool, sql string) error {
	_, err := pool.Exec(ctx, fmt.Sprintf(`SELECT duckdb.raw_query($q$%s$q$)`, sql))
	return err
}

// attachIceberg sets up the per-connection DuckDB S3 secret and Lakekeeper catalog.
func attachIceberg(ctx context.Context, pool *pgxpool.Pool, cfg *config.Config) error {
	if err := execDuckDB(ctx, pool, fmt.Sprintf(
		"CREATE SECRET IF NOT EXISTS s3_secret (TYPE S3, KEY_ID %s, SECRET %s, ENDPOINT %s, URL_STYLE 'path', USE_SSL false, REGION %s)",
		sqlutil.Literal(cfg.S3.AccessKey), sqlutil.Literal(cfg.S3.SecretKey),
		sqlutil.Literal(cfg.S3.Endpoint), sqlutil.Literal(cfg.S3.Region))); err != nil {
		return fmt.Errorf("create s3 secret: %w", err)
	}

	if err := execDuckDB(ctx, pool, fmt.Sprintf(
		"ATTACH IF NOT EXISTS %s AS ice (TYPE ICEBERG, ENDPOINT %s, AUTHORIZATION_TYPE NONE, ACCESS_DELEGATION_MODE NONE)",
		sqlutil.Literal(cfg.Iceberg.Warehouse), sqlutil.Literal(cfg.Iceberg.LakekeeperEndpoint))); err != nil {
		return fmt.Errorf("attach iceberg catalog: %w", err)
	}

	return nil
}

// parsePartitionKeyDef parses the column list from a pg_get_partkeydef output
// like "RANGE (ts)" or "RANGE (tenant_id, ts)". Returns the trimmed column
// names in order.
func parsePartitionKeyDef(def string) ([]string, error) {
	start := strings.Index(def, "(")
	end := strings.LastIndex(def, ")")
	if start < 0 || end < 0 || end <= start+1 {
		return nil, fmt.Errorf("cannot parse partition key: %s", def)
	}
	raw := def[start+1 : end]
	parts := strings.Split(raw, ",")
	cols := make([]string, 0, len(parts))
	for _, p := range parts {
		col := strings.TrimSpace(p)
		if col == "" {
			return nil, fmt.Errorf("cannot parse partition key: %s", def)
		}
		cols = append(cols, col)
	}
	return cols, nil
}

// detectPartitionColumns returns the partition key columns from pg_catalog.
// Errors if the table is partitioned by more than one column — the archiver's
// single-watermark retention model only supports single-column time-based
// partition keys.
func detectPartitionColumns(ctx context.Context, db querier, schema, table string) ([]string, error) {
	name := resolveTableName(ctx, db, schema, table)
	var def string
	err := db.QueryRow(ctx, `
		SELECT pg_get_partkeydef(c.oid)
		FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'p'`,
		schema, name).Scan(&def)
	if err != nil {
		return nil, fmt.Errorf("table %s.%s is not partitioned or does not exist", schema, table)
	}
	cols, err := parsePartitionKeyDef(def)
	if err != nil {
		return nil, err
	}
	if len(cols) > 1 {
		return nil, fmt.Errorf(
			"multi-column partition keys are not supported on %s.%s (key: (%s)). "+
				"The archiver maintains a single global watermark per table to represent "+
				"the hot/cold boundary, which cannot express independent per-dimension "+
				"archival state. Use a table partitioned by a single time/date column",
			schema, table, strings.Join(cols, ", "))
	}
	return cols, nil
}

// validateFlatPartitioning errors if the source table has any sub-partitioned
// child (i.e. a child that is itself a partitioned table). The archiver's
// retention model assumes a flat, single-level partition scheme.
func validateFlatPartitioning(ctx context.Context, db querier, schema, table string) error {
	name := resolveTableName(ctx, db, schema, table)
	var child string
	err := db.QueryRow(ctx, `
		SELECT c.relname
		FROM pg_inherits i
		JOIN pg_class p ON p.oid = i.inhparent
		JOIN pg_namespace n ON n.oid = p.relnamespace
		JOIN pg_class c ON c.oid = i.inhrelid
		WHERE n.nspname = $1 AND p.relname = $2 AND c.relkind = 'p'
		LIMIT 1`, schema, name).Scan(&child)
	if err == pgx.ErrNoRows {
		return nil
	}
	if err != nil {
		return err
	}
	return fmt.Errorf(
		"multi-level (sub-partitioned) partitioning is not supported on %s.%s "+
			"(found sub-partitioned child %q). The archiver requires a single-level, "+
			"time-based partition scheme because a single global watermark cannot "+
			"track per-branch/per-tenant archival state independently.\n\n"+
			"If your time-based partitioning is at the sub-partition level (e.g. "+
			"%s is partitioned by branch_id/tenant, and each sub-partition is "+
			"partitioned by time), point the archiver at each time-partitioned "+
			"sub-partition as a separate entry in archiver.tables. "+
			"Note: tiering a sub-partition converts it to a view, so it can no "+
			"longer be accessed through the top-level parent — applications must "+
			"query the sub-partition directly",
		schema, table, child, table)
}

// resolveTableName returns the actual partitioned table name: _{source} if swap already
// happened, or {source} if this is the first run.
func resolveTableName(ctx context.Context, db querier, schema, source string) string {
	var exists bool
	err := db.QueryRow(ctx, `SELECT EXISTS (
		SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'p')`,
		schema, "_"+source).Scan(&exists)
	if err == nil && exists {
		return "_" + source
	}
	return source
}

// runCycle performs one archive pass for a single table: ensures future
// partitions, finds expired ones, archives each (capture trigger + bulk
// export + delta replay + atomic cutover), and drops archived PG partitions.
// Safe to re-run — every phase is idempotent.
func runCycle(ctx context.Context, cfg *config.Config, t *config.TableConfig, pool *pgxpool.Pool, wmStore *watermark.Store, debugExportDelay time.Duration) error {
	now := time.Now().UTC()
	partMgr := partition.NewManager(pool)
	viewGen := view.NewGenerator(pool)
	iceTable := pgx.Identifier{"ice", cfg.Iceberg.Namespace, t.SourceTable}.Sanitize()

	// Resolve actual table name (_{source} after swap, {source} on first run)
	tableName := resolveTableName(ctx, pool, t.SourceSchema, t.SourceTable)

	// 1. Create future partitions
	if err := partMgr.EnsureFuture(ctx, tableName, t.SourceSchema,
		t.PartitionColumn, t.PartitionPeriod,
		t.FuturePartitions, now); err != nil {
		return fmt.Errorf("ensure future partitions: %w", err)
	}

	// 2. Find expired partitions
	retention, err := parseInterval(t.RetentionPeriod)
	if err != nil {
		return fmt.Errorf("parse retention: %w", err)
	}
	expired, err := partMgr.FindExpired(ctx, tableName, t.SourceSchema, now.Add(-retention))
	if err != nil {
		return fmt.Errorf("find expired: %w", err)
	}
	if len(expired) == 0 {
		log.Printf("[%s] no expired partitions", t.SourceTable)
		return nil
	}
	log.Printf("[%s] found %d expired partition(s)", t.SourceTable, len(expired))

	// 3. Attach Lakekeeper Iceberg catalog
	if err := attachIceberg(ctx, pool, cfg); err != nil {
		return err
	}

	// 4. Ensure Iceberg namespace + table
	if err := ensureIcebergTable(ctx, pool, cfg, t, iceTable); err != nil {
		return fmt.Errorf("ensure iceberg table: %w", err)
	}

	// 5. Resolve columns once (used by every partition's cutover view DDL).
	columns, err := getColumns(ctx, pool, t.SourceSchema, t.SourceTable)
	if err != nil {
		return fmt.Errorf("get columns: %w", err)
	}
	hasPK := false
	for _, c := range columns {
		if c.IsPK {
			hasPK = true
			break
		}
	}
	if !hasPK {
		return fmt.Errorf(
			"%s.%s has no primary key — required for race-safe archive (delta capture "+
				"keys writes by source PK; without one we can't replay UPDATE/DELETE to Iceberg)",
			t.SourceSchema, t.SourceTable)
	}

	// 6. First-cycle bootstrap: rename events → _events and create the unified
	//    view with cutoff=zero (hot-only). Idempotent — the swap SQL no-ops if
	//    the rename already happened. Runs once per first archive cycle.
	wmCutoff, _, err := wmStore.Get(ctx, t.SourceTable)
	if err != nil {
		return fmt.Errorf("get watermark: %w", err)
	}
	bootstrapCfg := view.ViewConfig{
		SourceSchema:    t.SourceSchema,
		SourceTable:     t.SourceTable,
		IcebergTable:    iceTable,
		CutoffTime:      wmCutoff,
		PartitionColumn: t.PartitionColumn,
		Columns:         columns,
	}
	if err := viewGen.Recreate(ctx, bootstrapCfg); err != nil {
		return fmt.Errorf("bootstrap view: %w", err)
	}
	hotTable := pgx.Identifier{t.SourceSchema, "_" + t.SourceTable}.Sanitize()
	if err := registerTieredView(ctx, pool, t.SourceSchema, t.SourceTable,
		hotTable, iceTable, t.PartitionColumn); err != nil {
		return fmt.Errorf("register tiered view: %w", err)
	}
	tableName = resolveTableName(ctx, pool, t.SourceSchema, t.SourceTable)
	_ = tableName // tableName resolution kept for any future use; archivePartition uses pg_inherits to find parent

	// 7. Archive each expired partition via the 5-phase pipeline.
	for _, part := range expired {
		if err := ctx.Err(); err != nil {
			return err
		}

		wmCutoff, found, err := wmStore.Get(ctx, t.SourceTable)
		if err != nil {
			return fmt.Errorf("get watermark: %w", err)
		}
		if found && !part.UpperBound.After(wmCutoff) {
			// Idempotent cleanup branch: partition was archived in a prior cycle,
			// no race to worry about.
			log.Printf("partition %s already archived, cleaning up", part.Name)
			parent := resolveTableName(ctx, pool, t.SourceSchema, t.SourceTable)
			if err := partMgr.Detach(ctx, parent, t.SourceSchema, part.Name); err != nil {
				return fmt.Errorf("detach %s: %w", part.Name, err)
			}
			if err := partMgr.Drop(ctx, t.SourceSchema, part.Name); err != nil {
				return fmt.Errorf("drop %s: %w", part.Name, err)
			}
			continue
		}

		if err := archivePartition(ctx, pool, t, part, iceTable, columns, debugExportDelay); err != nil {
			return fmt.Errorf("archive %s: %w", part.Name, err)
		}
		log.Printf("archived %s", part.Name)
	}

	return nil
}

// archivePartition runs the archive pipeline for one expired partition.
//
//  0. Wipe any partial Iceberg state in the partition's range (idempotent prep).
//  1. Install capture trigger + UNLOGGED delta table on the partition.
//  2. Bulk export PG → Iceberg under a captured REPEATABLE READ snapshot S.
//  3. Drain delta rows whose xid is not visible in S (batched COMMIT, no main
//     lock — concurrent writers continue and add rows to the delta).
//  4. cutover_archive: watermark UPDATE, then LOCK ACCESS EXCLUSIVE on parent
//     + partition with lock_timeout=100ms, then view DDL + DETACH, then COMMIT.
//  5. cutover_cleanup: drain stragglers that landed in the gap between Phase
//     3's commit and Phase 4's lock (partition is detached now, capture
//     trigger is inert, finite catch-up), then drop partition + trigger + delta.
//
// On Phase 4 failure, retry Phase 3 + Phase 4 with exponential backoff up
// to 10 attempts (~102s total budget). Phase 3 is idempotent so retries are
// safe; Phase 4 either commits everything atomically or rolls back cleanly.
func archivePartition(ctx context.Context, pool *pgxpool.Pool, t *config.TableConfig,
	part partition.Info, iceTable string, columns []view.Column, debugExportDelay time.Duration,
) error {
	cycleStart := time.Now()
	log.Printf("[%s] archiving %s (%s to %s)", t.SourceTable, part.Name, part.LowerBound, part.UpperBound)

	// Phase 0
	t0 := time.Now()
	if err := wipeIcebergRange(ctx, pool, iceTable, t.PartitionColumn, part.LowerBound, part.UpperBound); err != nil {
		return fmt.Errorf("phase 0 (idempotent prep): %w", err)
	}
	log.Printf("[%s] %s phase 0 (idempotent iceberg-range wipe): %s",
		t.SourceTable, part.Name, time.Since(t0).Round(time.Millisecond))

	// Phase 1
	t0 = time.Now()
	if _, err := pool.Exec(ctx, "SELECT coldfront.install_archive_capture($1, $2)",
		t.SourceSchema, part.Name); err != nil {
		return fmt.Errorf("phase 1 (install capture): %w", err)
	}
	log.Printf("[%s] %s phase 1 (install capture trigger + delta table): %s",
		t.SourceTable, part.Name, time.Since(t0).Round(time.Millisecond))

	// Phase 2
	t0 = time.Now()
	snapshotStr, err := bulkExportWithSnapshot(ctx, pool, t, part.Name, iceTable, columns)
	if err != nil {
		return fmt.Errorf("phase 2 (bulk export): %w", err)
	}
	log.Printf("[%s] %s phase 2 (bulk export PG→Iceberg under snapshot): %s",
		t.SourceTable, part.Name, time.Since(t0).Round(time.Millisecond))

	if debugExportDelay > 0 {
		log.Printf("[debug-export-delay] holding capture window for %s before replay+cutover", debugExportDelay)
		select {
		case <-time.After(debugExportDelay):
		case <-ctx.Done():
			return ctx.Err()
		}
	}

	viewCfg := view.ViewConfig{
		SourceSchema:    t.SourceSchema,
		SourceTable:     t.SourceTable,
		IcebergTable:    iceTable,
		CutoffTime:      part.UpperBound,
		PartitionColumn: t.PartitionColumn,
		Columns:         columns,
	}
	viewDDL := view.GenerateViewSQL(viewCfg)

	// Phase 3 + 4 with retry harness. Each attempt's wall-clock is logged
	// so the per-phase totals are visible even when retries fire.
	backoff := 100 * time.Millisecond
	var lastErr error
	cutoverDone := false
	for attempt := 1; attempt <= 10; attempt++ {
		t3 := time.Now()
		if _, err := pool.Exec(ctx,
			"CALL coldfront.replay_archive_delta($1, $2, $3, $4)",
			t.SourceSchema, part.Name, snapshotStr, iceTable); err != nil {
			return fmt.Errorf("phase 3 attempt %d: %w", attempt, err)
		}
		log.Printf("[%s] %s phase 3 attempt %d (delta replay): %s",
			t.SourceTable, part.Name, attempt, time.Since(t3).Round(time.Millisecond))

		t4 := time.Now()
		if _, err := pool.Exec(ctx,
			"CALL coldfront.cutover_archive($1, $2, $3, $4, $5, $6)",
			t.SourceSchema, part.Name, t.SourceTable,
			part.UpperBound, viewDDL, 100); err == nil {
			log.Printf("[%s] %s phase 4 attempt %d (cutover: lock + watermark + view + DETACH): %s",
				t.SourceTable, part.Name, attempt, time.Since(t4).Round(time.Millisecond))
			cutoverDone = true
			break
		} else {
			lastErr = err
		}

		log.Printf("cutover %s attempt %d failed after %s: %v (retry in %s)",
			part.Name, attempt, time.Since(t4).Round(time.Millisecond), lastErr, backoff)
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return ctx.Err()
		}
		backoff *= 2 // 100, 200, 400, 800, 1.6s, 3.2s, 6.4s, 12.8s, 25.6s, 51.2s
	}
	if !cutoverDone {
		return fmt.Errorf("phase 4 (cutover) failed after 10 attempts; trigger+delta left for next cycle: %w", lastErr)
	}

	// Phase 5: post-cutover drain + drop. Single CALL: cutover_cleanup
	// internally drains stragglers from the lock-acquisition window and then
	// drops the detached partition, capture trigger, and delta table.
	t5 := time.Now()
	if _, err := pool.Exec(ctx,
		"CALL coldfront.cutover_cleanup($1, $2, $3, $4)",
		t.SourceSchema, part.Name, snapshotStr, iceTable); err != nil {
		return fmt.Errorf("phase 5 (cleanup): %w", err)
	}
	log.Printf("[%s] %s phase 5 (cleanup: drain stragglers + drop partition + trigger + delta): %s",
		t.SourceTable, part.Name, time.Since(t5).Round(time.Millisecond))

	log.Printf("[%s] %s ARCHIVE TOTAL: %s",
		t.SourceTable, part.Name, time.Since(cycleStart).Round(time.Millisecond))
	return nil
}

// wipeIcebergRange deletes any existing Iceberg rows whose partition column
// falls inside [lower, upper). Phase 0 of archive — handles the case where a
// previous archive cycle exported to Iceberg but crashed before cutover, so
// the partition remained attached and will be re-exported this cycle.
func wipeIcebergRange(ctx context.Context, pool *pgxpool.Pool, iceTable, partCol string, lower, upper time.Time) error {
	// Route through coldfront._exec_iceberg_with_claim so this cold-tier write
	// is serialized against concurrent committers (R-A bakery on a mesh, local
	// advisory lock single-node) — same no-409 guarantee as every other cold
	// write. The inner DELETE is dollar-quoted as the p_sql argument.
	inner := fmt.Sprintf(
		`DELETE FROM %s WHERE %s >= '%s'::timestamptz AND %s < '%s'::timestamptz`,
		iceTable,
		pgx.Identifier{partCol}.Sanitize(),
		lower.UTC().Format("2006-01-02 15:04:05+00"),
		pgx.Identifier{partCol}.Sanitize(),
		upper.UTC().Format("2006-01-02 15:04:05+00"))
	sql := fmt.Sprintf(`SELECT coldfront._exec_iceberg_with_claim(%s, $q$%s$q$)`,
		sqlutil.Literal(iceTable), inner)
	_, err := pool.Exec(ctx, sql)
	return err
}

// bulkExportWithSnapshot captures a PG snapshot, then runs the bulk PG→Iceberg
// copy as autocommit statements. Each statement is its own PG (and DuckDB)
// transaction — required because DuckDB rejects writes to two databases (the
// pg_temp duck_stage and ice.* iceberg) in a single transaction.
//
// All three statements (snapshot capture + CREATE TEMP TABLE + INSERT) run
// on the same dedicated conn so the temp table created by step 2 is visible
// to step 3. The temp table is connection-scoped, not tx-scoped, so it
// survives across autocommit txs on the same conn.
//
// Snapshot semantics: the captured snapshot S is taken BEFORE the bulk copy's
// implicit snapshot S2 ≥ S, so a write committed between S and S2 ends up
// BOTH in the bulk copy AND classified by Phase 3's filter as "not visible
// in S" → replayed. The replay is idempotent (DELETE+INSERT keyed on PK), so
// the duplicate work is correct, just wasted. For typical workloads this
// window is sub-millisecond.
// stageSelectList builds the SELECT projection for the bulk export, casting
// only the VARCHAR-backed rich types (jsonb/json/interval — Type=="VARCHAR"
// with a surface ViewCastType) to ::text so they land as VARCHAR in Iceberg
// and the transparent view casts them back on read.
//
// A ViewCastType alone does NOT mean text-backed: bytea (storage BLOB) and
// double precision (storage DOUBLE) carry a ViewCastType only to give the view
// a PG-parseable hot-side cast (`::bytea`/`::double precision` instead of the
// non-PG `::BLOB`/`::DOUBLE`). Iceberg stores those natively (binary / double),
// so they must be exported AS-IS — ::text-casting bytea would stringify the
// bytes ('\xdeadbeef') and corrupt the BLOB column. Gating on Type=="VARCHAR"
// selects exactly the text-backed types and leaves native ones untouched.
func stageSelectList(columns []view.Column) string {
	if len(columns) == 0 {
		return "*"
	}
	parts := make([]string, len(columns))
	for i, c := range columns {
		id := pgx.Identifier{c.Name}.Sanitize()
		if c.Type == "VARCHAR" && c.ViewCastType != "" {
			parts[i] = id + "::text AS " + id
		} else {
			parts[i] = id
		}
	}
	return strings.Join(parts, ", ")
}

// needsPGTextStage reports whether the column set contains a type pg_duckdb's
// PG reader cannot scan, requiring a PostgreSQL-side text-cast staging table
// before the DuckDB stage. jsonb (ViewCastType "json") scans fine, so it does
// NOT trigger the detour. interval is included defensively (Iceberg-VARCHAR-
// backed, and not worth a separate scan probe). inet/cidr were the original
// offenders but are no longer supported (pg_duckdb rejects inet outright).
func needsPGTextStage(columns []view.Column) bool {
	for _, c := range columns {
		if c.ViewCastType == "interval" {
			return true
		}
	}
	return false
}

func bulkExportWithSnapshot(ctx context.Context, pool *pgxpool.Pool, t *config.TableConfig, partName, iceTable string, columns []view.Column) (string, error) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return "", fmt.Errorf("acquire conn: %w", err)
	}
	defer conn.Release()

	var snapshotStr string
	if err := conn.QueryRow(ctx, "SELECT pg_current_snapshot()::text").Scan(&snapshotStr); err != nil {
		return "", fmt.Errorf("capture snapshot: %w", err)
	}

	// Stage the partition into a DuckDB-backed temp table for the Iceberg
	// write. A few VARCHAR-backed types pg_duckdb's reader prefers not to scan
	// directly (interval) get a PostgreSQL-side text-cast copy in a plain temp
	// table first; then pg_duckdb scans that text-only table. The value lands as
	// VARCHAR in Iceberg and the transparent view casts it back on read.
	// (inet/cidr were the original Oid-869 offenders that motivated this detour
	// but are no longer supported — see pgFormatTypeToDuckDB.) jsonb-only /
	// plain tables skip the detour (single copy, fast path).
	src := pgx.Identifier{t.SourceSchema, partName}.Sanitize()
	if needsPGTextStage(columns) {
		pgStageSQL := fmt.Sprintf(
			"CREATE TEMP TABLE cf_pgstage AS SELECT %s FROM %s",
			stageSelectList(columns), src)
		if _, err := conn.Exec(ctx, pgStageSQL); err != nil {
			return "", fmt.Errorf("pg text-stage: %w", err)
		}
		defer func() { _, _ = conn.Exec(ctx, "DROP TABLE IF EXISTS cf_pgstage") }()
		src = "cf_pgstage"
	}
	stageSQL := fmt.Sprintf(
		"CREATE TEMP TABLE duck_stage USING duckdb AS SELECT * FROM %s", src)
	if _, err := conn.Exec(ctx, stageSQL); err != nil {
		return "", fmt.Errorf("stage: %w", err)
	}
	defer func() { _, _ = conn.Exec(ctx, "DROP TABLE IF EXISTS duck_stage") }()

	// Route the bulk iceberg INSERT through the bakery wrapper (serialized:
	// R-A on a mesh, local advisory lock single-node). Runs as an autocommit
	// statement on this dedicated conn, so the claim/lock is released at this
	// statement's commit. duck_stage was created on the same conn in the prior
	// statement, so only one DuckDB-database write happens inside this tx.
	if _, err := conn.Exec(ctx,
		fmt.Sprintf("SELECT coldfront._exec_iceberg_with_claim(%s, $q$INSERT INTO %s SELECT * FROM pg_temp.duck_stage$q$)",
			sqlutil.Literal(iceTable), iceTable),
	); err != nil {
		return "", fmt.Errorf("iceberg insert: %w", err)
	}
	return snapshotStr, nil
}

// (Old exportPartition + retryOnConflict were replaced by archivePartition's
// 5-phase pipeline. Catalog-conflict retry is no longer needed because the
// bulk export is one autocommit DuckDB transaction; if Iceberg rejects it,
// the whole archive cycle errors out and cron retries.)

// ensureIcebergTable creates the Iceberg namespace and table (matching the
// PG source schema) if they don't already exist. Safe to call every run.
func ensureIcebergTable(ctx context.Context, pool *pgxpool.Pool, cfg *config.Config, t *config.TableConfig, iceTable string) error {
	if err := execDuckDB(ctx, pool, fmt.Sprintf("CREATE SCHEMA IF NOT EXISTS %s",
		pgx.Identifier{"ice", cfg.Iceberg.Namespace}.Sanitize())); err != nil {
		return fmt.Errorf("create namespace: %w", err)
	}

	columns, err := getColumns(ctx, pool, t.SourceSchema, t.SourceTable)
	if err != nil {
		return fmt.Errorf("get columns: %w", err)
	}
	var colDefs string
	for i, c := range columns {
		if i > 0 {
			colDefs += ", "
		}
		colDefs += fmt.Sprintf("%s %s", pgx.Identifier{c.Name}.Sanitize(), c.Type)
	}

	if err := execDuckDB(ctx, pool, fmt.Sprintf("CREATE TABLE IF NOT EXISTS %s (%s)", iceTable, colDefs)); err != nil {
		return fmt.Errorf("create iceberg table: %w", err)
	}
	return nil
}

// registerTieredView upserts a row in coldfront.tiered_views so the
// coldfront C extension can identify this view as a tiered target and
// rewrite UPDATE/DELETE into dual-tier CTEs. Called after every view recreate.
func registerTieredView(ctx context.Context, pool *pgxpool.Pool, schema, table, hotTable, icebergTable, partitionCol string) error {
	_, err := pool.Exec(ctx, `
		INSERT INTO coldfront.tiered_views (schema_name, relname, hot_table, iceberg_table, partition_col)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (schema_name, relname) DO UPDATE
		  SET hot_table     = EXCLUDED.hot_table,
		      iceberg_table = EXCLUDED.iceberg_table,
		      partition_col = EXCLUDED.partition_col`,
		schema, table, hotTable, icebergTable, partitionCol)
	return err
}

// pgFormatTypeToDuckDB maps PG's format_type(atttypid, atttypmod) output to:
//
//	storage      — the DuckDB type used for the Iceberg CREATE TABLE column
//	               declaration. pg_duckdb passes this through to
//	               duckdb-iceberg's LogicalTypeToIcebergType to derive the
//	               Iceberg primitive (e.g. DuckDB BIGINT → Iceberg long).
//	viewCastType — the DuckDB type the view should expose by casting both
//	               UNION branches. Empty for types whose storage form already
//	               matches the surface type (BIGINT, TIMESTAMPTZ, DECIMAL(P,S),
//	               …). Non-empty for types Iceberg cannot represent natively
//	               (jsonb/json → json, interval → interval): storage is VARCHAR,
//	               view casts to the rich type so applications see jsonb/interval,
//	               not text. (Also bytea → bytea, double precision → double
//	               precision: native storage BLOB/DOUBLE, cast only so the view's
//	               hot-side spelling is PG-parseable.)
//
// Hard-errors on types with no Iceberg-compatible storage (unbounded numeric,
// time-with-tz, custom enums, xml, tsvector, …) rather than silently falling
// back to VARCHAR — silent type loss is a footgun for users with e.g.
// numeric(20,5) financial columns who would discover the precision loss
// months later when querying the cold tier.
func pgFormatTypeToDuckDB(s string) (storage, viewCastType string, err error) {
	switch s {
	// Numeric / boolean — storage matches surface; no cast needed.
	case "bigint":
		return "BIGINT", "", nil
	case "integer":
		return "INTEGER", "", nil
	case "smallint":
		// Iceberg has no 16-bit integer; widen to INTEGER (lossless, same as
		// oid → BIGINT). duckdb-iceberg rejects SMALLINT at CREATE TABLE. No
		// view cast needed: INTEGER is itself a PG-parseable surface, and the
		// view casts BOTH branches to the storage type, so bootstrap (hot-only)
		// and post-cutover (hot+cold) views agree on the column type.
		return "INTEGER", "", nil
	case "real":
		return "REAL", "", nil
	case "double precision":
		// Iceberg/DuckDB storage is DOUBLE, but PG has no bare type named
		// "double" (it's a shell type), so the transparent view's cold cast
		// r['col']::DOUBLE fails to PARSE when CREATE VIEW validates the body.
		// Surface via the PG-spelled "double precision" cast (pg_duckdb maps it
		// back to DOUBLE); both branches then parse and unify.
		return "DOUBLE", "double precision", nil
	case "boolean":
		return "BOOLEAN", "", nil

	// Temporal — storage matches surface; no cast needed.
	case "timestamp with time zone":
		return "TIMESTAMPTZ", "", nil
	case "timestamp without time zone":
		return "TIMESTAMP", "", nil
	case "date":
		return "DATE", "", nil
	case "time without time zone":
		return "TIME", "", nil

	// Identifiers / strings / binary — storage matches surface.
	case "uuid":
		return "UUID", "", nil
	case "text":
		return "VARCHAR", "", nil
	case "bytea":
		// Iceberg/DuckDB storage is BLOB, which is not a PG-parseable cast
		// name; surface via the PG-spelled "bytea" on both branches.
		return "BLOB", "bytea", nil

	// PG `oid` is 4-byte unsigned (max 4_294_967_295). DuckDB INTEGER is
	// signed 32-bit, so values above 2_147_483_647 would overflow. Use
	// BIGINT for safe round-trip.
	case "oid":
		// oid widens to BIGINT (4-byte unsigned safe-widen). No view cast:
		// BIGINT is a PG-parseable surface and the view casts both branches to
		// the storage type, so bootstrap/cutover view types agree.
		return "BIGINT", "", nil

	// View-cast types use lowercase by convention — PG/DuckDB cast targets
	// (`::json`, `::interval`) read more naturally than UPPERCASE. Storage
	// types stay UPPERCASE because they're CREATE-TABLE column declarations
	// (BIGINT, VARCHAR, …) where uppercase is conventional.

	// Iceberg has no JSON primitive — storage VARCHAR, surface json.
	case "jsonb", "json":
		return "VARCHAR", "json", nil

	// Iceberg has no INTERVAL — storage VARCHAR, surface interval.
	// PG interval ↔ text is round-trip-clean (e.g. "1 day 02:00:00"), and
	// DuckDB INTERVAL parses the same text. pg_duckdb maps DuckDB INTERVAL
	// back to PG interval.
	case "interval":
		return "VARCHAR", "interval", nil

		// inet/cidr are NOT supported. pg_duckdb cannot represent PG inet (Oid
		// 869) anywhere in a query it plans, and every read through an
		// Iceberg-backed view is planned by pg_duckdb (the view embeds
		// iceberg_scan). It rejects the column *reference* at plan time, before
		// any cast — so "store as VARCHAR, cast back to inet" is impossible. Fall
		// through to the unsupported-type error; users store IP data as text.
	}

	// VARCHAR(N) / CHAR(N) — PG's format_type emits "character varying(N)"
	// or "character(N)". Iceberg/DuckDB don't enforce length anyway.
	if strings.HasPrefix(s, "character varying") || strings.HasPrefix(s, "character(") || s == "character" {
		return "VARCHAR", "", nil
	}

	// numeric(P,S) → DECIMAL(P,S). Iceberg supports decimal up to P=38.
	if m := numericTypeRe.FindStringSubmatch(s); m != nil {
		return "DECIMAL(" + m[1] + "," + m[2] + ")", "", nil
	}
	if s == "numeric" {
		return "", "", fmt.Errorf(
			"PG type %q is unbounded-precision; Iceberg requires DECIMAL(P,S) "+
				"with explicit precision and scale. ALTER COLUMN ... TYPE numeric(P,S) "+
				"to fix (P up to 38)", s)
	}

	return "", "", fmt.Errorf(
		"PG type %q has no Iceberg-compatible mapping. Supported: bigint, integer, "+
			"smallint, real, double precision, boolean, timestamp with/without time "+
			"zone, date, time without time zone, uuid, text, character varying(N), "+
			"character(N), bytea, numeric(P,S) with P<=38, json, jsonb, interval, "+
			"oid. inet/cidr are not supported (pg_duckdb cannot process inet in "+
			"Iceberg-backed queries); store IP data as text", s)
}

var numericTypeRe = regexp.MustCompile(`^numeric\((\d+),\s*(\d+)\)$`)

// getColumns introspects pg_catalog to return the column list for the
// source table. Each Column.Type is the **DuckDB type name**, derived from
// PG's format_type(atttypid, atttypmod) output via pgFormatTypeToDuckDB —
// so callers can use it directly for both Iceberg CREATE TABLE column
// declarations and view cold-side casts.
//
// Errors out at archiver startup on any column whose PG type has no
// Iceberg-compatible mapping (rather than silently falling back to VARCHAR
// and losing precision/format/identity at write time).
//
// ViewCastType is set for PG types Iceberg can't represent natively
// (jsonb/json → json, interval → interval; storage VARCHAR), and for native
// types whose storage name isn't PG-parseable (bytea → bytea, double precision
// → double precision; storage BLOB/DOUBLE). The view layer emits ::ViewCastType
// on both UNION branches so the application surface stays the right type.
//
// IsIdentity is attidentity = 'a' (GENERATED ALWAYS AS IDENTITY); IsPK is
// participation in pg_index.indisprimary. Composite PKs handled transparently.
func getColumns(ctx context.Context, db querier, schema, tableName string) ([]view.Column, error) {
	actualName := resolveTableName(ctx, db, schema, tableName)

	// format_type carries the typmod-decoded form (numeric(P,S), character
	// varying(N), timestamp with time zone, …). attidentity is PG internal
	// type "char"; cast to text for pgx compatibility.
	rows, err := db.Query(ctx, `
		SELECT a.attname,
		       format_type(a.atttypid, a.atttypmod),
		       a.attidentity::text
		FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2
		  AND a.attnum > 0 AND NOT a.attisdropped
		ORDER BY a.attnum`, schema, actualName)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var cols []view.Column
	for rows.Next() {
		var name, pgFormatType, attidentity string
		if err := rows.Scan(&name, &pgFormatType, &attidentity); err != nil {
			return nil, err
		}
		storage, viewCastType, err := pgFormatTypeToDuckDB(pgFormatType)
		if err != nil {
			return nil, fmt.Errorf("column %s.%s.%s: %w", schema, actualName, name, err)
		}
		cols = append(cols, view.Column{
			Name:         name,
			Type:         storage,
			ViewCastType: viewCastType,
			IsIdentity:   attidentity == "a",
		})
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Primary key column names — works for single-column and composite PKs.
	pkRows, err := db.Query(ctx, `
		SELECT a.attname
		FROM pg_index i
		JOIN pg_class c ON c.oid = i.indrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
		WHERE n.nspname = $1 AND c.relname = $2 AND i.indisprimary`, schema, actualName)
	if err != nil {
		return nil, err
	}
	defer pkRows.Close()

	pkSet := map[string]bool{}
	for pkRows.Next() {
		var name string
		if err := pkRows.Scan(&name); err != nil {
			return nil, err
		}
		pkSet[name] = true
	}
	if err := pkRows.Err(); err != nil {
		return nil, err
	}

	for i := range cols {
		if pkSet[cols[i].Name] {
			cols[i].IsPK = true
		}
	}
	return cols, nil
}

// parseInterval parses a "N unit" string like "3 months" or "7 days" into
// a time.Duration using approximate month/year lengths (30 / 365 days).
// Good enough for retention comparisons; exact PG interval arithmetic is
// not required.
func parseInterval(s string) (time.Duration, error) {
	var n int
	var unit string
	if _, err := fmt.Sscanf(s, "%d %s", &n, &unit); err != nil {
		return 0, fmt.Errorf("invalid interval %q: expected \"N unit\"", s)
	}
	switch unit {
	case "day", "days":
		return time.Duration(n) * 24 * time.Hour, nil
	case "week", "weeks":
		return time.Duration(n) * 7 * 24 * time.Hour, nil
	case "month", "months":
		return time.Duration(n) * 30 * 24 * time.Hour, nil
	case "year", "years":
		return time.Duration(n) * 365 * 24 * time.Hour, nil
	default:
		return 0, fmt.Errorf("unsupported interval unit %q", unit)
	}
}

// init configures the standard logger: UTC timestamps on stderr so cron
// output is unambiguous across timezones.
func init() {
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.SetOutput(os.Stderr)
}
