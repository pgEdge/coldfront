package main

import (
	"context"
	"fmt"
	"strings"

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
	groups []table.CompactionTaskGroup
	plan   compaction.Plan
}

// planCompaction loads the table, scans its current snapshot, and bin-packs the
// below-target data files into rewrite groups. This is the detection step: an
// empty plan.groups means every file already meets the target — a clean no-op.
func planCompaction(ctx context.Context, cat *rest.Catalog, ns, name string, targetSize int64) (*table.Table, *planResult, error) {
	tbl, err := cat.LoadTable(ctx, catalog.ToIdentifier(ns, name))
	if err != nil {
		return nil, nil, fmt.Errorf("load table %s.%s: %w", ns, name, err)
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
	return tbl, &planResult{groups: groups, plan: plan}, nil
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
func rewrite(ctx context.Context, tbl *table.Table, groups []table.CompactionTaskGroup, targetSize int64) (*table.RewriteResult, error) {
	txn := tbl.NewTransaction()
	opts := table.RewriteDataFilesOptions{}
	if targetSize > 0 {
		opts.GroupOptions = []table.CompactionGroupOption{table.WithCompactionTargetFileSize(targetSize)}
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
