package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/apache/iceberg-go/utils"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

// TestWithColdStoreSigning_GCS: a TLS S3-compatible endpoint (GCS interop) gets
// an aws.Config with the signing-exclusion middleware pinned onto the context.
func TestWithColdStoreSigning_GCS(t *testing.T) {
	c := &Config{}
	c.S3.Endpoint = "storage.googleapis.com"
	c.S3.UseSSL = true
	c.S3.AccessKey = "GOOGTESTHMAC"
	c.S3.SecretKey = "secret"

	ctx, err := withColdStoreSigning(context.Background(), c)
	if err != nil {
		t.Fatal(err)
	}
	awscfg := utils.GetAwsConfig(ctx)
	if awscfg == nil {
		t.Fatal("expected an aws.Config on the context for a TLS S3 endpoint")
	}
	if len(awscfg.APIOptions) == 0 {
		t.Fatal("expected the signing-exclusion middleware in APIOptions")
	}
}

// TestWithColdStoreSigning_NoOverride: the cases that must be left on SDK
// defaults — plain-http S3 (SeaweedFS/MinIO), no-endpoint AWS native, and
// Azure — return the context unchanged (no aws.Config injected).
func TestWithColdStoreSigning_NoOverride(t *testing.T) {
	cases := map[string]func(*Config){
		"seaweedfs-http": func(c *Config) {
			c.S3.Endpoint = "seaweedfs:8333"
			c.S3.AccessKey = "admin"
			c.S3.SecretKey = "adminsecret"
		},
		"aws-native-no-endpoint": func(c *Config) {
			c.S3.Region = "eu-west-1"
			c.S3.AccessKey = "AKIA"
			c.S3.SecretKey = "secret"
		},
		"azure": func(c *Config) {
			c.Azure.ConnectionString = "DefaultEndpointsProtocol=https;AccountName=a;AccountKey=a2V5;EndpointSuffix=core.windows.net"
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			c := &Config{}
			setup(c)
			ctx, err := withColdStoreSigning(context.Background(), c)
			if err != nil {
				t.Fatal(err)
			}
			if utils.GetAwsConfig(ctx) != nil {
				t.Fatalf("%s must not inject an aws.Config (signing workaround is GCS-only)", name)
			}
		})
	}
}

// signedHeadersOf extracts the SignedHeaders list from a SigV4 Authorization
// header captured by the test server.
func signedHeadersOf(t *testing.T, auth string) string {
	t.Helper()
	m := regexp.MustCompile(`SignedHeaders=([^,]+)`).FindStringSubmatch(auth)
	if m == nil {
		t.Fatalf("no SignedHeaders in Authorization: %q", auth)
	}
	return m[1]
}

// getObjectVia performs one GetObject against a capture server through a client
// built with the given API options, returning the received Authorization and
// Accept-Encoding headers.
func getObjectVia(t *testing.T, apiOpts ...func(*aws.Config)) (auth, acceptEncoding string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		acceptEncoding = r.Header.Get("Accept-Encoding")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	cfg := aws.Config{
		Region: "us-east-1",
		Credentials: aws.CredentialsProviderFunc(func(context.Context) (aws.Credentials, error) {
			return aws.Credentials{AccessKeyID: "k", SecretAccessKey: "s"}, nil
		}),
	}
	for _, o := range apiOpts {
		o(&cfg)
	}
	client := s3.NewFromConfig(cfg, func(o *s3.Options) {
		o.BaseEndpoint = aws.String(srv.URL)
		o.UsePathStyle = true
	})
	_, err := client.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String("b"), Key: aws.String("k"),
	})
	if err != nil {
		t.Fatalf("GetObject: %v", err)
	}
	return auth, acceptEncoding
}

// TestExcludeFromSigning_AcceptEncoding is the behavioral proof: with the
// middleware, a GetObject sends Accept-Encoding on the wire but keeps it OUT of
// the SigV4 SignedHeaders list; without it, the SDK signs the header — exactly
// what GCS's S3-interop endpoint rejects with 403 SignatureDoesNotMatch.
func TestExcludeFromSigning_AcceptEncoding(t *testing.T) {
	// Stock SDK: Accept-Encoding is signed (the bug's precondition).
	auth, _ := getObjectVia(t)
	if !strings.Contains(signedHeadersOf(t, auth), "accept-encoding") {
		t.Skip("SDK no longer signs Accept-Encoding; workaround obsolete")
	}

	// With the exclusion middleware: sent, but not signed.
	auth, acceptEncoding := getObjectVia(t, func(cfg *aws.Config) {
		cfg.APIOptions = append(cfg.APIOptions, excludeFromSigning("Accept-Encoding"))
	})
	if strings.Contains(signedHeadersOf(t, auth), "accept-encoding") {
		t.Fatalf("Accept-Encoding still signed: %s", signedHeadersOf(t, auth))
	}
	if acceptEncoding == "" {
		t.Fatal("Accept-Encoding missing from the wire (must be restored after signing)")
	}
}
