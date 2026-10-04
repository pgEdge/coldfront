package main

import (
	"context"
	"fmt"
	"time"

	"github.com/apache/iceberg-go/catalog"
	"github.com/apache/iceberg-go/catalog/rest"
	"github.com/apache/iceberg-go/table"
)

// loadTable fetches the table's current state from the catalog. Each maintenance
// step reloads, so a step always operates on (and asserts against) the freshest head.
func loadTable(ctx context.Context, cat *rest.Catalog, ns, name string) (*table.Table, error) {
	tbl, err := cat.LoadTable(ctx, catalog.ToIdentifier(ns, name))
	if err != nil {
		return nil, fmt.Errorf("load table %s.%s: %w", ns, name, err)
	}
	return tbl, nil
}

// expireSnapshots drops snapshots older than olderThan (Iceberg expiry is age-driven; the
// current snapshot is always kept, and retainLast is a FLOOR, keep at least this many,
// not a target). When deleteFiles is true (the default) it also deletes the manifests,
// manifest lists, and data files that ONLY those expired snapshots referenced — which is
// how the small Parquet files a prior compaction superseded are finally reclaimed
// (they stay pinned by the pre-compaction snapshot until it is expired). When false (the
// --expire-keep-files operator option, iceberg-go's WithPostCommit(false)), the metadata is
// expired but the now-unreferenced files are left for a separate deleteOrphans pass. It is
// an Iceberg commit guarded by AssertRefSnapshotID, so it MUST run while the bakery claim is
// held: the same stock-ordering discipline the compaction rewrite uses (docs/formal). In dryRun it
// stops at the staged metadata, which iceberg-go builds in memory and writes nowhere.
// Returns the number of snapshots expired and the number kept, both counted from the
// resulting metadata, so the table's own history.expire.* properties and the ref's
// overrides are reflected.
func expireSnapshots(ctx context.Context, tbl *table.Table, retainLast int, olderThan time.Duration, deleteFiles, dryRun bool) (expired, kept int, err error) {
	before := len(tbl.Metadata().Snapshots())
	txn := tbl.NewTransaction()
	if err := txn.ExpireSnapshots(
		table.WithRetainLast(retainLast),
		table.WithOlderThan(olderThan),
		table.WithPostCommit(deleteFiles),
	); err != nil {
		return 0, 0, fmt.Errorf("expire snapshots: %w", err)
	}
	var after *table.Table
	if dryRun {
		staged, err := txn.StagedTable()
		if err != nil {
			return 0, 0, fmt.Errorf("stage expire snapshots: %w", err)
		}
		after = staged.Table
	} else if after, err = txn.Commit(ctx); err != nil {
		return 0, 0, fmt.Errorf("commit expire snapshots: %w", err)
	}
	kept = len(after.Metadata().Snapshots())
	return before - kept, kept, nil
}

// deleteOrphans removes files under the table's location that no retained snapshot
// references AND that are older than minAge — the in-flight-write safety window
// (iceberg-go defaults to 72h; never pass 0 in production, or a concurrent writer's
// freshly-staged parquet could be reaped). It deletes physical files directly (NOT an
// Iceberg commit), but runs under the bakery claim so it cannot race a concurrent cold
// writer for the same table. dryRun reports candidates without deleting. Returns the
// orphan-file count (found, in dry-run; deleted, otherwise).
func deleteOrphans(ctx context.Context, tbl *table.Table, minAge time.Duration, dryRun bool) (int, error) {
	res, err := tbl.DeleteOrphanFiles(ctx,
		table.WithFilesOlderThan(minAge),
		table.WithDryRun(dryRun))
	if err != nil {
		return 0, fmt.Errorf("delete orphan files: %w", err)
	}
	if dryRun {
		return len(res.OrphanFileLocations), nil
	}
	return len(res.DeletedFiles), nil
}
