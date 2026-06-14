package main

import (
	"fmt"
	"os"
	"strings"

	iceberg "github.com/apache/iceberg-go"
	iceio "github.com/apache/iceberg-go/io"
	"gopkg.in/yaml.v3"
)

// Config is the subset of the ColdFront deployment YAML the compactor needs:
// the Postgres DSN (for the bakery claim) plus the Lakekeeper catalog and the
// one configured cold-store backend. It deliberately mirrors the archiver's
// YAML shape so a single config file drives both — but the compactor is a
// separate Go module, so it parses its own subset rather than importing the
// archiver's internal/config across the module boundary.
type Config struct {
	Postgres struct {
		DSN string `yaml:"dsn"`
	} `yaml:"postgres"`
	Iceberg struct {
		Warehouse          string `yaml:"warehouse"`
		LakekeeperEndpoint string `yaml:"lakekeeper_endpoint"`
		Namespace          string `yaml:"namespace"`
	} `yaml:"iceberg"`
	S3 struct {
		Endpoint  string `yaml:"endpoint"`
		Region    string `yaml:"region"`
		AccessKey string `yaml:"access_key"`
		SecretKey string `yaml:"secret_key"`
		UseSSL    bool   `yaml:"use_ssl"`
		URLStyle  string `yaml:"url_style"`
	} `yaml:"s3"`
	Azure struct {
		ConnectionString string `yaml:"connection_string"`
	} `yaml:"azure"`
}

// LoadConfig reads and parses the deployment YAML.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	var c Config
	if err := yaml.Unmarshal(data, &c); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if c.Iceberg.Namespace == "" {
		c.Iceberg.Namespace = "default"
	}
	return &c, nil
}

// storageProps builds the iceberg-go fileio credential properties for whichever
// cold-store backend the deployment configures — exactly one of S3 or Azure,
// mirroring ColdFront's set_storage_secret. The S3 path serves SeaweedFS/MinIO,
// real AWS S3, AND Google Cloud Storage via its S3-interop endpoint (they are
// all the S3 protocol, differing only by endpoint/addressing); the Azure path
// serves ADLS Gen2. These props are handed to the REST catalog so the table's
// fileio (keyed by its location scheme: s3://, gs://, abfs://) can authenticate.
func (c *Config) storageProps() (iceberg.Properties, error) {
	if c.Azure.ConnectionString != "" {
		name, key, err := parseAzureConnString(c.Azure.ConnectionString)
		if err != nil {
			return nil, err
		}
		return iceberg.Properties{
			iceio.ADLSSharedKeyAccountName: name,
			iceio.ADLSSharedKeyAccountKey:  key,
		}, nil
	}

	p := iceberg.Properties{
		iceio.S3AccessKeyID:     c.S3.AccessKey,
		iceio.S3SecretAccessKey: c.S3.SecretKey,
	}
	if c.S3.Region != "" {
		p[iceio.S3Region] = c.S3.Region
	}
	if c.S3.Endpoint != "" {
		// S3-compatible store (SeaweedFS/MinIO) or GCS S3-interop: an explicit
		// endpoint, http unless use_ssl. Path-style is the default for these;
		// only url_style:"vhost" forces virtual-hosted addressing.
		scheme := "http"
		if c.S3.UseSSL {
			scheme = "https"
		}
		p[iceio.S3EndpointURL] = scheme + "://" + c.S3.Endpoint
		p[iceio.S3ForceVirtualAddressing] = fmt.Sprintf("%t", c.S3.URLStyle == "vhost")
	}
	// No endpoint => real AWS S3: leave endpoint/addressing to the aws-sdk
	// default (per-Region virtual-hosted HTTPS), set only the region.
	return p, nil
}

// parseAzureConnString extracts AccountName and AccountKey from an ADLS
// connection string ("DefaultEndpointsProtocol=...;AccountName=foo;AccountKey=
// bar==;EndpointSuffix=..."). The key is base64 and may end in '=' padding;
// splitting on ';' then the FIRST '=' preserves it.
func parseAzureConnString(cs string) (name, key string, err error) {
	for _, part := range strings.Split(cs, ";") {
		k, v, ok := strings.Cut(part, "=")
		if !ok {
			continue
		}
		switch strings.TrimSpace(k) {
		case "AccountName":
			name = strings.TrimSpace(v)
		case "AccountKey":
			key = strings.TrimSpace(v)
		}
	}
	if name == "" || key == "" {
		return "", "", fmt.Errorf("azure connection string missing AccountName/AccountKey")
	}
	return name, key, nil
}
