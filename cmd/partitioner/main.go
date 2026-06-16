// Command partitioner is the standalone native-partition manager: for each
// managed table it premakes the forward window of partitions and detaches +
// drops those past retention, against stock PostgreSQL — no cold-tier / Iceberg
// dependency. One reconcile pass per invocation; run it from cron. Config is a
// YAML file (--config) holding the Postgres DSN and per-table partition
// settings; any iceberg/s3 sections are ignored here.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/pgedge/coldfront/internal/config"
	"github.com/pgedge/coldfront/internal/partcfg"
	"github.com/pgedge/coldfront/internal/partition"
)

// reconcileFailed logs a reconcile error and reports whether it should fail the
// run. A "behind" condition is self-healed by RunReconcile (the partition
// covering now is created during the pass), so — consistent with the archiver,
// which logs the same condition non-fatally — it is a WARNING and NOT fatal.
// Any other reconcile error is fatal.
func reconcileFailed(parent string, err error) bool {
	if errors.Is(err, partition.ErrBehind) {
		log.Printf("[%s] WARNING (self-healed): %v", parent, err)
		return false
	}
	log.Printf("[%s] reconcile: %v", parent, err)
	return true
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if dispatchSubcommand(ctx) {
		return
	}

	cfgPath := flag.String("config", "", "path to the YAML config file")
	flag.Parse()
	if *cfgPath == "" {
		log.Fatal("--config is required")
	}

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	conn, err := pgx.Connect(ctx, cfg.Postgres.DSN)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := conn.Ping(ctx); err != nil {
		log.Fatalf("ping: %v", err)
	}

	loadAndResolve(ctx, conn, cfg, *cfgPath)
	validateTablePeriods(ctx, conn, cfg)
	runReconcilePass(ctx, conn, cfg)
}

// dispatchSubcommand handles the top-level help/overview and management
// subcommands, routing the latter to the shared CLI. It returns true when the
// invocation was fully handled (main should return); false means main should
// fall through to its default reconcile run (--config). Preserves the
// os.Exit(2)-for-unknown-subcommand vs log.Fatalf split and the Stdout/Stderr
// usage destinations.
func dispatchSubcommand(ctx context.Context) bool {
	const defaultDesc = "run one partition-maintenance reconcile pass"
	// Top-level help / overview — no args, or help/-h/--help — lists the
	// management subcommands so they are discoverable.
	if len(os.Args) < 2 || os.Args[1] == "help" || os.Args[1] == "-h" || os.Args[1] == "--help" {
		partcfg.PrintTopLevelUsage(os.Stdout, "partitioner", defaultDesc)
		return true
	}
	// A management subcommand routes to the shared CLI; with no subcommand the
	// partitioner does its default reconcile run (--config below).
	if !strings.HasPrefix(os.Args[1], "-") {
		if partcfg.IsCommand(os.Args[1]) {
			if err := partcfg.Run(ctx, os.Args[1], os.Args[2:]); err != nil {
				log.Fatalf("%s: %v", os.Args[1], err)
			}
			return true
		}
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n", os.Args[1])
		partcfg.PrintTopLevelUsage(os.Stderr, "partitioner", defaultDesc)
		os.Exit(2)
	}
	return false
}

// loadAndResolve resolves the managed tables from the replicated
// coldfront.partition_config table (falling back to the YAML archiver.tables
// deprecation bridge), writes them back onto cfg, and validates the config.
func loadAndResolve(ctx context.Context, conn *pgx.Conn, cfg *config.Config, cfgPath string) {
	// Resolve managed tables from the replicated coldfront.partition_config
	// table, falling back to the YAML archiver.tables (deprecation bridge).
	tables, fromYAML, err := partcfg.ResolveTables(ctx, conn, cfg.Archiver.Tables)
	if err != nil {
		log.Fatalf("resolve tables: %v", err)
	}
	if len(tables) == 0 {
		log.Fatalf("no tables configured: coldfront.partition_config is empty and no archiver.tables in %s", cfgPath)
	}
	if fromYAML {
		log.Printf("no partition_config rows; using %d table(s) from YAML (deprecated — migrate with `register`/`import`)", len(tables))
	} else {
		log.Printf("loaded %d table(s) from coldfront.partition_config", len(tables))
	}
	cfg.Archiver.Tables = tables
	if err := cfg.Validate(); err != nil {
		log.Fatalf("config invalid: %v", err)
	}
}

