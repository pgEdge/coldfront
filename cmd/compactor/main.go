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
	"time"

	"github.com/jackc/pgx/v5"

	// Register every fileio backend a ColdFront cold tier can live on:
	//   s3 / s3a / s3n / oss        -> S3-compatible, AWS S3, GCS via S3-interop
	//   abfs / abfss / wasb / wasbs -> Azure ADLS Gen2
	"github.com/apache/iceberg-go/catalog/rest"
	_ "github.com/apache/iceberg-go/io/gocloud"
	"github.com/apache/iceberg-go/table"
)

// runOpts is the parsed CLI: compaction always runs (a no-op when nothing is below
// target); --expire-snapshots and --orphans add opt-in reclaim steps.
type runOpts struct {
	targetSize int64
	dryRun     bool
	expire     bool
	retainLast int
	olderThan  time.Duration
	keepFiles  bool
	orphans    bool
	orphanAge  time.Duration
}

func main() {
	cfgPath := flag.String("config", "", "deployment YAML: DSN + iceberg/S3/azure storage creds")
	tableName := flag.String("table", "", "table in the configured iceberg namespace (required)")
	targetMB := flag.Int64("target-size-mb", 128, "compaction: target output Parquet file size in MiB")
	dryRun := flag.Bool("dry-run", false, "plan only — report what would change, change nothing")
	expire := flag.Bool("expire-snapshots", false, "also expire old snapshots and reclaim the files they alone pinned")
	retainLast := flag.Int("expire-retain-last", 1, "with --expire-snapshots: keep at least this many most-recent snapshots (a floor, not a target)")
	olderThan := flag.Duration("expire-older-than", 168*time.Hour, "with --expire-snapshots: expire snapshots older than this, keeping --expire-retain-last (default 7d; lower it to reclaim compaction bloat sooner)")
	keepFiles := flag.Bool("expire-keep-files", false, "with --expire-snapshots: expire metadata only, leave freed files for an --orphans pass (iceberg-go WithPostCommit(false))")
	orphans := flag.Bool("orphans", false, "also delete orphan files (under the table location, referenced by no retained snapshot)")
	orphanAge := flag.Duration("orphan-age", 72*time.Hour, "with --orphans: only delete files older than this (in-flight-write safety; never 0 in production)")
	flag.Parse()

	if *cfgPath == "" || *tableName == "" {
		fmt.Fprintln(os.Stderr, "usage: compactor --config <yaml> --table <name> [--target-size-mb N] [--dry-run]"+
			" [--expire-snapshots [--expire-retain-last N]] [--orphans [--orphan-age D]]")
		os.Exit(2)
	}
	o := runOpts{
		targetSize: *targetMB << 20,
		dryRun:     *dryRun,
		expire:     *expire,
		retainLast: *retainLast,
		olderThan:  *olderThan,
		keepFiles:  *keepFiles,
		orphans:    *orphans,
		orphanAge:  *orphanAge,
	}
	if err := run(*cfgPath, *tableName, o); err != nil {
		fmt.Fprintf(os.Stderr, "compactor: %v\n", err)
		os.Exit(1)
	}
}

// run executes the requested maintenance for one table: compaction (always; a no-op
// when nothing is below target), then optional snapshot expiry and orphan-file deletion.
// Each mutating step runs under the bakery claim; a pure --dry-run mutates nothing and
// takes no claim.
func run(cfgPath, tableName string, o runOpts) error {
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

	// The bakery claim key MUST be byte-identical to the cold-write path's so every
	// mutating step mutually-excludes with concurrent cold writers. The archiver and
	// hook build it as pgx.Identifier{"ice", namespace, table}.Sanitize()
	// (cmd/archiver/main.go iceTable; coldfront--0.1.sql tiered_views.iceberg_table).
	icebergRef := pgx.Identifier{"ice", ns, tableName}.Sanitize()

	// One PG connection, shared across each step's bakery claim, opened lazily — a
	// pure dry-run never needs it.
	var conn *pgx.Conn
	defer func() {
		if conn != nil {
			_ = conn.Close(ctx)
		}
	}()
	claim := func(fn func() error) error {
		if conn == nil {
			c, cerr := pgx.Connect(ctx, cfg.Postgres.DSN)
			if cerr != nil {
				return fmt.Errorf("connect postgres (bakery): %w", cerr)
			}
			conn = c
		}
		return withBakeryClaim(ctx, conn, icebergRef, fn)
	}

	if err := doCompaction(ctx, cat, ns, tableName, o, claim); err != nil {
		return err
	}
	if o.expire {
		if err := doExpire(ctx, cat, ns, tableName, o, claim); err != nil {
			return err
		}
	}
	if o.orphans {
		if err := doOrphans(ctx, cat, ns, tableName, o, claim); err != nil {
			return err
		}
	}
	return nil
}

// doCompaction plans + (unless dry-run) rewrites below-target files under one claim.
// Detection self-gates: an empty plan is a clean no-op.
func doCompaction(ctx context.Context, cat *rest.Catalog, ns, tableName string, o runOpts, claim func(func() error) error) error {
	tbl, plan, err := planCompaction(ctx, cat, ns, tableName, o.targetSize)
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
	if o.dryRun {
		return nil
	}
	var res *table.RewriteResult
	if err := claim(func() error {
		var rerr error
		res, rerr = rewrite(ctx, tbl, plan.groups, o.targetSize)
		return rerr
	}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "compactor: %s.%s — compacted: %d files -> %d (%d MiB -> %d MiB)\n",
		ns, tableName, res.RemovedDataFiles, res.AddedDataFiles, res.BytesBefore>>20, res.BytesAfter>>20)
	return nil
}

// doExpire expires all but the most-recent --expire-retain-last snapshots under a claim.
func doExpire(ctx context.Context, cat *rest.Catalog, ns, tableName string, o runOpts, claim func(func() error) error) error {
	tbl, err := loadTable(ctx, cat, ns, tableName)
	if err != nil {
		return err
	}
	have := len(tbl.Metadata().Snapshots())
	if o.dryRun {
		fmt.Fprintf(os.Stderr, "compactor: %s.%s — %d snapshot(s); would retain the most recent %d\n",
			ns, tableName, have, o.retainLast)
		return nil
	}
	var expired int
	if err := claim(func() error {
		var eerr error
		expired, eerr = expireSnapshots(ctx, tbl, o.retainLast, o.olderThan, !o.keepFiles)
		return eerr
	}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "compactor: %s.%s — expired %d snapshot(s), retained %d\n",
		ns, tableName, expired, o.retainLast)
	return nil
}

// doOrphans deletes orphan files older than --orphan-age under a claim (dry-run reports only).
func doOrphans(ctx context.Context, cat *rest.Catalog, ns, tableName string, o runOpts, claim func(func() error) error) error {
	tbl, err := loadTable(ctx, cat, ns, tableName)
	if err != nil {
		return err
	}
	if o.dryRun {
		n, derr := deleteOrphans(ctx, tbl, o.orphanAge, true)
		if derr != nil {
			return derr
		}
		fmt.Fprintf(os.Stderr, "compactor: %s.%s — %d orphan file(s) older than %s would be deleted\n",
			ns, tableName, n, o.orphanAge)
		return nil
	}
	var deleted int
	if err := claim(func() error {
		var oerr error
		deleted, oerr = deleteOrphans(ctx, tbl, o.orphanAge, false)
		return oerr
	}); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "compactor: %s.%s — deleted %d orphan file(s) older than %s\n",
		ns, tableName, deleted, o.orphanAge)
	return nil
}
