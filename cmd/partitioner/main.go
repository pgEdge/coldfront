// Command partitioner is the standalone native-partition manager: for each
// managed table it premakes the forward window of partitions and detaches +
// drops those past retention, against stock PostgreSQL — no cold-tier / Iceberg
// dependency. One reconcile pass per invocation; run it from cron. Config is a
// YAML file (--config) holding the Postgres DSN and per-table partition
// settings; any iceberg/s3 sections are ignored here.
package main

import (
	"context"
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

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	const defaultDesc = "run one partition-maintenance reconcile pass"
	// Top-level help / overview — no args, or help/-h/--help — lists the
	// management subcommands so they are discoverable.
	if len(os.Args) < 2 || os.Args[1] == "help" || os.Args[1] == "-h" || os.Args[1] == "--help" {
		partcfg.PrintTopLevelUsage(os.Stdout, "partitioner", defaultDesc)
		return
	}
	// A management subcommand routes to the shared CLI; with no subcommand the
	// partitioner does its default reconcile run (--config below).
	if !strings.HasPrefix(os.Args[1], "-") {
		if partcfg.IsCommand(os.Args[1]) {
			if err := partcfg.Run(ctx, os.Args[1], os.Args[2:]); err != nil {
				log.Fatalf("%s: %v", os.Args[1], err)
			}
			return
		}
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n", os.Args[1])
		partcfg.PrintTopLevelUsage(os.Stderr, "partitioner", defaultDesc)
		os.Exit(2)
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

	// Resolve managed tables from the replicated coldfront.partition_config
	// table, falling back to the YAML archiver.tables (deprecation bridge).
	tables, fromYAML, err := partcfg.ResolveTables(ctx, conn, cfg.Archiver.Tables)
	if err != nil {
		log.Fatalf("resolve tables: %v", err)
	}
	if len(tables) == 0 {
		log.Fatalf("no tables configured: coldfront.partition_config is empty and no archiver.tables in %s", *cfgPath)
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

	mgr := partition.NewManager(conn)
	now := time.Now().UTC()
	failed := 0
	for _, t := range cfg.Archiver.Tables {
		spec, err := specFromTable(t)
		if err != nil {
			log.Printf("[%s] config: %v", t.SourceTable, err)
			failed++
			continue
		}
		if t.SubPartition != nil {
			values, err := mgr.ListValues(ctx, t.SubPartition.ValuesSource)
			if err != nil {
				log.Printf("[%s] values_source: %v", spec.Parent, err)
				failed++
				continue
			}
			if err := partition.RunReconcileTwoLevel(ctx, mgr, spec, values, now, nil); err != nil {
				log.Printf("[%s] reconcile: %v", spec.Parent, err)
				failed++
				continue
			}
			log.Printf("[%s] reconciled %d sub-tree(s) (premake %d, retention %s)", spec.Parent, len(values), spec.Premake, t.RetentionPeriod)
			continue
		}
		if err := partition.RunReconcile(ctx, mgr, spec, now, nil); err != nil {
			log.Printf("[%s] reconcile: %v", spec.Parent, err)
			failed++
			continue
		}
		log.Printf("[%s] reconciled (premake %d, retention %s)", spec.Parent, spec.Premake, t.RetentionPeriod)
	}
	if failed > 0 {
		log.Fatalf("%d table(s) failed", failed)
	}
}

// specFromTable maps one configured table onto a partition.Spec, parsing the
// retention string. Kept pure + table-tested; main() only wires config + conn.
func specFromTable(t config.TableConfig) (partition.Spec, error) {
	retention, err := partition.ParseRetention(t.RetentionPeriod)
	if err != nil {
		return partition.Spec{}, err
	}
	boundary, err := partition.BoundaryFor(t.PartMode, t.IDScheme)
	if err != nil {
		return partition.Spec{}, err
	}
	return partition.Spec{
		Parent:    t.SourceTable,
		Schema:    t.SourceSchema,
		Column:    t.PartitionColumn,
		Period:    t.PartitionPeriod,
		Premake:   t.FuturePartitions,
		Retention: retention,
		Boundary:  boundary,
		Strategy:  t.ExpirationStrategy,
	}, nil
}

// init configures UTC log timestamps on stderr so cron output is unambiguous
// across timezones.
func init() {
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.SetOutput(os.Stderr)
}
