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
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/vyruss/coldfront/internal/config"
	"github.com/vyruss/coldfront/internal/partition"
)

func main() {
	cfgPath := flag.String("config", "", "path to the YAML config file")
	flag.Parse()
	if *cfgPath == "" {
		log.Fatal("--config is required")
	}

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		log.Fatalf("load config: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, cfg.Postgres.DSN)
	if err != nil {
		log.Fatalf("connect: %v", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("ping: %v", err)
	}

	mgr := partition.NewManager(pool)
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
// retention string. Kept pure + table-tested; main() only wires config + pool.
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
	}, nil
}

// init configures UTC log timestamps on stderr so cron output is unambiguous
// across timezones.
func init() {
	log.SetFlags(log.Ldate | log.Ltime | log.LUTC)
	log.SetOutput(os.Stderr)
}
