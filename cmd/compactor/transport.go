package main

import (
	"context"
	"strings"

	iceio "github.com/apache/iceberg-go/io"
	"github.com/apache/iceberg-go/io/gocloud"
	"github.com/apache/iceberg-go/utils"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/smithy-go/middleware"
	smithyhttp "github.com/aws/smithy-go/transport/http"
)

// withColdStoreSigning fixes SigV4 signing for an S3-compatible cold store
// reached over TLS (GCS via its S3-interop endpoint). aws-sdk-go-v2 signs the
// Accept-Encoding header; Google's frontend rewrites that header before
// signature verification, so every request fails with 403
// SignatureDoesNotMatch. The fix is the SDK's documented workaround: strip
// Accept-Encoding just before the signer runs and restore it right after, so
// the header is sent but never signed. SeaweedFS/MinIO (plain http) and real
// AWS S3 (no custom endpoint) verify the signed header correctly and are left
// on SDK defaults; Azure is not S3.
//
// The tweaked config rides the context: iceberg-go's gocloud backend prefers a
// caller-supplied aws.Config (utils.GetAwsConfig) over building its own, and
// the table's file IO is created lazily with the call-site context, so every
// downstream read/commit inherits it.
func withColdStoreSigning(ctx context.Context, cfg *Config) (context.Context, error) {
	props, err := cfg.storageProps()
	if err != nil {
		return nil, err
	}
	// Only the TLS S3-compatible custom-endpoint case (GCS) needs the workaround.
	if !strings.HasPrefix(props[iceio.S3EndpointURL], "https://") {
		return ctx, nil
	}
	awscfg, err := gocloud.ParseAWSConfig(ctx, props)
	if err != nil {
		return nil, err
	}
	awscfg.APIOptions = append(awscfg.APIOptions, excludeFromSigning("Accept-Encoding"))
	// Uploads: the SDK's default CRC32 trailer checksum rides an aws-chunked
	// streaming body, which GCS rejects the same way. WhenRequired skips it for
	// operations that don't mandate a checksum.
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
