package main

import (
	"context"
	"errors"
	"fmt"
	"iter"
	"strings"

	"github.com/apache/arrow-go/v18/arrow"
	"github.com/apache/arrow-go/v18/arrow/array"
	"github.com/apache/arrow-go/v18/arrow/compute"
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
	sorted  bool                // the table declares a sort key: merge, do not concatenate
	sortKey iceberg.NestedField // the column to merge on, when sorted
	skipped string              // non-empty: why the rewrite must leave this table alone
}

// sortKeyProp names the column a table's data files are ordered by. Set it on
// tables whose query speed depends on row-group pruning; a table without it is
// rewritten as it arrives, with no ordering step.
//
// With it, a rewrite merges each group on that column rather than appending its
// files, so every output row group spans adjacent key values and its statistics
// stay useful. Row group *size* is a separate property: iceberg-go cuts groups
// only by write.parquet.row-group-limit (a row count, default 1,048,576) and
// never reads write.parquet.row-group-size-bytes, so a table that wants small
// groups sets the row-count property too.
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
		groups[i] = table.CompactionTaskGroup{
			PartitionKey:   g.PartitionKey,
			Tasks:          g.Tasks,
			TotalSizeBytes: g.TotalSizeBytes,
		}
	}
	return tbl, &planResult{groups: groups, plan: plan, sorted: sorted, sortKey: sortKey}, nil
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
func rewrite(ctx context.Context, tbl *table.Table, p *planResult, targetSize int64) (*table.RewriteResult, error) {
	if p.sorted {
		return rewriteSorted(ctx, tbl, p.groups, p.sortKey, targetSize)
	}
	txn := tbl.NewTransaction()
	opts := table.RewriteDataFilesOptions{}
	if targetSize > 0 {
		opts.GroupOptions = []table.CompactionGroupOption{table.WithCompactionTargetFileSize(targetSize)}
	}
	res, err := txn.RewriteDataFiles(ctx, p.groups, opts)
	if err != nil {
		return nil, fmt.Errorf("rewrite data files: %w", err)
	}
	if _, err := txn.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit rewrite: %w", err)
	}
	return res, nil
}

// rewriteSorted compacts a sorted table by merging each group on its sort column
// instead of concatenating it, and stages every group on one rewrite snapshot.
//
// Concatenation preserves order only while a group's input ranges are disjoint,
// which is true of a table built by one sorted pass and false as soon as writes
// land clustered: a batch cold write orders its own rows, so each new file spans
// the whole of key space and appending two of them interleaves two sorted runs.
// The cost of that is a run count, and a probe reads at least one row group per
// run, so bounding file count without merging the runs bounds the wrong thing.
//
// This drives the same two halves iceberg-go's own group executor drives, with a
// sort between them, which is the seam its documentation points distributed
// coordinators at. Reading through Scan.ReadTasks applies the position deletes a
// cold UPDATE or DELETE left behind, and writing through WriteRecords produces
// files with field ids, statistics and the table's row-group limit. Neither is
// true of touching the Parquet directly.
func rewriteSorted(ctx context.Context, tbl *table.Table, groups []table.CompactionTaskGroup,
	field iceberg.NestedField, targetSize int64) (*table.RewriteResult, error) {
	txn := tbl.NewTransaction()
	rw := txn.NewRewrite(nil)
	res := &table.RewriteResult{}

	for _, g := range groups {
		gr, err := mergeGroup(ctx, tbl, g, field, targetSize)
		if err != nil {
			return nil, err
		}
		rw.ApplyResult(gr)
		res.RewrittenGroups++
		res.AddedDataFiles += len(gr.NewDataFiles)
		res.RemovedDataFiles += len(gr.OldDataFiles)
		res.RemovedPositionDeleteFiles += len(gr.SafePosDeletes)
		res.BytesBefore += gr.BytesBefore
		res.BytesAfter += gr.BytesAfter
	}

	if err := rw.Commit(ctx); err != nil {
		return nil, fmt.Errorf("stage sorted rewrite: %w", err)
	}
	if _, err := txn.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit rewrite: %w", err)
	}
	return res, nil
}