// validateTablePeriods checks each table's period syntax + retention>hot
// ordering. Those are PostgreSQL interval semantics, so they're validated
// against the live connection (config.Load can't).
func validateTablePeriods(ctx context.Context, conn *pgx.Conn, cfg *config.Config) {
	for _, t := range cfg.Archiver.Tables {
		if err := partition.ValidatePeriods(ctx, conn, t.HotPeriod, t.RetentionPeriod); err != nil {
			log.Fatalf("[%s] %v", t.SourceTable, err)
		}
	}
}

// runReconcilePass runs one reconcile pass over every configured table and
// fails the run if any table failed.
func runReconcilePass(ctx context.Context, conn *pgx.Conn, cfg *config.Config) {
	mgr := partition.NewManager(conn)
	now := time.Now().UTC()
	failed := 0
	for _, t := range cfg.Archiver.Tables {
		if !reconcileTable(ctx, mgr, t, now) {
			failed++
		}
	}
	if failed > 0 {
		log.Fatalf("%d table(s) failed", failed)
	}
}

// reconcileTable runs one reconcile pass for a single configured table and
// reports whether it succeeded (true) or should count toward the run's failure
// total (false). It selects the single-level vs two-level path off
// t.SubPartition; the ErrBehind self-heal stays a non-fatal WARNING via
// reconcileFailed. main() only sums the failures.
func reconcileTable(ctx context.Context, mgr *partition.Manager, t config.TableConfig, now time.Time) bool {
	// Resolve the real partitioned table: after the archiver's first-run swap the
	// registered name is a VIEW over "_"+name, so premake against the table itself
	// (issue #12). No-op for partition-only tables that were never swapped.
	t.SourceTable = mgr.ResolveSourceTable(ctx, t.SourceSchema, t.SourceTable)
	spec, err := specFromTable(t)
	if err != nil {
		log.Printf("[%s] config: %v", t.SourceTable, err)
		return false
	}
	if t.SubPartition != nil {
		values, err := mgr.ListValues(ctx, t.SubPartition.ValuesSource)
		if err != nil {
			log.Printf("[%s] values_source: %v", spec.Parent, err)
			return false
		}
		if err := partition.RunReconcileTwoLevel(ctx, mgr, spec, values, now, nil); err != nil {
			return !reconcileFailed(spec.Parent, err)
		}
		log.Printf("[%s] reconciled %d sub-tree(s) (premake %d, retention %s)", spec.Parent, len(values), spec.Premake, t.RetentionPeriod)
		return true
	}
	if err := partition.RunReconcile(ctx, mgr, spec, now, nil); err != nil {
		return !reconcileFailed(spec.Parent, err)
	}
	log.Printf("[%s] reconciled (premake %d, retention %s)", spec.Parent, spec.Premake, t.RetentionPeriod)
	return true
}

// specFromTable maps one configured table onto a partition.Spec. The retention
// period is carried verbatim as a PostgreSQL interval literal; the cutoff is
// resolved later in Postgres (Manager.ExpiryCutoff), and interval validity is
// enforced against a live connection (partition.ValidatePeriods), so there is no
// Go-side parsing here. Kept pure + table-tested; main() only wires config + conn.
func specFromTable(t config.TableConfig) (partition.Spec, error) {
	boundary, err := partition.BoundaryFor(t.PartMode, t.IDScheme)
	if err != nil {
		return partition.Spec{}, err
	}
	return partition.Spec{
		Parent:            t.SourceTable,
		Schema:            t.SourceSchema,
		Column:            t.PartitionColumn,
		Period:            t.PartitionPeriod,
		Premake:           t.FuturePartitions,
		RetentionInterval: t.RetentionPeriod,
		Boundary:          boundary,
		Strategy:          t.ExpirationStrategy,
	}, nil
}

// init configures UTC log timestamps on stderr so cron output is unambiguous
// across timezones.
func init() {
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.SetOutput(os.Stderr)
}
