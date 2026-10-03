package main

import (
	"context"
	"fmt"
	"strings"

	iceberg "github.com/apache/iceberg-go"
	iceio "github.com/apache/iceberg-go/io"
	"github.com/jackc/pgx/v5"
)

// Config is what the compactor needs, read from the server it maintains: the
// Lakekeeper catalog from the coldfront.warehouse and
// coldfront.lakekeeper_endpoint settings, and the one cold-store backend from
// the coldfront.storage_secret row, the same configuration every cold write
// uses.
type Config struct {
	Iceberg struct {
		Warehouse          string
		LakekeeperEndpoint string
	}
	S3 struct {
		Endpoint  string
		Region    string
		AccessKey string
		SecretKey string
		UseSSL    bool
		URLStyle  string
	}
	Azure struct {
		ConnectionString string
	}
}

// secretRow is the coldfront.storage_secret row, NULLs read as empty strings.
type secretRow struct {
	storageType, keyID, secret, endpoint, region, urlStyle, connectionString string
	useSSL, vended                                                           bool
}

// loadServerConfig reads the catalog settings and the storage secret over a
// connection of its own, closed before the bakery connection opens.
func loadServerConfig(ctx context.Context, dsn string) (*Config, error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("connect postgres: %w", err)
	}
	defer func() { _ = conn.Close(ctx) }()
	var warehouse, endpoint string
	if err := conn.QueryRow(ctx, `SELECT COALESCE(current_setting('coldfront.warehouse', true), ''),
		       COALESCE(current_setting('coldfront.lakekeeper_endpoint', true), '')`).Scan(&warehouse, &endpoint); err != nil {
		return nil, fmt.Errorf("read catalog settings: %w", err)
	}
	var r secretRow
	err = conn.QueryRow(ctx, `SELECT storage_type, COALESCE(key_id, ''), COALESCE(secret, ''), COALESCE(endpoint, ''),
		       region, url_style, use_ssl, COALESCE(connection_string, ''), vended
		  FROM coldfront.storage_secret LIMIT 1`).Scan(
		&r.storageType, &r.keyID, &r.secret, &r.endpoint, &r.region, &r.urlStyle, &r.useSSL, &r.connectionString, &r.vended)
	if err == pgx.ErrNoRows {
		return configFromServer(warehouse, endpoint, nil)
	}
	if err != nil {
		return nil, fmt.Errorf("read coldfront.storage_secret: %w", err)
	}
	return configFromServer(warehouse, endpoint, &r)
}

// configFromServer maps the settings and the secret row onto Config. A vended
// row stores no credential, so nothing is mapped and Lakekeeper's vended
// credentials are the only ones iceberg-go sees.
func configFromServer(warehouse, endpoint string, row *secretRow) (*Config, error) {
	if warehouse == "" || endpoint == "" {
		return nil, fmt.Errorf("the server has no catalog: set coldfront.warehouse and coldfront.lakekeeper_endpoint in postgresql.conf")
	}
	if row == nil {
		return nil, fmt.Errorf("the server has no cold store: run coldfront.set_storage_secret (or set_storage_secret_azure, set_storage_secret_vended), or import a YAML with an s3: or azure: stanza")
	}
	c := &Config{}
	c.Iceberg.Warehouse, c.Iceberg.LakekeeperEndpoint = warehouse, endpoint
	switch {
	case row.vended:
	case row.storageType == "azure":
		c.Azure.ConnectionString = row.connectionString
	default:
		c.S3.Endpoint, c.S3.Region, c.S3.AccessKey, c.S3.SecretKey = row.endpoint, row.region, row.keyID, row.secret
		c.S3.UseSSL, c.S3.URLStyle = row.useSSL, row.urlStyle
	}
	return c, nil
}

// splitSchemaTable parses a "schema.table" CLI argument into its parts; a bare
// name defaults to the "public" schema, matching the archiver's default source
// schema. The PG schema is the Iceberg namespace, so same-named tables in
// different schemas resolve to distinct Iceberg tables.
func splitSchemaTable(arg string) (schema, table string) {
	if s, t, found := strings.Cut(arg, "."); found {
		return s, t
	}
	return "public", arg
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
	return c.s3Props(), nil
}

// s3Props builds the S3 fileio properties: static keys, region, endpoint
// addressing.
func (c *Config) s3Props() iceberg.Properties {
	p := iceberg.Properties{}
	// Static S3 keys. Omitted entirely for a vended deployment (empty s3 block):
	// iceberg-go always requests delegation and merges Lakekeeper's vended
	// storage-credentials last, so empty static keys must not shadow them. (A
	// vended Azure store leaves the azure block empty too, so no ADLSSharedKey*
	// is set; the shared-key branch would otherwise beat the vended SAS.)
	if c.S3.AccessKey != "" && c.S3.SecretKey != "" {
		p[iceio.S3AccessKeyID] = c.S3.AccessKey
		p[iceio.S3SecretAccessKey] = c.S3.SecretKey
	}
	if region := c.s3Region(); region != "" {
		p[iceio.S3Region] = region
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
	return p
}

// s3Region resolves the region to sign with. The SDK refuses to sign without
// one, so default it the way the archiver does, but only where an S3 store is
// configured: a vended deployment takes its region from Lakekeeper instead.
func (c *Config) s3Region() string {
	if c.S3.Region != "" {
		return c.S3.Region
	}
	if c.S3.Endpoint != "" || c.S3.AccessKey != "" {
		return "us-east-1"
	}
	return ""
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
