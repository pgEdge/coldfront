package main

import (
	"context"
	"testing"

	iceio "github.com/apache/iceberg-go/io"
	"github.com/apache/iceberg-go/utils"
)

func TestSplitSchemaTable(t *testing.T) {
	cases := []struct{ arg, schema, table string }{
		{"events", "public", "events"},
		{"myapp.events", "myapp", "events"},
		{"analytics.events", "analytics", "events"},
	}
	for _, c := range cases {
		s, tbl := splitSchemaTable(c.arg)
		if s != c.schema || tbl != c.table {
			t.Errorf("splitSchemaTable(%q) = (%q, %q); want (%q, %q)", c.arg, s, tbl, c.schema, c.table)
		}
	}
}

func TestStorageProps_S3Compat(t *testing.T) {
	// SeaweedFS/MinIO: explicit http endpoint, path-style addressing.
	c := &Config{}
	c.S3.Endpoint = "seaweedfs:8333"
	c.S3.AccessKey = "admin"
	c.S3.SecretKey = "adminsecret"
	c.S3.Region = "us-east-1"
	c.S3.URLStyle = "path"
	p, err := c.storageProps()
	if err != nil {
		t.Fatal(err)
	}
	if got := p[iceio.S3EndpointURL]; got != "http://seaweedfs:8333" {
		t.Fatalf("endpoint = %q", got)
	}
	if p[iceio.S3AccessKeyID] != "admin" || p[iceio.S3SecretAccessKey] != "adminsecret" {
		t.Fatalf("creds not mapped: %v", p)
	}
	if got := p[iceio.S3ForceVirtualAddressing]; got != "false" {
		t.Fatalf("path-style must be force-virtual=false, got %q", got)
	}
}

func TestStorageProps_GCSInterop(t *testing.T) {
	// GCS via S3-interop: TLS endpoint at storage.googleapis.com, HMAC keys.
	c := &Config{}
	c.S3.Endpoint = "storage.googleapis.com"
	c.S3.UseSSL = true
	c.S3.AccessKey = "GOOGTESTHMAC"
	c.S3.SecretKey = "secret"
	p, err := c.storageProps()
	if err != nil {
		t.Fatal(err)
	}
	if got := p[iceio.S3EndpointURL]; got != "https://storage.googleapis.com" {
		t.Fatalf("gcs-interop endpoint = %q", got)
	}
}

func TestStorageProps_AWSNative(t *testing.T) {
	// Real AWS S3: no endpoint (aws-sdk native vhost+https), region only.
	c := &Config{}
	c.S3.Region = "ap-south-2"
	c.S3.AccessKey = "AKIAEXAMPLE"
	c.S3.SecretKey = "secret"
	p, err := c.storageProps()
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := p[iceio.S3EndpointURL]; ok {
		t.Fatalf("AWS native must set no endpoint, got %q", p[iceio.S3EndpointURL])
	}
	if p[iceio.S3Region] != "ap-south-2" {
		t.Fatalf("region = %q", p[iceio.S3Region])
	}
}

func TestStorageProps_VendedEmptyConfig(t *testing.T) {
	// Vended deployment: no s3/azure creds in YAML. storageProps must set NO
	// credential keys, so iceberg-go's vended storage-credentials (merged last)
	// are not shadowed by empty static keys, and its Azure shared-key branch does
	// not preempt a vended SAS.
	c := &Config{}
	c.Iceberg.Warehouse = "wh"
	c.Iceberg.LakekeeperEndpoint = "http://lk:8181/catalog"
	p, err := c.storageProps()
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{
		iceio.S3AccessKeyID, iceio.S3SecretAccessKey,
		iceio.ADLSSharedKeyAccountName, iceio.ADLSSharedKeyAccountKey,
	} {
		if _, ok := p[k]; ok {
			t.Fatalf("vended config must not set %q, got %q", k, p[k])
		}
	}
}

