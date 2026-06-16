package main

import (
	"testing"

	iceio "github.com/apache/iceberg-go/io"
)

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
