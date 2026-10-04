package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/pgedge/coldfront/internal/config"
	"github.com/pgedge/coldfront/internal/partcfg"
	"github.com/pgedge/coldfront/internal/partition"
	"github.com/pgedge/coldfront/internal/sqlutil"
	"github.com/pgedge/coldfront/internal/version"
	"github.com/pgedge/coldfront/internal/view"
	"github.com/pgedge/coldfront/internal/watermark"
)

// querier is the subset of *pgx.Conn that the pg-catalog helpers below use.
// Defined for testability — *pgx.Conn satisfies it directly.
type querier interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// main loads the config, connects to PostgreSQL, and runs one archive cycle
// per configured table. Intended to be invoked from cron; exits non-zero on
// any failure so the caller can alert.
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	if dispatchCLI(ctx) {
		return
	}

	configPath := flag.String("config", "", "deployment YAML, checked against the stored configuration; its postgres.dsn connects when --dsn is unset")
	dsn := flag.String("dsn", "", "PostgreSQL connection string (default: the libpq environment)")
	debugExportDelay := flag.Duration("debug-export-delay", 0,
		"sleep this long after Phase 2 (capture+bulk-export) and before Phase 3 "+
			"(replay+cutover). Test-only knob to widen the window so concurrent "+
			"writes deterministically race into the capture trigger.")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("%s %s (built %s)\n", filepath.Base(os.Args[0]), version.Version, version.BuildTime)
		return
	}

	cfg := &config.Config{}
	if *configPath != "" {
		c, err := config.Load(*configPath)
		if err != nil {
			log.Fatalf("load config: %v", err)
		}
		cfg = c
	}

	conn, wmStore := setupConnection(ctx, *dsn, fileConfig(*configPath, cfg))
	defer func() { _ = conn.Close(ctx) }()

	requireColdTier(ctx, conn)
	resolveAndValidateTables(ctx, cfg, conn)

	for i := range cfg.Archiver.Tables {
		prepareAndRunTable(ctx, cfg, &cfg.Archiver.Tables[i], conn, wmStore, *debugExportDelay)
	}
}

// dispatchCLI handles the non-archive-run invocations: the top-level help
// overview (help/-h/--help) and the management subcommands routed through the
// shared CLI. Returns true when it fully handled the invocation so main should
// return; false when this is a default archive run (no arguments, or a leading
// "-" flag) that main proceeds with.
func dispatchCLI(ctx context.Context) bool {
	const defaultDesc = "run one tiering/archive cycle"
	// No arguments is the default archive run. help/-h/--help lists the
	// management subcommands so they are discoverable.
	if len(os.Args) < 2 {
		return false
	}
	if os.Args[1] == "help" || os.Args[1] == "-h" || os.Args[1] == "--help" {
		partcfg.PrintTopLevelUsage(os.Stdout, "archiver", defaultDesc)
		return true
	}
	// A management subcommand routes to the shared CLI; a flag means the
	// default archive run.
	if !strings.HasPrefix(os.Args[1], "-") {
		if partcfg.IsCommand(os.Args[1]) {
			if err := partcfg.Run(ctx, os.Args[1], os.Args[2:]); err != nil {
				log.Fatalf("%s: %v", os.Args[1], err)
			}
			return true
		}
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n", os.Args[1])
		partcfg.PrintTopLevelUsage(os.Stderr, "archiver", defaultDesc)
		os.Exit(2)
	}
	return false
}

// fileConfig is the YAML to verify against the server, or nil when the run was
// given none.
func fileConfig(path string, cfg *config.Config) *config.Config {
	if path == "" {
		return nil
	}
	return cfg
}

// setupConnection connects to PostgreSQL (dsn, else the YAML's postgres.dsn,
// else the libpq environment), refuses a YAML that disagrees with the stored
// configuration, verifies the connection, and ensures the watermark table
// exists. Any failure log.Fatalf's — this is the cron body.
func setupConnection(ctx context.Context, dsn string, cfg *config.Config) (*pgx.Conn, *watermark.Store) {
	conn, err := partcfg.Connect(ctx, dsn, cfg)
	if err != nil {
		log.Fatalf("connect pg: %v", err)
	}

	if err := conn.Ping(ctx); err != nil {
		log.Fatalf("ping pg: %v", err)
	}

	wmStore := watermark.NewStore(conn)
	if err := wmStore.EnsureTable(ctx); err != nil {
		log.Fatalf("ensure watermark table: %v", err)
	}
	return conn, wmStore
}

// requireColdTier stops the run on a server with no cold tier: the catalog
// settings and a storage secret are what every archive cycle needs, and they
// live in the server, not in a file.
func requireColdTier(ctx context.Context, conn *pgx.Conn) {
	var ok bool
	err := conn.QueryRow(ctx, `SELECT COALESCE(current_setting('coldfront.warehouse', true), '') <> ''
		   AND COALESCE(current_setting('coldfront.lakekeeper_endpoint', true), '') <> ''
		   AND EXISTS (SELECT 1 FROM coldfront.storage_secret)`).Scan(&ok)
	if err != nil {
		log.Fatalf("read the cold-tier configuration: %v", err)
	}
	if !ok {
		log.Fatalf("this server has no cold tier: set coldfront.warehouse and coldfront.lakekeeper_endpoint in postgresql.conf and run coldfront.set_storage_secret (or set_storage_secret_azure, set_storage_secret_vended), or import a YAML with an s3: or azure: stanza")
	}
}

// resolveAndValidateTables loads the managed tables from the replicated
// coldfront.partition_config table, assigns them onto cfg, and validates the
// config. Any failure log.Fatalf's.
func resolveAndValidateTables(ctx context.Context, cfg *config.Config, conn *pgx.Conn) {
	tables, err := partcfg.ResolveTables(ctx, conn, partcfg.Tiered)
	if err != nil {
		log.Fatalf("resolve tables: %v", err)
	}
	if len(tables) == 0 {
		log.Fatalf("no tables in coldfront.partition_config; add one with `archiver register` or write a YAML into the server with `archiver import --config <yaml>`")
	}
	log.Printf("loaded %d table(s) from coldfront.partition_config", len(tables))
	cfg.Archiver.Tables = tables
	if err := cfg.Validate(); err != nil {
		log.Fatalf("config invalid: %v", err)
	}
}

// prepareAndRunTable validates one table's periods/partitioning (against the
// live connection), auto-detects the partition column for flat tables, then
// runs a single archive cycle. Any failure log.Fatalf's — this is the cron
// body, where the first table error must abort the whole run non-zero.
func prepareAndRunTable(ctx context.Context, cfg *config.Config, t *config.TableConfig, conn *pgx.Conn, wmStore *watermark.Store, debugExportDelay time.Duration) {
	// Period syntax + retention>hot ordering are PostgreSQL interval semantics
	// (calendar-aware), so they're validated here against the live connection —
	// config.Load (no DB) only checks presence.
	if err := partition.ValidatePeriods(ctx, conn, t.HotPeriod, t.RetentionPeriod); err != nil {
		log.Fatalf("[%s] %v", t.SourceTable, err)
	}

	// Flat single-level tables: reject sub-partitioning and auto-detect the
	// time column. 2-level (sub_partition) tables are LIST→RANGE by design
	// and carry an explicit partition_column (the RANGE/time key), required
	// by config — on a first run no LIST child exists yet to detect it from.
	if t.SubPartition == nil {
		if err := validateFlatPartitioning(ctx, conn, t.SourceSchema, t.SourceTable); err != nil {
			log.Fatalf("[%s] %v", t.SourceTable, err)
		}
		if t.PartitionColumn == "" {
			cols, err := detectPartitionColumns(ctx, conn, t.SourceSchema, t.SourceTable)
			if err != nil {
				log.Fatalf("auto-detect partition column for %s: %v", t.SourceTable, err)
			}
			if len(cols) == 0 {
				log.Fatalf("[%s] no partition column detected", t.SourceTable)
			}
			t.PartitionColumn = cols[0]
			log.Printf("[%s] auto-detected partition column: %s", t.SourceTable, cols[0])
		}
	}

	log.Printf("[%s] starting archive cycle", t.SourceTable)
	if err := runCycle(ctx, cfg, t, conn, wmStore, debugExportDelay); err != nil {
		log.Fatalf("[%s] archive cycle: %v", t.SourceTable, err)
	}
	log.Printf("[%s] archive cycle complete", t.SourceTable)
}