func TestStorageProps_Azure(t *testing.T) {
	c := &Config{}
	c.Azure.ConnectionString = "DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=a2V5cGFkZGluZw==;EndpointSuffix=core.windows.net"
	p, err := c.storageProps()
	if err != nil {
		t.Fatal(err)
	}
	if got := p[iceio.ADLSSharedKeyAccountName]; got != "acct" {
		t.Fatalf("account name = %q", got)
	}
	// The trailing '==' base64 padding must survive the parse.
	if got := p[iceio.ADLSSharedKeyAccountKey]; got != "a2V5cGFkZGluZw==" {
		t.Fatalf("account key = %q", got)
	}
}

func TestStorageProps_AzureMalformed(t *testing.T) {
	c := &Config{}
	c.Azure.ConnectionString = "DefaultEndpointsProtocol=https;EndpointSuffix=core.windows.net"
	if _, err := c.storageProps(); err == nil {
		t.Fatal("expected error for connection string missing AccountName/AccountKey")
	}
}

func TestWithColdStoreSigning_GCS(t *testing.T) {
	// TLS S3-compatible endpoint (GCS interop): an aws.Config carrying the
	// signing adjustments must ride the context.
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

func TestWithColdStoreSigning_NoOverride(t *testing.T) {
	// Plain-http S3 (SeaweedFS/MinIO), no-endpoint AWS native, and Azure stay
	// on SDK defaults: context returned unchanged.
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
				t.Fatalf("%s must not adjust signing (GCS-only)", name)
			}
		})
	}
}

func TestStorageProps_RegionDefault(t *testing.T) {
	// An omitted region defaults to us-east-1 ONLY where an S3 store was
	// actually configured, matching the archiver (internal/config:
	// applyDefaults) so one YAML drives both tools. Without it the AWS SDK
	// fails inside iceberg-go with "A region must be set", naming nothing the
	// operator wrote. A vended deployment configures no store here and must be
	// left alone: Lakekeeper vends s3.region in the table config, and inventing
	// one would also stamp a meaningless s3.region on a vended ADLS store.
	cases := []struct {
		name   string
		setup  func(*Config)
		region string // "" means the key must be absent
	}{
		{"gcs interop, region omitted", func(c *Config) {
			c.S3.Endpoint = "storage.googleapis.com"
			c.S3.UseSSL = true
			c.S3.AccessKey = "GOOGTESTHMAC"
			c.S3.SecretKey = "secret"
		}, "us-east-1"},
		{"aws native, region omitted", func(c *Config) {
			c.S3.AccessKey = "AKIAEXAMPLE"
			c.S3.SecretKey = "secret"
		}, "us-east-1"},
		{"endpoint only, no creds", func(c *Config) {
			c.S3.Endpoint = "seaweedfs:8333"
		}, "us-east-1"},
		{"explicit region wins", func(c *Config) {
			c.S3.Endpoint = "seaweedfs:8333"
			c.S3.Region = "eu-west-2"
		}, "eu-west-2"},
		{"vended: no store configured", func(c *Config) {
			c.Iceberg.Warehouse = "wh"
		}, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := &Config{}
			tc.setup(c)
			p, err := c.storageProps()
			if err != nil {
				t.Fatal(err)
			}
			got, ok := p[iceio.S3Region]
			if tc.region == "" {
				if ok {
					t.Fatalf("region must be absent, got %q", got)
				}
				return
			}
			if got != tc.region {
				t.Fatalf("region = %q, want %q", got, tc.region)
			}
		})
	}
}

func TestStorageProps_AzureNeverGetsRegion(t *testing.T) {
	// A static ADLS store returns before the S3 branch, so it cannot pick up an
	// S3 region. Pinned because the region default lives on the other side of
	// that early return.
	c := &Config{}
	c.Azure.ConnectionString = "DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=a2V5;EndpointSuffix=core.windows.net"
	p, err := c.storageProps()
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := p[iceio.S3Region]; ok {
		t.Fatalf("azure must carry no s3.region, got %q", got)
	}
}
