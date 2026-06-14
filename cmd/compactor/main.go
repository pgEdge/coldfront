// Command compactor consolidates an Iceberg table's many small Parquet data
// files into fewer large ones (data-file compaction) for ColdFront cold tiers,
// via apache/iceberg-go's RewriteDataFiles.
//
// It is a SEPARATE Go module from the archiver on purpose: iceberg-go pulls a
// heavy dependency tree (arrow + cloud SDKs) that must never link into the lean
// ~9 MB archiver binary. The compactor reaches every ColdFront backend through
// iceberg-go's gocloud fileio — S3-compatible (SeaweedFS/MinIO), AWS S3, GCS via
// its S3-interop endpoint, and Azure ADLS Gen2 — and serializes every commit
// through the coldfront bakery so it can never 409 against concurrent cold
// writers (formally cleared in docs/formal: a stock-ordering claimant).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5"

	// Register every fileio backend a ColdFront cold tier can live on:
	//   s3 / s3a / s3n / oss        -> S3-compatible, AWS S3, GCS via S3-interop
	//   abfs / abfss / wasb / wasbs -> Azure ADLS Gen2
	_ "github.com/apache/iceberg-go/io/gocloud"
	"github.com/apache/iceberg-go/table"
)

func main() {
	cfgPath := flag.String("config", "", "deployment YAML: DSN + iceberg/S3/azure storage creds")
	tableName := flag.String("table", "", "table to compact, in the configured iceberg namespace (required)")
	targetMB := flag.Int64("target-size-mb", 128, "target output Parquet file size in MiB")
	dryRun := flag.Bool("dry-run", false, "plan only — report what would be compacted, change nothing")
	flag.Parse()

	if *cfgPath == "" || *tableName == "" {
		fmt.Fprintln(os.Stderr, "usage: compactor --config <yaml> --table <name> [--target-size-mb N] [--dry-run]")
		os.Exit(2)
	}
	if err := run(*cfgPath, *tableName, *targetMB<<20, *dryRun); err != nil {
		fmt.Fprintf(os.Stderr, "compactor: %v\n", err)
		os.Exit(1)
	}
}

// run plans compaction for one table and (unless --dry-run) executes the rewrite
// under a bakery claim. Detection self-gates: an empty plan is a clean no-op.
func run(cfgPath, tableName string, targetSize int64, dryRun bool) error {
	ctx := context.Background()
	cfg, err := LoadConfig(cfgPath)
	if err != nil {
		return err
	}
	ns := cfg.Iceberg.Namespace

	cat, err := openCatalog(ctx, cfg)
	if err != nil {
		return fmt.Errorf("connect lakekeeper: %w", err)
	}
	tbl, plan, err := planCompaction(ctx, cat, ns, tableName, targetSize)
	if err != nil {
		return err
	}
	if len(plan.groups) == 0 {
		fmt.Fprintf(os.Stderr, "compactor: %s.%s — nothing to compact (%d files scanned, none below target)\n",
			ns, tableName, plan.plan.TotalInputFiles)
		return nil
	}
	fmt.Fprintf(os.Stderr, "compactor: %s.%s — %d group(s), %d small files -> ~%d (%d MiB in)\n",
		ns, tableName, len(plan.groups), plan.plan.TotalInputFiles, plan.plan.EstOutputFiles, plan.plan.TotalInputBytes>>20)
	if dryRun {
		return nil
	}

	// The bakery claim key MUST be byte-identical to the cold-write path's so the
	// compactor mutually-excludes with concurrent cold writers. The archiver and
	// hook build it as pgx.Identifier{"ice", namespace, table}.Sanitize()
	// (cmd/archiver/main.go iceTable; coldfront--0.1.sql tiered_views.iceberg_table).
	icebergRef := pgx.Identifier{"ice", ns, tableName}.Sanitize()

	conn, err := pgx.Connect(ctx, cfg.Postgres.DSN)
	if err != nil {
		return fmt.Errorf("connect postgres (bakery): %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()

	var res *table.RewriteResult
	err = withBakeryClaim(ctx, conn, icebergRef, func() error {
		var rerr error
		res, rerr = rewrite(ctx, tbl, plan.groups, targetSize)
		return rerr
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "compactor: %s — done: %d files -> %d (%d MiB -> %d MiB)\n",
		icebergRef, res.RemovedDataFiles, res.AddedDataFiles, res.BytesBefore>>20, res.BytesAfter>>20)
	return nil
}