// dollarQuote wraps s as a PostgreSQL dollar-quoted literal using a randomized
// tag that is verified absent from s. A static tag ($q$) is breakable: an
// Iceberg identifier or a values_source value containing the literal tag would
// close the quote early and inject the trailing text as separate SQL. A random,
// collision-checked tag cannot be terminated by any payload content, so the
// wrapped string is always a single safe literal.
func dollarQuote(s string) (string, error) {
	var b [9]byte
	for {
		if _, err := rand.Read(b[:]); err != nil {
			return "", fmt.Errorf("dollar-quote tag: %w", err)
		}
		tag := "$cf" + hex.EncodeToString(b[:]) + "$"
		if !strings.Contains(s, tag) {
			return tag + s + tag, nil
		}
	}
}

// execDuckDB executes a DuckDB SQL statement via duckdb.raw_query().
func execDuckDB(ctx context.Context, conn *pgx.Conn, sql string) error {
	q, err := dollarQuote(sql)
	if err != nil {
		return err
	}
	_, err = conn.Exec(ctx, fmt.Sprintf(`SELECT duckdb.raw_query(%s)`, q)) // nosemgrep
	return err
}

// attachIceberg attaches the Lakekeeper catalog. The cold-store credential is
// the persistent DuckDB secret the stored storage_secret row materialized, so
// nothing is created here. coldfront.ensure_attached()
// is the sole ATTACH: it derives the access-delegation mode from the stored
// storage_secret row (VENDED_CREDENTIALS when vended, else NONE) and pins the
// bundled httplib HTTP client. The system libcurl client DuckDB 1.5 defaults to
// uses a threaded resolver that races glibc's getaddrinfo netlink fd under a
// copy-on-write Iceberg DELETE against an object-store hostname (never a bare-IP
// store, which is why CI on SeaweedFS never hit it); curl 8.11.1 made that a hard
// SIGABRT via CVE-2025-0665. The base now builds curl 8.12.0 (CVE-fixed), but
// httplib stays pinned: it resolves in-thread, so DuckDB stays fully parallel.
func attachIceberg(ctx context.Context, conn *pgx.Conn) error {
	if _, err := conn.Exec(ctx, "SELECT coldfront.ensure_attached()"); err != nil { // nosemgrep
		return fmt.Errorf("attach iceberg catalog via ensure_attached: %w", err)
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
	name := partition.ResolveSourceTable(ctx, db, schema, table)
	var def string
	err := db.QueryRow(ctx /* nosemgrep */, `
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
	name := partition.ResolveSourceTable(ctx, db, schema, table)
	var child string
	err := db.QueryRow(ctx /* nosemgrep */, `
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

// archiveCycle carries the per-archive-cycle context shared by the tiering helpers,
// so they don't thread a dozen positional args.
type archiveCycle struct {
	cfg              *config.Config
	t                *config.TableConfig
	conn             *pgx.Conn
	wmStore          *watermark.Store
	partMgr          *partition.Manager
	iceTable         string
	now              time.Time
	debugExportDelay time.Duration
	// listCol is the LIST (level-1) column of a two-level table, empty for a flat
	// one: the cold table is partitioned by it, and the Phase-0 wipe is scoped to
	// its value.
	listCol string
	// The archive watermark as it stood when this cycle's tiering pass began,
	// captured by bootstrapTieredView before the per-partition loop and held
	// fixed for the whole pass. Each cutover advances the stored watermark to
	// its own partition's upper bound, so this snapshot is what keeps
	// "already archived" a property of the cycle rather than of a partition's
	// position in the loop.
	wmCutoff time.Time
	haveWM   bool
}

// runCycle performs one archive pass for a single table: ensures future
// partitions, finds expired ones, archives each (capture trigger + bulk
// export + delta replay + atomic cutover), and drops archived PG partitions.
// Safe to re-run — every phase is idempotent.
func runCycle(ctx context.Context, cfg *config.Config, t *config.TableConfig, conn *pgx.Conn, wmStore *watermark.Store, debugExportDelay time.Duration) error {
	now := time.Now().UTC()
	if t.SubPartition != nil {
		return runCycleTwoLevel(ctx, cfg, t, conn, wmStore, debugExportDelay, now)
	}
	ac := &archiveCycle{
		cfg: cfg, t: t, conn: conn, wmStore: wmStore,
		partMgr:  partition.NewManager(conn),
		iceTable: icebergRef(t.SourceSchema, t.SourceTable),
		now:      now, debugExportDelay: debugExportDelay,
	}

	// Resolve actual table name (_{source} after swap, {source} on first run)
	tableName := partition.ResolveSourceTable(ctx, conn, t.SourceSchema, t.SourceTable)

	// 1 + 1b. Create future partitions and self-heal the current one.
	if err := ac.ensureSingleLevelPartitions(ctx, tableName); err != nil {
		return err
	}

	// 2. Find partitions past the hot window — the tier-to-cold candidates.
	hotExpired, err := ac.findSingleLevelExpired(ctx, tableName)
	if err != nil {
		return err
	}
	// retention_period (optional) drops cold Iceberg data past its age — the
	// destroy end of the lifecycle, distinct from the tier-to-cold above.
	coldExpiry := t.RetentionPeriod != ""
	if len(hotExpired) == 0 && !coldExpiry {
		log.Printf("[%s] nothing to tier or expire", t.SourceTable)
		return nil
	}
	if len(hotExpired) > 0 {
		log.Printf("[%s] found %d partition(s) past the hot window", t.SourceTable, len(hotExpired))
	}

	// 3-5. Attach the catalog + ensure the Iceberg table, tier the past-hot
	//      partitions, then run the cold-expiry pass.
	return ac.tierAndExpireSingleLevel(ctx, hotExpired, coldExpiry)
}

// tierAndExpireSingleLevel is steps 3-5 of runCycle: attach the catalog + ensure
// the Iceberg table, tier each past-hot partition (when any), then run the
// optional cold-expiry pass.
func (ac *archiveCycle) tierAndExpireSingleLevel(ctx context.Context, hotExpired []partition.Info, coldExpiry bool) error {
	// 3. Attach the Lakekeeper catalog and ensure the Iceberg table exists —
	//    needed by both the tiering pass and the cold-expiry DELETE.
	if err := ac.attachAndEnsureTable(ctx); err != nil {
		return err
	}

	// 4. Tiering pass: move each past-hot partition hot → cold.
	if len(hotExpired) > 0 {
		if err := ac.tierExpiredPartitions(ctx, hotExpired); err != nil {
			return err
		}
	}

	// 5. Cold-expiry pass: drop Iceberg data older than retention_period.
	if coldExpiry {
		if err := ac.expireColdTier(ctx); err != nil {
			return err
		}
	}

	return nil
}

// attachAndEnsureTable is step 3 shared by both cycles: attach the Lakekeeper
// catalog and ensure the (single) Iceberg table exists — needed by both the
// tiering pass and the cold-expiry DELETE.
func (ac *archiveCycle) attachAndEnsureTable(ctx context.Context) error {
	if err := attachIceberg(ctx, ac.conn); err != nil {
		return err
	}
	if err := ensureIcebergTable(ctx, ac.conn, ac.t, ac.iceTable, ac.listCol); err != nil {
		return fmt.Errorf("ensure iceberg table: %w", err)
	}
	return nil
}

// premakeRange provisions one RANGE parent: the forward window of future
// periods and the period covering now, which must be maintained together and
// on the same cadence. It reports whether premake had fallen behind. Shared by
// the flat cycle and by each LIST-value child of the 2-level cycle.
func (ac *archiveCycle) premakeRange(ctx context.Context, parent, leafPrefix string) (bool, error) {
	t, partMgr, now := ac.t, ac.partMgr, ac.now
	// The cold tier always partitions by time.
	if err := partMgr.EnsureFuture(ctx, parent, t.SourceSchema,
		t.PartitionColumn, t.PartitionPeriod,
		t.FuturePartitions, now, partition.TimeBoundary{}, leafPrefix); err != nil {
		return false, fmt.Errorf("premake %s: %w", parent, err)
	}
	behind, err := partMgr.EnsureCurrent(ctx, parent, t.SourceSchema,
		t.PartitionPeriod, now, partition.TimeBoundary{}, leafPrefix)
	if err != nil {
		return false, fmt.Errorf("ensure current %s: %w", parent, err)
	}
	return behind, nil
}

// ensureSingleLevelPartitions is phases 1 + 1b of runCycle: create the forward
// window of future partitions, then self-heal the partition covering now.
//
// The archiver deliberately does NOT abort on the "behind" flag (unlike the
// standalone partitioner): it legitimately tiers historical tables whose newest
// partition is already in the past, so "no current partition" is normal here
// rather than a lagging cron, and the two cannot be told apart without per-table
// state. It is logged instead, so a genuine lag stays visible. The 2-level path
// treats it the same way.
func (ac *archiveCycle) ensureSingleLevelPartitions(ctx context.Context, tableName string) error {
	t, now := ac.t, ac.now
	behind, err := ac.premakeRange(ctx, tableName, "")
	if err != nil {
		return err
	}
	if behind {
		log.Printf("[%s] no hot partition covered %s — created it; if this table is actively written, widen future_partitions (=%d) or run more often",
			t.SourceTable, now.Format("2006-01-02"), t.FuturePartitions)
	}
	return nil
}

// findSingleLevelExpired is phase 2 of runCycle: find the partitions past the
// hot window (the tier-to-cold candidates).
func (ac *archiveCycle) findSingleLevelExpired(ctx context.Context, tableName string) ([]partition.Info, error) {
	t, partMgr, now := ac.t, ac.partMgr, ac.now
	hotCutoff, err := partMgr.ExpiryCutoff(ctx, now, t.HotPeriod)
	if err != nil {
		return nil, fmt.Errorf("hot cutoff: %w", err)
	}
	hotExpired, err := partMgr.FindExpired(ctx, tableName, t.SourceSchema, hotCutoff, partition.TimeBoundary{})
	if err != nil {
		return nil, fmt.Errorf("find expired: %w", err)
	}
	return hotExpired, nil
}

// requirePK errors when no column participates in the primary key. The
// race-safe archive pipeline keys delta capture by source PK, so without one an
// UPDATE or DELETE cannot be replayed to Iceberg.
func requirePK(columns []view.Column, schema, table string) error {
	for _, c := range columns {
		if c.IsPK {
			return nil
		}
	}
	return fmt.Errorf("%s.%s has no primary key: required for race-safe archive "+
		"(delta capture keys writes by source PK, and without one an UPDATE or "+
		"DELETE cannot be replayed to Iceberg)", schema, table)
}

// prepareTiering is the once-per-cycle preamble both tiering passes share: read
// the table's columns, require a primary key, then bootstrap and register the
// unified view. Called before the per-partition / per-period loop, never inside it.
func (ac *archiveCycle) prepareTiering(ctx context.Context) ([]view.Column, error) {
	columns, err := getColumns(ctx, ac.conn, ac.t.SourceSchema, ac.t.SourceTable)
	if err != nil {
		return nil, fmt.Errorf("get columns: %w", err)
	}
	if err := requirePK(columns, ac.t.SourceSchema, ac.t.SourceTable); err != nil {
		return nil, err
	}
	if err := ac.bootstrapTieredView(ctx, columns); err != nil {
		return nil, err
	}
	return columns, nil
}

// tierExpiredPartitions is step 4 of runCycle: get columns, require a PK,
// bootstrap the unified view + register it (ONCE), then archive each past-hot
// partition through the cutover pipeline (with idempotent cleanup of any that a
// prior cycle already archived).
func (ac *archiveCycle) tierExpiredPartitions(ctx context.Context, hotExpired []partition.Info) error {
	columns, err := ac.prepareTiering(ctx)
	if err != nil {
		return err
	}

	// Archive each past-hot partition via the cutover pipeline.
	for _, part := range hotExpired {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := ac.archiveOnePartition(ctx, part, columns); err != nil {
			return err
		}
	}
	return nil
}

// archiveOnePartition tiers one past-hot partition: if the cycle-start
// watermark was already past its upper bound it was archived in a prior cycle,
// so just clean up the stale PG partition; otherwise run the full archive
// pipeline. Candidates arrive in ascending bound order, so within one cycle a
// partition is only ever reached before the watermark passes its range.
func (ac *archiveCycle) archiveOnePartition(ctx context.Context, part partition.Info, columns []view.Column) error {
	t := ac.t
	if ac.haveWM && !part.UpperBound.After(ac.wmCutoff) {
		return ac.cleanupAlreadyArchived(ctx, part)
	}

	if err := archivePartition(ctx, ac.conn, t, part, ac.iceTable, columns, ac.debugExportDelay); err != nil {
		return fmt.Errorf("archive %s: %w", part.Name, err)
	}
	log.Printf("archived %s", part.Name)
	return nil
}

// bootstrapTieredView is the first-cycle bootstrap shared by both tiering
// passes: read the watermark, then in one transaction rename {source} to
// _{source}, (re)create the unified view with cutoff=watermark and register the
// tiered view. One transaction, so the view never exists without the registry
// row the hook resolves it by, on this node or on a Spock peer, which applies
// the transaction as a unit. Idempotent: the swap SQL no-ops if the rename
// already happened. Called ONCE before the per-partition / per-period loop,
// never inside it.
func (ac *archiveCycle) bootstrapTieredView(ctx context.Context, columns []view.Column) error {
	t, iceTable := ac.t, ac.iceTable
	wmCutoff, found, err := ac.wmStore.Get(ctx, t.SourceSchema, t.SourceTable)
	if err != nil {
		return fmt.Errorf("get watermark: %w", err)
	}
	ac.wmCutoff, ac.haveWM = wmCutoff, found // the cycle-start snapshot; see archiveCycle
	bootstrapCfg := view.ViewConfig{
		SourceSchema:    t.SourceSchema,
		SourceTable:     t.SourceTable,
		IcebergTable:    iceTable,
		CutoffTime:      wmCutoff,
		PartitionColumn: t.PartitionColumn,
		Columns:         columns,
	}
	tx, err := ac.conn.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin bootstrap: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := view.NewGenerator(tx).Recreate(ctx, bootstrapCfg); err != nil {
		return fmt.Errorf("bootstrap view: %w", err)
	}
	hotTable := pgx.Identifier{t.SourceSchema, "_" + t.SourceTable}.Sanitize()
	if err := registerTieredView(ctx, tx, t.SourceSchema, t.SourceTable,
		hotTable, iceTable, t.PartitionColumn, vectorColumns(columns)); err != nil {
		return fmt.Errorf("register tiered view: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit bootstrap: %w", err)
	}
	return nil
}

// cleanupAlreadyArchived removes a stale PG partition whose range the cold
// tier already covers. The drop requires direct evidence that nothing is lost:
// the partition must be empty. That is the legitimate case, an operator
// creating a historical partition over a range that has already been tiered.
//
// A partition below the watermark that still holds rows is an anomaly. Phase 4
// detaches atomically with the watermark advance, so a partition the pipeline
// archived is never a candidate again, and rows here are in neither tier: an
// out-of-band write straight to the heap, or a mesh peer writing hot against a
// stale cutoff. They are the only copy, so the table fails loudly.
func (ac *archiveCycle) cleanupAlreadyArchived(ctx context.Context, part partition.Info) error {
	t, partMgr := ac.t, ac.partMgr
	rows, err := partMgr.RowCount(ctx, t.SourceSchema, part.Name)
	if err != nil {
		return fmt.Errorf("count rows in %s before dropping it: %w", part.Name, err)
	}
	if rows > 0 {
		return fmt.Errorf("refusing to drop %s.%s: its range is already below the archive "+
			"watermark, yet it holds %d row(s) that were never exported to the cold tier. "+
			"Move them into the cold tier (or out of the database) and drop the partition, "+
			"then re-run", t.SourceSchema, part.Name, rows)
	}
	log.Printf("partition %s is empty and its range is already cold, dropping it", part.Name)
	parent := partMgr.ResolveSourceTable(ctx, t.SourceSchema, t.SourceTable)
	if err := partMgr.Detach(ctx, parent, t.SourceSchema, part.Name); err != nil {
		return fmt.Errorf("detach %s: %w", part.Name, err)
	}
	if err := partMgr.Drop(ctx, t.SourceSchema, part.Name); err != nil {
		return fmt.Errorf("drop %s: %w", part.Name, err)
	}
	return nil
}

// expireColdTier is the step-5 cold-expiry pass: drop Iceberg data older than
// retention_period. Shared by the single-level and 2-level cycles.
func (ac *archiveCycle) expireColdTier(ctx context.Context) error {
	t := ac.t
	cutoff, err := ac.partMgr.ExpiryCutoff(ctx, ac.now, t.RetentionPeriod)
	if err != nil {
		return fmt.Errorf("cold cutoff: %w", err)
	}
	if err := dropColdBeforeRetention(ctx, ac.conn, ac.iceTable, t.PartitionColumn, cutoff); err != nil {
		return fmt.Errorf("cold expiry: %w", err)
	}
	log.Printf("[%s] expired cold rows older than %s", t.SourceTable, cutoff.Format("2006-01-02 15:04:05Z"))
	return nil
}

// runCycleTwoLevel tiers a 2-level LIST(key)→RANGE(time) table. It premakes
// the forward window of RANGE leaves under each LIST value's child, then tiers
// past-hot leaves to the single cold Iceberg table (the LIST key is just a
// column), then runs the list-agnostic cold-expiry. Leaves are tiered grouped by
// ts period, oldest first, and within a period EVERY LIST value's leaf is exported
// to cold before any cutover advances the shared watermark — so a period only goes
// cold once it is cold for all LIST values, and no LIST value's rows vanish from
// the list-agnostic view mid-cycle. The child name uses the stable configured name
// (t.SourceTable) so it matches the partitioner's naming across the bootstrap
// rename of the physical hot table.
// childRef is one LIST-value child: its physical name and the LIST value it
// holds. Built in step 1 of the 2-level cycle, consumed when enumerating leaves.
type childRef struct{ name, listVal string }

// leafRef is one past-hot RANGE leaf under a LIST-value child, carrying enough
// context (child, listVal) for the LIST-value-scoped Phase-0 wipe at export.
type leafRef struct {
	child, listVal string
	info           partition.Info
}

// exported pairs a tiered leaf with the snapshot string its cutover needs, so
// the per-period export-all pass can hand off to the cutover-all pass.
type exported struct {
	lf   leafRef
	snap string
}

func runCycleTwoLevel(ctx context.Context, cfg *config.Config, t *config.TableConfig, conn *pgx.Conn, wmStore *watermark.Store, debugExportDelay time.Duration, now time.Time) error {
	ac := &archiveCycle{
		cfg: cfg, t: t, conn: conn, wmStore: wmStore,
		partMgr:  partition.NewManager(conn),
		iceTable: icebergRef(t.SourceSchema, t.SourceTable),
		now:      now, debugExportDelay: debugExportDelay,
	}

	values, err := ac.partMgr.ListValues(ctx, t.SubPartition.ValuesSource)
	if err != nil {
		return fmt.Errorf("values_source: %w", err)
	}
	parent := partition.ResolveSourceTable(ctx, conn, t.SourceSchema, t.SourceTable) // physical top (_events after swap)
	// The LIST column is read before the tiering preamble renames the hot table,
	// though detectPartitionColumns resolves either name.
	listCols, err := detectPartitionColumns(ctx, conn, t.SourceSchema, t.SourceTable)
	if err != nil {
		return fmt.Errorf("detect list column: %w", err)
	}
	ac.listCol = listCols[0]

	// 1. Premake per LIST value: ensure the LIST child exists (attached to the
	//    physical top, named by the stable source name) and its forward window.
	children, err := ac.premakeListChildren(ctx, parent, values)
	if err != nil {
		return err
	}

	// 2. Enumerate past-hot RANGE leaves under each LIST-value child.
	leaves, err := ac.findExpiredLeaves(ctx, children)
	if err != nil {
		return err
	}

	coldExpiry := t.RetentionPeriod != ""
	if len(leaves) == 0 && !coldExpiry {
		log.Printf("[%s] nothing to tier or expire", t.SourceTable)
		return nil
	}
	if len(leaves) > 0 {
		log.Printf("[%s] found %d leaf partition(s) past the hot window across %d LIST value(s)",
			t.SourceTable, len(leaves), len(children))
	}

	// 3-5. Attach the catalog + ensure the Iceberg table, tier the past-hot
	//      leaves grouped by period, then run the list-agnostic cold-expiry.
	return ac.tierAndExpireTwoLevel(ctx, leaves, coldExpiry)
}

// tierAndExpireTwoLevel is steps 3-5 of runCycleTwoLevel: attach the catalog +
// ensure the (single) Iceberg table, tier the past-hot leaves grouped by ts
// period (when any), then run the optional list-agnostic cold-expiry pass.
func (ac *archiveCycle) tierAndExpireTwoLevel(ctx context.Context, leaves []leafRef, coldExpiry bool) error {
	// 3. Attach the catalog + ensure the (single) Iceberg table.
	if err := ac.attachAndEnsureTable(ctx); err != nil {
		return err
	}

	// 4. Tier the past-hot leaves, grouped by ts period (oldest first).
	if len(leaves) > 0 {
		if err := ac.tierLeavesByPeriod(ctx, leaves); err != nil {
			return err
		}
	}

	// 5. Cold-expiry: drop Iceberg data older than retention_period (list-agnostic).
	if coldExpiry {
		if err := ac.expireColdTier(ctx); err != nil {
			return err
		}
	}
	return nil
}

// premakeListChildren is step 1 of the 2-level cycle: for each LIST value ensure
// its child (attached to the physical top, named by the stable source name) and
// its forward window + current partition exist, logging once if any was behind.
// Two values that map to one child name fail the cycle before it creates any.
func (ac *archiveCycle) premakeListChildren(ctx context.Context, parent string, values []string) ([]childRef, error) {
	t, partMgr, now := ac.t, ac.partMgr, ac.now
	names, err := partition.SubNames(t.SourceTable, values)
	if err != nil {
		return nil, err
	}
	var children []childRef
	anyBehind := false
	for i, v := range values {
		child := names[i]
		if err := partMgr.EnsureListChild(ctx, parent, t.SourceSchema, v, child, t.PartitionColumn); err != nil {
			return nil, err
		}
		b, err := ac.premakeRange(ctx, child, child+"_")
		if err != nil {
			return nil, err
		}
		anyBehind = anyBehind || b
		children = append(children, childRef{child, v})
	}
	if anyBehind {
		log.Printf("[%s] a LIST value had no hot partition covering %s — created it; if this table is actively written, widen future_partitions (=%d) or run more often",
			t.SourceTable, now.Format("2006-01-02"), t.FuturePartitions)
	}
	return children, nil
}

// findExpiredLeaves is step 2 of the 2-level cycle: enumerate the past-hot RANGE
// leaves under each LIST-value child.
func (ac *archiveCycle) findExpiredLeaves(ctx context.Context, children []childRef) ([]leafRef, error) {
	t, partMgr, now := ac.t, ac.partMgr, ac.now
	var leaves []leafRef
	hotCutoff, err := partMgr.ExpiryCutoff(ctx, now, t.HotPeriod)
	if err != nil {
		return nil, fmt.Errorf("hot cutoff: %w", err)
	}
	for _, c := range children {
		exp, err := partMgr.FindExpired(ctx, c.name, t.SourceSchema, hotCutoff, partition.TimeBoundary{})
		if err != nil {
			return nil, fmt.Errorf("find expired %s: %w", c.name, err)
		}
		for _, info := range exp {
			leaves = append(leaves, leafRef{c.name, c.listVal, info})
		}
	}
	return leaves, nil
}

// tierLeavesByPeriod is step 4 of the 2-level cycle: run the shared tiering
// preamble, then group the leaves by ts period and tier them oldest-first.
func (ac *archiveCycle) tierLeavesByPeriod(ctx context.Context, leaves []leafRef) error {
	columns, err := ac.prepareTiering(ctx)
	if err != nil {
		return err
	}

	// Group by period (UpperBound); process oldest-first.
	for _, grp := range groupLeavesByPeriod(leaves) {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := ac.tierOnePeriod(ctx, columns, ac.listCol, grp); err != nil {
			return err
		}
	}
	return nil
}

// groupLeavesByPeriod groups leaves by their ts period (UpperBound) and returns
// the per-period leaf slices ordered oldest-first — so the caller tiers each
// period's leaves together, advancing the shared cutoff one period at a time.
func groupLeavesByPeriod(leaves []leafRef) [][]leafRef {
	byPeriod := map[time.Time][]leafRef{}
	for _, lf := range leaves {
		byPeriod[lf.info.UpperBound] = append(byPeriod[lf.info.UpperBound], lf)
	}
	periods := make([]time.Time, 0, len(byPeriod))
	for p := range byPeriod {
		periods = append(periods, p)
	}
	sort.Slice(periods, func(i, j int) bool { return periods[i].Before(periods[j]) })

	groups := make([][]leafRef, 0, len(periods))
	for _, p := range periods {
		groups = append(groups, byPeriod[p])
	}
	return groups
}

// tierOnePeriod tiers one ts period's leaves: it exports EVERY LIST value's leaf
// for the period FIRST (no detach, cutoff unchanged) so the whole period is in
// cold before the shared cutoff advances, then cuts them all over (the first
// advances the cutoff to p, the rest re-set it idempotently and detach their
// now-excluded leaf). The two loops must stay sequential — never interleaved.
func (ac *archiveCycle) tierOnePeriod(ctx context.Context, columns []view.Column, listCol string, grp []leafRef) error {
	conn, t, iceTable := ac.conn, ac.t, ac.iceTable
	// Export EVERY LIST value's leaf for this period first (no detach, cutoff
	// unchanged) so all of the period is in cold before it advances.
	var done []exported
	for _, lf := range grp {
		snap, err := archiveExport(ctx, conn, t, lf.info, iceTable, columns, listCol, lf.listVal, ac.debugExportDelay)
		if err != nil {
			return fmt.Errorf("export %s: %w", lf.info.Name, err)
		}
		done = append(done, exported{lf, snap})
	}
	// Then cut them over: the first advances the shared cutoff to p, the
	// rest re-set it idempotently and detach their (now-excluded) leaf.
	for _, e := range done {
		if err := archiveCutover(ctx, conn, t, e.lf.info, iceTable, e.snap, columns); err != nil {
			return fmt.Errorf("cutover %s: %w", e.lf.info.Name, err)
		}
		log.Printf("tiered %s (list value %s)", e.lf.info.Name, e.lf.listVal)
	}
	return nil
}

// dropColdBeforeRetention deletes Iceberg rows whose partition column is older
// than the retention cutoff — the destroy end of the tiered data lifecycle.
// Routed through coldfront._exec_iceberg_with_claim so it serializes against
// concurrent cold writers (R-A bakery on a mesh, advisory lock single-node),
// the same no-409 guarantee as every other cold write.
func dropColdBeforeRetention(ctx context.Context, conn *pgx.Conn, iceTable, partCol string, cutoff time.Time) error {
	inner := fmt.Sprintf(
		`DELETE FROM %s WHERE %s < '%s'::timestamptz`,
		iceTable,
		pgx.Identifier{partCol}.Sanitize(),
		sqlutil.Timestamp(cutoff))
	q, err := dollarQuote(inner)
	if err != nil {
		return err
	}
	sql := fmt.Sprintf(`SELECT coldfront._exec_iceberg_with_claim(%s, %s)`,
		sqlutil.Literal(iceTable), q)
	_, err = conn.Exec(ctx, sql) // nosemgrep
	return err
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
func archivePartition(ctx context.Context, conn *pgx.Conn, t *config.TableConfig,
	part partition.Info, iceTable string, columns []view.Column, debugExportDelay time.Duration,
) error {
	snapshot, err := archiveExport(ctx, conn, t, part, iceTable, columns, "", "", debugExportDelay)
	if err != nil {
		return err
	}
	return archiveCutover(ctx, conn, t, part, iceTable, snapshot, columns)
}

// archiveExport runs Phases 0-2 for one partition: the idempotent Iceberg-range
// wipe, install of the capture trigger + delta table, and the bulk PG→Iceberg
// export under a captured snapshot. It returns the snapshot string the cutover's
// delta replay needs. (listCol, listVal) scopes the Phase-0 wipe for a
// 2-level leaf so re-exporting one LIST value's leaf cannot wipe another LIST
// value's already-cold rows in the same ts range; pass "","" for the single-level
// path. Splitting export from cutover lets the 2-level path export EVERY LIST
// value's leaf for a ts period before the shared cutoff advances, so no LIST
// value's rows vanish from the view mid-cycle.
func archiveExport(ctx context.Context, conn *pgx.Conn, t *config.TableConfig,
	part partition.Info, iceTable string, columns []view.Column,
	listCol, listVal string, debugExportDelay time.Duration,
) (string, error) {
	log.Printf("[%s] exporting %s (%s to %s)", t.SourceTable, part.Name, part.LowerBound, part.UpperBound)

	// Phase 0
	t0 := time.Now()
	if err := wipeIcebergRange(ctx, conn, iceTable, t.PartitionColumn, part.LowerBound, part.UpperBound, listCol, listVal); err != nil {
		return "", fmt.Errorf("phase 0 (idempotent prep): %w", err)
	}
	log.Printf("[%s] %s phase 0 (idempotent iceberg-range wipe): %s",
		t.SourceTable, part.Name, time.Since(t0).Round(time.Millisecond))

	// Phase 1
	t0 = time.Now()
	if _, err := conn.Exec(ctx /* nosemgrep */, "SELECT coldfront.install_archive_capture($1, $2)",
		t.SourceSchema, part.Name); err != nil {
		return "", fmt.Errorf("phase 1 (install capture): %w", err)
	}
	log.Printf("[%s] %s phase 1 (install capture trigger + delta table): %s",
		t.SourceTable, part.Name, time.Since(t0).Round(time.Millisecond))

	// Phase 2
	t0 = time.Now()
	snapshotStr, err := bulkExportWithSnapshot(ctx, conn, t, part.Name, iceTable, columns)
	if err != nil {
		return "", fmt.Errorf("phase 2 (bulk export): %w", err)
	}
	log.Printf("[%s] %s phase 2 (bulk export PG→Iceberg under snapshot): %s",
		t.SourceTable, part.Name, time.Since(t0).Round(time.Millisecond))

	if debugExportDelay > 0 {
		log.Printf("[debug-export-delay] holding capture window for %s before replay+cutover", debugExportDelay)
		select {
		case <-time.After(debugExportDelay):
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}
	return snapshotStr, nil
}

// archiveCutover runs Phases 3-5 for one partition: delta replay + the atomic
// cutover (watermark advance + view rebuild + DETACH, under a retry harness),
// then drain + drop. cutover_archive's watermark/view update is idempotent, so
// invoking it across the several leaves of one ts period re-sets the same cutoff
// harmlessly — the first call advances it; the rest just detach their (now
// cutoff-excluded) leaf.
func archiveCutover(ctx context.Context, conn *pgx.Conn, t *config.TableConfig,
	part partition.Info, iceTable, snapshotStr string, columns []view.Column,
) error {
	viewCfg := view.ViewConfig{
		SourceSchema:    t.SourceSchema,
		SourceTable:     t.SourceTable,
		IcebergTable:    iceTable,
		CutoffTime:      part.UpperBound,
		PartitionColumn: t.PartitionColumn,
		Columns:         columns,
	}
	viewDDL := view.GenerateViewSQL(viewCfg)

	if err := runCutoverWithRetry(ctx, conn, t, part, iceTable, snapshotStr, viewDDL); err != nil {
		return err
	}

	// Phase 5: post-cutover drain + drop. Single CALL: cutover_cleanup
	// internally drains stragglers from the lock-acquisition window and then
	// drops the detached partition, capture trigger, and delta table.
	t5 := time.Now()
	if _, err := conn.Exec(ctx, /* nosemgrep */
		"CALL coldfront.cutover_cleanup($1, $2, $3, $4)",
		t.SourceSchema, part.Name, snapshotStr, iceTable); err != nil {
		return fmt.Errorf("phase 5 (cleanup): %w", err)
	}
	log.Printf("[%s] %s phase 5 (cleanup: drain stragglers + drop partition + trigger + delta): %s",
		t.SourceTable, part.Name, time.Since(t5).Round(time.Millisecond))
	return nil
}

// isRetryableCutover reports whether a Phase-4 (cutover_archive) failure is
// worth retrying. cutover_archive's only transient failure by design is its
// lock_timeout circuit breaker on the ACCESS EXCLUSIVE acquisition, which raises
// lock_not_available (55P03) when a cold writer still holds the partition; the
// lock_timeout is kept below deadlock_timeout so the cutover always yields that
// way. Every other error is permanent (e.g. an inbound FK blocking DETACH,
// 23503) — retrying only burns the backoff budget, so fail fast.
func isRetryableCutover(err error) bool {
	var pg *pgconn.PgError
	return errors.As(err, &pg) && pg.Code == "55P03"
}

// cutoverFailHint returns actionable guidance for the well-known permanent
// cutover failures. An inbound foreign key blocks DETACH (23503) because
// archiving physically removes the rows from PostgreSQL (export to Iceberg,
// then DETACH + DROP) and PG cannot enforce a foreign key against the cold tier.
func cutoverFailHint(err error) string {
	var pg *pgconn.PgError
	if errors.As(err, &pg) && pg.Code == "23503" {
		return fmt.Sprintf(" — inbound foreign key %q blocks the partition DETACH; "+
			"archiving removes these rows from PostgreSQL, so the foreign key must be "+
			"dropped before this table can be archived", pg.ConstraintName)
	}
	return ""
}

// runCutoverWithRetry runs Phase 3 (delta replay) + Phase 4 (atomic cutover)
// under a 10-attempt retry harness with exponential backoff (100ms → 51.2s).
// Phase 3 is idempotent so retries are safe; Phase 4 either commits everything
// atomically or rolls back cleanly. Each attempt's wall-clock is logged so the
// per-phase totals are visible even when retries fire. Returns nil only after a
// successful cutover (so the caller's Phase 5 runs ONLY then).
func runCutoverWithRetry(ctx context.Context, conn *pgx.Conn, t *config.TableConfig,
	part partition.Info, iceTable, snapshotStr, viewDDL string,
) error {
	backoff := 100 * time.Millisecond
	var lastErr error
	cutoverDone := false
	for attempt := 1; attempt <= 10; attempt++ {
		t3 := time.Now()
		if _, err := conn.Exec(ctx, /* nosemgrep */
			"CALL coldfront.replay_archive_delta($1, $2, $3, $4)",
			t.SourceSchema, part.Name, snapshotStr, iceTable); err != nil {
			return fmt.Errorf("phase 3 attempt %d: %w", attempt, err)
		}
		log.Printf("[%s] %s phase 3 attempt %d (delta replay): %s",
			t.SourceTable, part.Name, attempt, time.Since(t3).Round(time.Millisecond))

		t4 := time.Now()
		if _, err := conn.Exec(ctx, /* nosemgrep */
			"CALL coldfront.cutover_archive($1, $2, $3, $4, $5, $6, $7)",
			t.SourceSchema, part.Name, t.SourceTable,
			part.UpperBound, viewDDL, iceTable, 100); err == nil {
			log.Printf("[%s] %s phase 4 attempt %d (cutover: lock + watermark + view + DETACH): %s",
				t.SourceTable, part.Name, attempt, time.Since(t4).Round(time.Millisecond))
			cutoverDone = true
			break
		} else {
			lastErr = err
		}

		// Only the lock-contention timeout (55P03) is transient. Anything else is
		// permanent — fail fast instead of burning the ~51s backoff budget.
		if !isRetryableCutover(lastErr) {
			return fmt.Errorf("cutover %s failed (permanent, not retried): %w%s",
				part.Name, lastErr, cutoverFailHint(lastErr))
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
	return nil
}

// wipeIcebergRange deletes any existing Iceberg rows whose partition column
// falls inside [lower, upper). Phase 0 of archive — handles the case where a
// previous archive cycle exported to Iceberg but crashed before cutover, so
// the partition remained attached and will be re-exported this cycle. For a
// 2-level leaf (listVal != "") the delete is scoped to that LIST value so
// re-exporting one LIST value's leaf cannot wipe another's already-cold rows
// in the same ts range (they share one Iceberg table).
func wipeIcebergRange(ctx context.Context, conn *pgx.Conn, iceTable, partCol string, lower, upper time.Time, listCol, listVal string) error {
	listPred := ""
	if listVal != "" {
		listPred = fmt.Sprintf(" AND %s = '%s'",
			pgx.Identifier{listCol}.Sanitize(), strings.ReplaceAll(listVal, "'", "''"))
	}
	// Route through coldfront._exec_iceberg_with_claim so this cold-tier write
	// is serialized against concurrent committers (R-A bakery on a mesh, local
	// advisory lock single-node) — same no-409 guarantee as every other cold
	// write. The inner DELETE is dollar-quoted as the p_sql argument.
	inner := fmt.Sprintf(
		`DELETE FROM %s WHERE %s >= '%s'::timestamptz AND %s < '%s'::timestamptz%s`,
		iceTable,
		pgx.Identifier{partCol}.Sanitize(),
		sqlutil.Timestamp(lower),
		pgx.Identifier{partCol}.Sanitize(),
		sqlutil.Timestamp(upper),
		listPred)
	q, err := dollarQuote(inner)
	if err != nil {
		return err
	}
	sql := fmt.Sprintf(`SELECT coldfront._exec_iceberg_with_claim(%s, %s)`,
		sqlutil.Literal(iceTable), q)
	_, err = conn.Exec(ctx, sql) // nosemgrep
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
// vecCompanion names the generated real[] column that carries a vector column's
// scannable form on the hot table. coldfront._vec_companion derives the same name
// for the SQL-side view rebuild; the two have to agree.
func vecCompanion(col string) string { return "_cf_vec_" + col }

// vecLayoutProps asks the extension for the CREATE TABLE properties a clustered
// table needs, or "" when the table has no vector. The values live in the
// extension so both modes create the same layout; the primary key rides along as
// the sort key's tiebreak, which only this side knows. Every table the archiver
// creates is partitioned, which the extension's property set depends on.
func vecLayoutProps(ctx context.Context, conn *pgx.Conn, columns []view.Column) (string, error) {
	if len(vectorColumns(columns)) == 0 {
		return "", nil
	}
	var pk []string
	for _, c := range columns {
		if c.IsPK {
			pk = append(pk, c.Name)
		}
	}
	var props string
	if err := conn.QueryRow(ctx,
		"SELECT coldfront._vec_layout_props(coldfront._vec_sort_key($1, $2), true)",
		vectorColumns(columns)[0], pk).Scan(&props); err != nil {
		return "", fmt.Errorf("layout properties: %w", err)
	}
	return props, nil
}

// pkOrder spells the primary key as trailing ORDER BY terms, or "" when the table
// has none. A tiebreak for determinism, not a pruning aid: sorting by cluster
// scatters a cluster's rows through key space.
func pkOrder(columns []view.Column) string {
	var terms []string
	for _, c := range columns {
		if c.IsPK {
			terms = append(terms, "s."+pgx.Identifier{c.Name}.Sanitize())
		}
	}
	if len(terms) == 0 {
		return ""
	}
	return ", " + strings.Join(terms, ", ")
}

// vectorColumns names the table's vector columns in column order, empty when it has
// none. The order is the contract: the Iceberg schema declares one cluster column
// per entry in this order, a positional cold write fills them in it, and the first
// entry is the one that owns the file sort order.
func vectorColumns(columns []view.Column) []string {
	var out []string
	for _, c := range columns {
		if c.IsVector() {
			out = append(out, c.Name)
		}
	}
	return out
}

// vecListPrefix asks the extension for the expression that assigns a cluster to
// each staged row, leading the Iceberg INSERT's projection, or "" when the table
// has no vector.
//
// The extension owns the expression rather than the archiver spelling its own:
// a row whose cluster disagrees with its vector is invisible to its own search
// and reports no error, so every write path derives from one definition. It also
// reads the centroids over pglocal, which is why the caller attaches it.
func vecListPrefix(ctx context.Context, conn *pgx.Conn, t *config.TableConfig, columns []view.Column) (string, error) {
	vecCols := vectorColumns(columns)
	if len(vecCols) == 0 {
		return "", nil
	}
	if _, err := conn.Exec(ctx, "SELECT coldfront.ensure_pg_attached()"); err != nil {
		return "", fmt.Errorf("attach pglocal: %w", err)
	}
	exprs := make([]string, len(vecCols))
	for i, c := range vecCols {
		exprs[i] = "s." + pgx.Identifier{c}.Sanitize()
	}
	var prefix string
	if err := conn.QueryRow(ctx,
		"SELECT coldfront._vec_list_prefix($1, $2, $3, $4)",
		t.SourceSchema, t.SourceTable, vecCols, exprs,
	).Scan(&prefix); err != nil {
		return "", fmt.Errorf("cluster expression: %w", err)
	}
	return prefix, nil
}

// stageSelectList builds the SELECT projection for the bulk export. Which
// columns need a cast, and to what, is view.Column.ExportCast's decision, and
// which hot-side column is read is view.Column.HotRef's: this only spells the
// projection.
func stageSelectList(columns []view.Column) string {
	if len(columns) == 0 {
		return "*"
	}
	parts := make([]string, 0, len(columns))
	for _, c := range columns {
		id := pgx.Identifier{c.Name}.Sanitize()
		ref, aliased := c.HotRef()
		switch {
		case aliased:
			// The companion is already real[]; reading it needs no cast.
			parts = append(parts, ref+" AS "+id)
		case c.ExportCast() != "":
			parts = append(parts, ref+"::"+c.ExportCast()+" AS "+id)
		default:
			parts = append(parts, ref)
		}
	}
	return strings.Join(parts, ", ")
}

// needsPGStage reports whether the column set contains a type pg_duckdb's PG
// reader cannot scan, so PostgreSQL has to materialise a cast copy in a plain
// temp table before the DuckDB stage reads it.
//
// interval is included defensively (Iceberg-VARCHAR-backed, and not worth a
// separate scan probe). jsonb, bytea and double scan fine and must not trigger
// it: the detour copies every partition twice. A vector does not trigger it
// either, because the export reads its generated real[] companion rather than the
// pgvector column (see view.Column.HotRef).
func needsPGStage(columns []view.Column) bool {
	for _, c := range columns {
		if c.ViewCastType == "interval" {
			return true
		}
	}
	return false
}

func bulkExportWithSnapshot(ctx context.Context, conn *pgx.Conn, t *config.TableConfig, partName, iceTable string, columns []view.Column) (string, error) {
	var snapshotStr string
	if err := conn.QueryRow(ctx, "SELECT pg_current_snapshot()::text").Scan(&snapshotStr); err != nil { // nosemgrep
		return "", fmt.Errorf("capture snapshot: %w", err)
	}

	// Stage the partition into a DuckDB-backed temp table for the Iceberg
	// write. A few VARCHAR-backed types pg_duckdb's reader prefers not to scan
	// directly (interval) get a PostgreSQL-side text-cast copy in a plain temp
	// table first; then pg_duckdb scans that text-only table. The value lands as
	// VARCHAR in Iceberg and the transparent view casts it back on read.
	// jsonb-only / plain tables skip the detour (single copy, fast path).
	// The projection belongs to whichever statement reads the real partition: it is
	// what casts the VARCHAR-backed types and what reads a vector through its
	// generated companion instead of the pgvector column pg_duckdb cannot scan.
	// After the detour, cf_pgstage already holds those columns under their own
	// names, so the DuckDB stage takes them as they are.
	src := pgx.Identifier{t.SourceSchema, partName}.Sanitize()
	proj := stageSelectList(columns)
	if needsPGStage(columns) {
		pgStageSQL := fmt.Sprintf(
			"CREATE TEMP TABLE cf_pgstage AS SELECT %s FROM %s", proj, src)
		if _, err := conn.Exec(ctx, pgStageSQL); err != nil { // nosemgrep
			return "", fmt.Errorf("pg text-stage: %w", err)
		}
		defer func() { _, _ = conn.Exec(ctx, "DROP TABLE IF EXISTS cf_pgstage") }() // nosemgrep
		src = "cf_pgstage"
		proj = "*"
	}
	stageSQL := fmt.Sprintf(
		"CREATE TEMP TABLE duck_stage USING duckdb AS SELECT %s FROM %s", proj, src)
	if _, err := conn.Exec(ctx, stageSQL); err != nil { // nosemgrep
		return "", fmt.Errorf("stage: %w", err)
	}
	defer func() { _, _ = conn.Exec(ctx, "DROP TABLE IF EXISTS duck_stage") }() // nosemgrep

	// Route the bulk iceberg INSERT through the bakery wrapper (serialized:
	// R-A on a mesh, local advisory lock single-node). Runs as an autocommit
	// statement on this dedicated conn, so the claim/lock is released at this
	// statement's commit. duck_stage was created on the same conn in the prior
	// statement, so only one DuckDB-database write happens inside this tx.
	vecPrefix, err := vecListPrefix(ctx, conn, t, columns)
	if err != nil {
		return "", err
	}
	// Ordered by cluster, so this file's own row groups each hold roughly one
	// cluster and a probe skips the rest of it. Nothing outside this file is
	// touched: the sorted regions accumulate and compaction folds them together.
	order := ""
	if vecPrefix != "" {
		order = " ORDER BY 1" + pkOrder(columns)
	}
	insertSQL, err := dollarQuote(fmt.Sprintf(
		"INSERT INTO %s SELECT %ss.* FROM pg_temp.duck_stage s%s", iceTable, vecPrefix, order))
	if err != nil {
		return "", fmt.Errorf("iceberg insert: %w", err)
	}
	if _, err := conn.Exec(ctx, // nosemgrep
		fmt.Sprintf("SELECT coldfront._exec_iceberg_with_claim(%s, %s)", sqlutil.Literal(iceTable), insertSQL),
	); err != nil {
		return "", fmt.Errorf("iceberg insert: %w", err)
	}
	return snapshotStr, nil
}

// (Old exportPartition + retryOnConflict were replaced by archivePartition's
// 5-phase pipeline. Catalog-conflict retry is no longer needed because the
// bulk export is one autocommit DuckDB transaction; if Iceberg rejects it,
// the whole archive cycle errors out and cron retries.)

// icebergRef is the DuckDB reference for a source table's cold Iceberg table.
// The PG schema is the Iceberg namespace, so the ref is ice.<schema>.<table>
// and same-named tables in different PG schemas resolve to distinct tables.
func icebergRef(schema, table string) string {
	return pgx.Identifier{"ice", schema, table}.Sanitize()
}

// coldPartitionClause is the PARTITIONED BY clause the cold table is created
// with, mirroring the hot partitioning: the period's transform on the time
// column, led by the LIST column of a two-level table (listCol, empty for a flat
// one). One export is then exactly one partition, a leaf wipe covers exactly one,
// and a predicate on either column skips whole manifests.
func coldPartitionClause(period, tsCol, listCol string) (string, error) {
	transform := map[string]string{partition.PeriodMonthly: "month", partition.PeriodDaily: "day"}[period]
	if transform == "" {
		return "", fmt.Errorf("partition_period %q has no Iceberg transform", period)
	}
	var terms []string
	if listCol != "" {
		terms = append(terms, pgx.Identifier{listCol}.Sanitize())
	}
	terms = append(terms, transform+"("+pgx.Identifier{tsCol}.Sanitize()+")")
	return " PARTITIONED BY (" + strings.Join(terms, ", ") + ")", nil
}

// ensureIcebergTable creates the Iceberg namespace and table (matching the
// PG source schema) if they don't already exist. Safe to call every run. The
// partition spec is set at creation and stays with the table.
func ensureIcebergTable(ctx context.Context, conn *pgx.Conn, t *config.TableConfig, iceTable, listCol string) error {
	if err := execDuckDB(ctx, conn, fmt.Sprintf("CREATE SCHEMA IF NOT EXISTS %s",
		pgx.Identifier{"ice", t.SourceSchema}.Sanitize())); err != nil {
		return fmt.Errorf("create namespace: %w", err)
	}

	columns, err := getColumns(ctx, conn, t.SourceSchema, t.SourceTable)
	if err != nil {
		return fmt.Errorf("get columns: %w", err)
	}
	defs := make([]string, 0, len(columns)+1)
	// One cluster column per vector column, leading the schema in column order, which
	// is the order a positional cold write fills them in.
	for _, c := range vectorColumns(columns) {
		defs = append(defs, pgx.Identifier{view.VecListColumn(c)}.Sanitize()+" INTEGER")
	}
	for _, c := range columns {
		defs = append(defs, fmt.Sprintf("%s %s", pgx.Identifier{c.Name}.Sanitize(), c.Type))
	}
	colDefs := strings.Join(defs, ", ")

	part, err := coldPartitionClause(t.PartitionPeriod, t.PartitionColumn, listCol)
	if err != nil {
		return err
	}
	props, err := vecLayoutProps(ctx, conn, columns)
	if err != nil {
		return err
	}
	if err := execDuckDB(ctx, conn, fmt.Sprintf("CREATE TABLE IF NOT EXISTS %s (%s)%s%s",
		iceTable, colDefs, part, props)); err != nil {
		return fmt.Errorf("create iceberg table: %w", err)
	}
	return nil
}

// registerTieredView upserts a row in coldfront.tiered_views so the
// coldfront C extension can identify this view as a tiered target and
// rewrite UPDATE/DELETE into dual-tier CTEs. Called after every view recreate.
func registerTieredView(ctx context.Context, db view.DBTX, schema, table, hotTable, icebergTable, partitionCol string, vecColumns []string) error {
	_, err := db.Exec(ctx /* nosemgrep */, `
		INSERT INTO coldfront.tiered_views (schema_name, relname, hot_table, iceberg_table, partition_col, vec_columns)
		VALUES ($1, $2, $3, $4, $5, NULLIF($6, '{}'::text[]))
		ON CONFLICT (schema_name, relname) DO UPDATE
		  SET hot_table     = EXCLUDED.hot_table,
		      iceberg_table = EXCLUDED.iceberg_table,
		      partition_col = EXCLUDED.partition_col,
		      vec_columns   = EXCLUDED.vec_columns`,
		schema, table, hotTable, icebergTable, partitionCol, vecColumns)
	return err
}

// getColumns introspects pg_catalog to return the column list for the source
// table. Each Column.Type is the Iceberg storage type and Column.ViewCastType
// the cast the view applies, both from the extension's type map
// (coldfront._iceberg_storage_type and coldfront._iceberg_view_cast_type), the
// map create_iceberg_table and the view rebuild use as well.
//
// A column whose type has no Iceberg-compatible mapping fails the query: the map
// raises rather than falling back to VARCHAR and losing precision or identity at
// write time.
//
// IsIdentity is attidentity = 'a' (GENERATED ALWAYS AS IDENTITY); IsPK is
// participation in pg_index.indisprimary. Composite PKs handled transparently.
func getColumns(ctx context.Context, db querier, schema, tableName string) ([]view.Column, error) {
	actualName := partition.ResolveSourceTable(ctx, db, schema, tableName)

	cols, err := scanColumns(ctx, db, schema, actualName)
	if err != nil {
		return nil, err
	}

	pkSet, err := scanPrimaryKeys(ctx, db, schema, actualName)
	if err != nil {
		return nil, err
	}

	for i := range cols {
		if pkSet[cols[i].Name] {
			cols[i].IsPK = true
		}
	}
	return cols, nil
}

// scanColumns runs the column-metadata query (the FIRST of getColumns' two
// queries). A vector's generated companion is ColdFront's own column, not one of
// the table's, so the extension's companion predicate keeps it out and the list
// holds exactly one column per user column.
func scanColumns(ctx context.Context, db querier, schema, actualName string) ([]view.Column, error) {
	// attidentity is PG internal type "char"; cast to text for pgx compatibility.
	rows, err := db.Query(ctx /* nosemgrep */, `
		SELECT a.attname,
		       coldfront._iceberg_storage_type(format_type(a.atttypid, a.atttypmod), a.attname),
		       coldfront._iceberg_view_cast_type(format_type(a.atttypid, a.atttypmod)),
		       a.attidentity::text
		FROM pg_attribute a
		JOIN pg_class c ON c.oid = a.attrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2
		  AND a.attnum > 0 AND NOT a.attisdropped
		  AND NOT coldfront._is_vec_companion(a.attname, a.attgenerated)
		ORDER BY a.attnum`, schema, actualName)
	if err != nil {
		return nil, fmt.Errorf("columns of %s.%s: %w", schema, actualName, err)
	}
	defer rows.Close()

	var cols []view.Column
	for rows.Next() {
		var col view.Column
		var attidentity string
		if err := rows.Scan(&col.Name, &col.Type, &col.ViewCastType, &attidentity); err != nil {
			return nil, err
		}
		col.IsIdentity = attidentity == "a"
		if col.IsVector() {
			col.HotSource = vecCompanion(col.Name)
		}
		cols = append(cols, col)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("columns of %s.%s: %w", schema, actualName, err)
	}
	return cols, nil
}

// scanPrimaryKeys runs the primary-key query (the SECOND of getColumns' two
// queries) and returns the set of PK column names — single-column and composite.
func scanPrimaryKeys(ctx context.Context, db querier, schema, actualName string) (map[string]bool, error) {
	// Primary key column names — works for single-column and composite PKs.
	pkRows, err := db.Query(ctx /* nosemgrep */, `
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
	return pkSet, pkRows.Err()
}

// init configures the standard logger: UTC timestamps on stderr so cron
// output is unambiguous across timezones.
func init() {
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.SetOutput(os.Stderr)
}
