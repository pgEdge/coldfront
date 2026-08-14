package main

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/apache/iceberg-go"
	"github.com/apache/iceberg-go/catalog"
	"github.com/apache/iceberg-go/catalog/rest"
	iceio "github.com/apache/iceberg-go/io"
	"github.com/apache/iceberg-go/io/gocloud"
	"github.com/apache/iceberg-go/table"
	"github.com/apache/iceberg-go/table/compaction"
	"github.com/apache/iceberg-go/utils"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/smithy-go/middleware"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

// openCatalog connects to the Lakekeeper REST catalog for the deployment's
// warehouse, handing it the fileio credentials for the configured cold-store
// backend so the table's data files (s3://, gs://, abfs://) can be read+written.
func openCatalog(ctx context.Context, cfg *Config) (*rest.Catalog, error) {
	props, err := cfg.storageProps()
	if err != nil {
		return nil, err
	}
	return rest.NewCatalog(ctx, "lakekeeper", cfg.Iceberg.LakekeeperEndpoint,
		rest.WithWarehouseLocation(cfg.Iceberg.Warehouse),
		rest.WithAdditionalProps(props))
}

// withColdStoreSigning adapts SigV4 signing for an S3-compatible cold store
// reached over TLS (GCS via its S3-interop endpoint), which requires:
//   - Accept-Encoding NOT covered by the signature (Google's frontend rewrites
//     the header before verifying, so a signed value never matches), and
//   - no CRC32 upload checksum (it rides an aws-chunked streaming body the
//     endpoint does not accept); WhenRequired computes checksums only for
//     operations that mandate one.
//
// SeaweedFS/MinIO (plain http) and real AWS S3 (no custom endpoint) verify the
// SDK defaults correctly and are left alone; Azure is not S3. The adapted
// aws.Config rides the context: iceberg-go's gocloud backend prefers a
// caller-supplied config (utils.GetAwsConfig) over building its own, and the
// table's file IO is created lazily with the call-site context, so every
// downstream read/commit inherits it.
func withColdStoreSigning(ctx context.Context, cfg *Config) (context.Context, error) {
	props, err := cfg.storageProps()
	if err != nil {
		return nil, err
	}
	if !strings.HasPrefix(props[iceio.S3EndpointURL], "https://") {
		return ctx, nil
	}
	awscfg, err := gocloud.ParseAWSConfig(ctx, props)
	if err != nil {
		return nil, err
	}
	awscfg.APIOptions = append(awscfg.APIOptions, excludeFromSigning("Accept-Encoding"))
	awscfg.RequestChecksumCalculation = aws.RequestChecksumCalculationWhenRequired
	return utils.WithAwsConfig(ctx, awscfg), nil
}

type ignoredHeadersKey struct{}

// excludeFromSigning returns a middleware installer that hides the named
// headers from the SigV4 signer: removed immediately before the "Signing"
// finalize step, restored immediately after, so they go on the wire unsigned.
func excludeFromSigning(headers ...string) func(*middleware.Stack) error {
	return func(stack *middleware.Stack) error {
		drop := middleware.FinalizeMiddlewareFunc("ExcludeFromSigning",
			func(ctx context.Context, in middleware.FinalizeInput, next middleware.FinalizeHandler) (middleware.FinalizeOutput, middleware.Metadata, error) {
				req, ok := in.Request.(*smithyhttp.Request)
				if !ok {
					return next.HandleFinalize(ctx, in)
				}
				ignored := make(map[string][]string, len(headers))
				for _, h := range headers {
					if v, present := req.Header[h]; present {
						ignored[h] = v
						req.Header.Del(h)
					}
				}
				ctx = middleware.WithStackValue(ctx, ignoredHeadersKey{}, ignored)
				return next.HandleFinalize(ctx, in)
			})
		restore := middleware.FinalizeMiddlewareFunc("RestoreExcludedFromSigning",
			func(ctx context.Context, in middleware.FinalizeInput, next middleware.FinalizeHandler) (middleware.FinalizeOutput, middleware.Metadata, error) {
				req, ok := in.Request.(*smithyhttp.Request)
				if !ok {
					return next.HandleFinalize(ctx, in)
				}
				ignored, _ := middleware.GetStackValue(ctx, ignoredHeadersKey{}).(map[string][]string)
				for h, v := range ignored {
					req.Header[h] = v
				}
				return next.HandleFinalize(ctx, in)
			})
		if err := stack.Finalize.Insert(drop, "Signing", middleware.Before); err != nil {
			return err
		}
		return stack.Finalize.Insert(restore, "Signing", middleware.After)
	}
}