// mergeGroup reads one group with its deletes applied, sorts it by field, and
// writes the result back as new data files.
//
// A group is bin-packed to the file-size target, so holding one is bounded by
// that target rather than by the table. Nulls sort last and therefore land
// together: a row another engine appended carries no assignment, and keeping
// those rows contiguous is what lets a probe read them in proportion to their own
// size instead of scattering them through every row group.
func mergeGroup(ctx context.Context, tbl *table.Table, group table.CompactionTaskGroup,
	field iceberg.NestedField, targetSize int64) (table.CompactionGroupResult, error) {
	var zero table.CompactionGroupResult

	if len(group.Tasks) == 0 {
		return table.CompactionGroupResult{PartitionKey: group.PartitionKey}, nil
	}

	// One reader: the sort below decides the order, so a concurrent read would
	// only shuffle its input to no effect.
	schema, records, err := tbl.Scan(table.WitMaxConcurrency(1)).ReadTasks(ctx, group.Tasks)
	if err != nil {
		return zero, fmt.Errorf("read group %q: %w", group.PartitionKey, err)
	}

	var batches []arrow.RecordBatch
	defer func() {
		for _, b := range batches {
			b.Release()
		}
	}()
	for rec, err := range records {
		if err != nil {
			return zero, fmt.Errorf("read group %q: %w", group.PartitionKey, err)
		}
		rec.Retain()
		batches = append(batches, rec)
	}
	if len(batches) == 0 {
		return table.CompactionGroupResult{PartitionKey: group.PartitionKey}, nil
	}

	idx, ok := schema.FieldIndices(field.Name), true
	if len(idx) != 1 {
		ok = false
	}
	if !ok {
		return zero, fmt.Errorf("sort column %q is not a single column of the read schema", field.Name)
	}

	unsorted := array.NewTableFromRecords(schema, batches)
	defer unsorted.Release()

	order, err := compute.SortIndicesTable(ctx, unsorted, []compute.SortKey{{
		ColumnIndex:   idx[0],
		Order:         compute.SortOrderAscending,
		NullPlacement: compute.SortNullsAtEnd,
	}})
	if err != nil {
		return zero, fmt.Errorf("sort group %q by %q: %w", group.PartitionKey, field.Name, err)
	}
	defer order.Release()

	taken, err := compute.Take(ctx, *compute.DefaultTakeOptions(),
		compute.NewDatumWithoutOwning(unsorted), compute.NewDatumWithoutOwning(order))
	if err != nil {
		return zero, fmt.Errorf("reorder group %q: %w", group.PartitionKey, err)
	}
	defer taken.Release()
	sorted := taken.(*compute.TableDatum).Value

	writeOpts := []table.WriteRecordOption{table.WithClusteredWrite()}
	if targetSize > 0 {
		writeOpts = append(writeOpts, table.WithTargetFileSize(targetSize))
	}

	rdr := array.NewTableReader(sorted, 0)
	defer rdr.Release()

	var (
		newFiles   []iceberg.DataFile
		bytesAfter int64
	)
	for df, err := range table.WriteRecords(ctx, tbl, schema, recordSeq(rdr), writeOpts...) {
		if err != nil {
			return zero, fmt.Errorf("write merged files for group %q: %w", group.PartitionKey, err)
		}
		newFiles = append(newFiles, df)
		bytesAfter += df.FileSizeBytes()
	}

	oldFiles := make([]iceberg.DataFile, 0, len(group.Tasks))
	for _, t := range group.Tasks {
		oldFiles = append(oldFiles, t.File)
	}
	return table.CompactionGroupResult{
		PartitionKey:   group.PartitionKey,
		OldDataFiles:   oldFiles,
		NewDataFiles:   newFiles,
		SafePosDeletes: table.CollectSafePositionDeletes(group.Tasks),
		BytesBefore:    group.TotalSizeBytes,
		BytesAfter:     bytesAfter,
	}, nil
}

// recordSeq adapts an Arrow table reader to the iterator WriteRecords consumes.
func recordSeq(rdr array.RecordReader) iter.Seq2[arrow.RecordBatch, error] {
	return func(yield func(arrow.RecordBatch, error) bool) {
		for rdr.Next() {
			if !yield(rdr.RecordBatch(), nil) {
				return
			}
		}
		if err := rdr.Err(); err != nil {
			yield(nil, err)
		}
	}
}