// planResult bundles the rewrite groups with the planner's summary (for logging
// and the no-op decision).
type planResult struct {
	groups  []table.CompactionTaskGroup
	plan    compaction.Plan
	sorted  bool   // tasks are in sort-key order; the rewrite must read serially
	skipped string // non-empty: why the rewrite must leave this table alone
}

// sortKeyProp names the column a table's data files are already ordered by, so a
// rewrite can concatenate them in that order. Set it on tables whose query speed
// depends on row-group pruning; a table without it is rewritten with no ordering
// step and no serial-read constraint.
//
// Without it, iceberg-go's rewrite reads a group's files concurrently and writes
// the stream as it arrives, so the files land in arbitrary order and one output
// row group per junction spans both sides of it. Ordering the files and reading
// them one at a time keeps every junction between adjacent key values, which is
// what leaves the row-group statistics useful. Row group *size* is a separate
// property: iceberg-go cuts groups only by write.parquet.row-group-limit (a row
// count, default 1,048,576) and never reads
// write.parquet.row-group-size-bytes, so a table that wants small groups sets
// the row-count property too.
const sortKeyProp = "coldfront.sort-key"

// sortField returns the schema field named by sortKeyProp. The bool is false when
// the property is absent, which is not an error: an unsorted table has no order
// to preserve. A property naming a column that is not in the schema IS an error,
// because rewriting anyway would scramble the layout it was meant to protect.
//
// Only the leading column of a compound key matters here. Files are ordered by
// it; within one of its values a secondary key never straddles two files.
func sortField(props iceberg.Properties, sc *iceberg.Schema) (iceberg.NestedField, bool, error) {
	name, _, _ := strings.Cut(props[sortKeyProp], ",")
	name = strings.TrimSpace(name)
	if name == "" {
		return iceberg.NestedField{}, false, nil
	}
	field, ok := sc.FindFieldByName(name)
	if !ok {
		return iceberg.NestedField{}, false, fmt.Errorf(
			"%s names column %q, which the table schema does not have", sortKeyProp, name)
	}
	return field, true, nil
}

// orderTasksBySortKey sorts tasks in place by each file's lower bound on field,
// so the rewrite concatenates them in key order.
//
// Any file whose bound is missing or unorderable fails the whole group: a
// best-effort sort would put that file somewhere arbitrary, which is the exact
// scrambling this exists to prevent.
func orderTasksBySortKey(tasks []table.FileScanTask, field iceberg.NestedField) error {
	// Decode every bound up front, because sort's comparator cannot report an
	// error and one that silently answered "not less" would leave the group in
	// an order nobody chose.
	keyed := make([]orderedTask, len(tasks))
	for i, t := range tasks {
		raw, ok := t.File.LowerBoundValues()[field.ID]
		if !ok {
			return fmt.Errorf("file %s has no lower bound for sort column %q",
				t.File.FilePath(), field.Name)
		}
		bound, err := iceberg.LiteralFromBytes(field.Type, raw)
		if err != nil {
			return fmt.Errorf("decode lower bound of %q in %s: %w",
				field.Name, t.File.FilePath(), err)
		}
		if _, ok := lessLiteral(bound, bound); !ok {
			return fmt.Errorf("cannot order sort column %q of type %s", field.Name, field.Type)
		}
		keyed[i] = orderedTask{bound: bound, task: t}
	}
	sort.SliceStable(keyed, func(i, j int) bool {
		less, _ := lessLiteral(keyed[i].bound, keyed[j].bound)
		return less
	})
	for i, k := range keyed {
		tasks[i] = k.task
	}
	return nil
}

// orderedTask pairs a task with the decoded lower bound that positions it.
type orderedTask struct {
	bound iceberg.Literal
	task  table.FileScanTask
}

// lessLiteral orders two lower bounds of the same Iceberg type. The second return
// is false for a pair this cannot order, so the caller declines the rewrite
// rather than guessing.
//
// Every type here is physically an integer or a string, which covers the keys a
// table is sorted by: a cluster id, a primary key, a timestamp, a date, a label.
// Floating-point keys are deliberately absent: nothing ColdFront sorts by is a
// float, and NaN has no total order.
func lessLiteral(a, b iceberg.Literal) (bool, bool) {
	switch av := a.Any().(type) {
	case int32:
		bv, ok := b.Any().(int32)
		return ok && av < bv, ok
	case int64:
		bv, ok := b.Any().(int64)
		return ok && av < bv, ok
	case iceberg.Date:
		bv, ok := b.Any().(iceberg.Date)
		return ok && av < bv, ok
	case iceberg.Time:
		bv, ok := b.Any().(iceberg.Time)
		return ok && av < bv, ok
	case iceberg.Timestamp:
		bv, ok := b.Any().(iceberg.Timestamp)
		return ok && av < bv, ok
	case string:
		bv, ok := b.Any().(string)
		return ok && av < bv, ok
	}
	return false, false
}

// loadTableErr turns a LoadTable failure into the message the operator sees.
// A missing table is the one case worth rewording: the REST catalog's own text
// ("NoSuchTableException: Error getting tabular from catalog") names neither
// the table nor anything actionable. Every other cause keeps its cause chain,
// so a refused connection or a rejected credential still reads as itself.
func loadTableErr(ns, name string, err error) error {
	if errors.Is(err, catalog.ErrNoSuchTable) {
		return fmt.Errorf("table %q not found in catalog", ns+"."+name)
	}
	return fmt.Errorf("load table %s.%s: %w", ns, name, err)
}

// planCompaction loads the table, scans its current snapshot, and bin-packs the
// below-target data files into rewrite groups. This is the detection step: an
// empty plan.groups means every file already meets the target — a clean no-op.
func planCompaction(ctx context.Context, cat *rest.Catalog, ns, name string, targetSize int64) (*table.Table, *planResult, error) {
	tbl, err := cat.LoadTable(ctx, catalog.ToIdentifier(ns, name))
	if err != nil {
		return nil, nil, loadTableErr(ns, name, err)
	}
	sortKey, sorted, err := sortField(tbl.Properties(), tbl.Schema())
	if err != nil {
		return tbl, &planResult{skipped: err.Error()}, nil
	}
	tasks, err := tbl.Scan().PlanFiles(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("plan files for %s.%s: %w", ns, name, err)
	}

	cfg := compaction.DefaultConfig()
	if targetSize > 0 {
		cfg.TargetFileSizeBytes = targetSize
		cfg.MinFileSizeBytes = targetSize * 3 / 4 // a file >= 75% of target is "optimal"
		cfg.MaxFileSizeBytes = targetSize * 9 / 5 // and one > 180% is oversized
	}
	if err := cfg.Validate(); err != nil {
		return nil, nil, fmt.Errorf("compaction config: %w", err)
	}
	plan, err := cfg.PlanCompaction(tasks)
	if err != nil {
		return nil, nil, fmt.Errorf("plan compaction for %s.%s: %w", ns, name, err)
	}

	groups := make([]table.CompactionTaskGroup, len(plan.Groups))
	for i, g := range plan.Groups {
		if sorted {
			if err := orderTasksBySortKey(g.Tasks, sortKey); err != nil {
				return tbl, &planResult{skipped: err.Error()}, nil
			}
		}
		groups[i] = table.CompactionTaskGroup{
			PartitionKey:   g.PartitionKey,
			Tasks:          g.Tasks,
			TotalSizeBytes: g.TotalSizeBytes,
		}
	}
	return tbl, &planResult{groups: groups, plan: plan, sorted: sorted}, nil
}

// rewrite executes the planned compaction as a single atomic rewrite snapshot
// and commits it to the catalog.
//
// MUST be called while the bakery claim for this table is held (see
// withBakeryClaim): iceberg-go commits straight to Lakekeeper, so the held claim
// is what serializes this against concurrent cold writers (no 409). Because
// iceberg-go has no bakery-aware re-stamp patch, the claim is held across the
// WHOLE read->rewrite->commit so the CAS parent is captured under the claim —
// the stock-ordering discipline proved safe in docs/formal (Bakery_v2.cfg).
func rewrite(ctx context.Context, tbl *table.Table, groups []table.CompactionTaskGroup, targetSize int64, sorted bool) (*table.RewriteResult, error) {
	txn := tbl.NewTransaction()
	opts := table.RewriteDataFilesOptions{}
	if targetSize > 0 {
		opts.GroupOptions = []table.CompactionGroupOption{table.WithCompactionTargetFileSize(targetSize)}
	}
	if sorted {
		// One reader, so the ordered files concatenate in that order. With more
		// than one, workers race and the output interleaves them, which is what
		// scrambles the sort order the tasks were just put into.
		opts.GroupOptions = append(opts.GroupOptions, table.WithCompactionScanConcurrency(1))
	}
	res, err := txn.RewriteDataFiles(ctx, groups, opts)
	if err != nil {
		return nil, fmt.Errorf("rewrite data files: %w", err)
	}
	if _, err := txn.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit rewrite: %w", err)
	}
	return res, nil
}
