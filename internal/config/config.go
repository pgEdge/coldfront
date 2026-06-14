package config

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/pgedge/coldfront/internal/partition"
)

// Config is the top-level archiver configuration parsed from YAML.
type Config struct {
	Postgres PostgresConfig `yaml:"postgres"`
	Iceberg  IcebergConfig  `yaml:"iceberg"`
	S3       S3Config       `yaml:"s3"`
	Azure    AzureConfig    `yaml:"azure"`
	Archiver ArchiverConfig `yaml:"archiver"`
}

// PostgresConfig holds the PostgreSQL connection string.
type PostgresConfig struct {
	DSN string `yaml:"dsn"`
}

// IcebergConfig identifies the Iceberg REST catalog (Lakekeeper) and
// warehouse the archiver writes to.
type IcebergConfig struct {
	Warehouse          string `yaml:"warehouse"`           // Lakekeeper warehouse name
	LakekeeperEndpoint string `yaml:"lakekeeper_endpoint"` // e.g. http://lakekeeper:8181/catalog
	Namespace          string `yaml:"namespace"`
}

// S3Config holds credentials and endpoint for the object store backing the
// Iceberg warehouse. Any S3-compatible store works, including Google Cloud
// Storage via its S3-interoperability endpoint (endpoint: storage.googleapis.com,
// use_ssl: true, access_key/secret_key = a GCS HMAC key pair) — GCS needs no
// separate backend, it IS an s3 store with a custom TLS endpoint.
type S3Config struct {
	Endpoint  string `yaml:"endpoint"` // e.g. seaweedfs:8333 (http) or storage.googleapis.com (GCS)
	Region    string `yaml:"region"`
	AccessKey string `yaml:"access_key"`
	SecretKey string `yaml:"secret_key"`
	// UseSSL toggles TLS on the session secret the archiver creates for its own
	// export. Default false suits a plain-http compat store (SeaweedFS/MinIO);
	// set true for a TLS endpoint (GCS, real AWS S3). Mirrors set_storage_secret's
	// p_use_ssl, which already drives the persistent (cold-commit) secret. IGNORED
	// when endpoint is empty: real AWS S3 then uses DuckDB's native https default.
	UseSSL bool `yaml:"use_ssl"`
	// URLStyle selects S3 addressing for the export secret: "path" (default;
	// S3-compatible stores — SeaweedFS/MinIO/GCS-interop) or "vhost". IGNORED when
	// endpoint is empty — real AWS S3 then uses DuckDB's native virtual-hosted
	// addressing, which is REQUIRED for Regions launched after 2019-03-20 (e.g.
	// ap-south-2): their DNS does not route path-style requests and returns HTTP
	// 400. Mirrors set_storage_secret's p_url_style.
	URLStyle string `yaml:"url_style"`
}

// AzureConfig holds the Azure ADLS Gen2 connection string for the cold tier.
// When set, the cold backend is Azure (a TYPE azure secret) instead of S3 — and
// s3.* must be left empty. The storage-account access key rides INSIDE the
// connection string (DefaultEndpointsProtocol=…;AccountName=…;AccountKey=…;
// EndpointSuffix=…); the DuckDB azure extension has no separate account-key
// parameter. Requires the DuckDB 1.5.x stack (see DUCKDB_1.5_PATCHED.md).
type AzureConfig struct {
	ConnectionString string `yaml:"connection_string"`
}

// ArchiverConfig wraps the list of tables the archiver manages in a single run.
type ArchiverConfig struct {
	Tables []TableConfig `yaml:"tables"`
}

// TableConfig describes one tiered table: which partitioned table to manage,
// its time column, the partition cadence, and how much history stays hot.
// PartitionColumn is optional; if empty it is auto-detected from pg_catalog.
type TableConfig struct {
	SourceTable     string `yaml:"source_table"`
	SourceSchema    string `yaml:"source_schema"`
	PartitionColumn string `yaml:"partition_column"`
	PartitionPeriod string `yaml:"partition_period"`
	// HotPeriod (tiered mode only) is the age at which a partition is tiered to
	// cold Iceberg — data preserved, just relocated. RetentionPeriod is the age
	// at which data is destroyed: in tiered mode it drops cold Iceberg rows past
	// it (optional; omit = keep cold forever); in partition-only mode it drops
	// the hot PG partition (required, no cold tier).
	HotPeriod        string `yaml:"hot_period"`
	RetentionPeriod  string `yaml:"retention_period"`
	FuturePartitions int    `yaml:"future_partitions"`
	// ExpirationStrategy decides what happens to a partition past the retention
	// window in the standalone partitioner: "drop" (default — DETACH + DROP,
	// destroy) or "detach" (DETACH only, leave it as a standalone table). The
	// tiered archiver ignores it (it always drops after exporting to cold), so
	// "detach" is valid only in partition-only mode.
	ExpirationStrategy string `yaml:"expiration_strategy"`
	// PartMode is "timestamp" (default) or "id". In id mode the partition
	// column is a time-ordered id (so it can also be the primary key) and
	// IDScheme names its encoding.
	PartMode string `yaml:"part_mode"`
	IDScheme string `yaml:"id_scheme"` // "uuidv7" | "snowflake" (id mode only)
	// SubPartition, when set, makes this a 2-level LIST→RANGE table.
	SubPartition *SubPartitionConfig `yaml:"sub_partition"`
}

// SubPartitionConfig turns a table into a 2-level LIST→RANGE tree. The table
// must already be PARTITION BY LIST(<level-1 column>); ValuesSource is a SQL
// query returning that column's current values (a single text column). The flat
// partition_column / partition_period above describe the level-2 RANGE leaves
// auto-maintained beneath each level-1 value.
type SubPartitionConfig struct {
	ValuesSource string `yaml:"values_source"`
}

// Load reads a YAML config file from path, applies defaults, and validates
// the result. Returns the parsed Config or an error describing the first
// problem encountered (read, parse, or validation).
func Load(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}

	cfg := &Config{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	applyDefaults(cfg)

	if err := cfg.Validate(); err != nil {
		return nil, err
	}

	return cfg, nil
}

// applyDefaults fills in sensible defaults for optional fields and parses
// any `schema.table` syntax in SourceTable into separate SourceSchema and
// SourceTable components.
func applyDefaults(cfg *Config) {
	if cfg.Iceberg.Namespace == "" {
		cfg.Iceberg.Namespace = "default"
	}
	if cfg.S3.Region == "" {
		cfg.S3.Region = "us-east-1"
	}
	for i := range cfg.Archiver.Tables {
		t := &cfg.Archiver.Tables[i]
		if strings.Contains(t.SourceTable, ".") {
			parts := strings.SplitN(t.SourceTable, ".", 2)
			if t.SourceSchema == "" {
				t.SourceSchema = parts[0]
			}
			t.SourceTable = parts[1]
		}
		if t.SourceSchema == "" {
			t.SourceSchema = "public"
		}
		if t.FuturePartitions == 0 {
			t.FuturePartitions = 3
		}
		if t.ExpirationStrategy == "" {
			t.ExpirationStrategy = partition.StrategyDrop
		}
	}
}

// Validate checks that all required fields are set and that enumerated
// values (like partition_period) are within the allowed set. Returns the
// first violation found; callers should treat a non-nil return as fatal.
func (c *Config) Validate() error {
	if c.Postgres.DSN == "" {
		return fmt.Errorf("postgres.dsn is required")
	}
	// Iceberg/S3 are required only in iceberg mode. A config with no iceberg
	// warehouse/endpoint and no S3 fields is a partition-only run (premake +
	// retention, no cold-tier archival). If ANY iceberg/S3 field is supplied,
	// every required one must be — a partial cold config fails loudly rather
	// than silently running half-configured.
	anyS3 := c.S3.Endpoint != "" || c.S3.AccessKey != "" || c.S3.SecretKey != ""
	icebergMode := c.Iceberg.Warehouse != "" || c.Iceberg.LakekeeperEndpoint != "" ||
		anyS3 || c.Azure.ConnectionString != ""
	if icebergMode {
		if c.Iceberg.Warehouse == "" {
			return fmt.Errorf("iceberg.warehouse is required")
		}
		if c.Iceberg.LakekeeperEndpoint == "" {
			return fmt.Errorf("iceberg.lakekeeper_endpoint is required")
		}
		// The cold backend is exactly one of S3 or Azure — selected by which is
		// configured. Mixing is a config error.
		if c.Azure.ConnectionString != "" {
			if anyS3 {
				return fmt.Errorf("set either s3.* or azure.connection_string, not both")
			}
		} else {
			// s3.endpoint is OPTIONAL. Empty = real AWS S3: DuckDB uses its native
			// per-Region virtual-hosted + https endpoint (set s3.region). A non-empty
			// endpoint = an S3-compatible store (SeaweedFS/MinIO/GCS-interop), reached
			// path-style by default. Forcing an endpoint broke real AWS in Regions
			// launched after 2019-03-20, which only route virtual-hosted requests.
			if c.S3.AccessKey == "" {
				return fmt.Errorf("s3.access_key is required")
			}
			if c.S3.SecretKey == "" {
				return fmt.Errorf("s3.secret_key is required")
			}
			if c.S3.URLStyle != "" && c.S3.URLStyle != "path" && c.S3.URLStyle != "vhost" {
				return fmt.Errorf("s3.url_style must be \"path\" or \"vhost\"")
			}
		}
	}
	// Zero tables is allowed here: the managed-table set may instead come from
	// the replicated coldfront.partition_config table, resolved at startup. The
	// binaries fail loud if BOTH the table and archiver.tables are empty.
	for i, t := range c.Archiver.Tables {
		if t.SourceTable == "" {
			return fmt.Errorf("archiver.tables[%d].source_table is required", i)
		}
		if t.PartitionPeriod == "" {
			return fmt.Errorf("archiver.tables[%d].partition_period is required", i)
		}
		if t.PartitionPeriod != partition.PeriodMonthly && t.PartitionPeriod != partition.PeriodDaily {
			return fmt.Errorf("archiver.tables[%d].partition_period must be %q or %q",
				i, partition.PeriodMonthly, partition.PeriodDaily)
		}
		// Lifecycle thresholds depend on mode. Tiered: hot_period (tier-to-cold
		// age) is required; retention_period (drop cold data) is optional and
		// must exceed hot_period. Partition-only: retention_period (drop the hot
		// partition) is required; hot_period is meaningless without a cold tier.
		if icebergMode {
			// The cold tier is time-only (timestamp RANGE key, timestamptz Iceberg
			// writes). id mode keys partitions on a non-time id, which the cold
			// tier cannot express — reject it at config load rather than fail
			// cryptically at runtime. (2-level LIST→RANGE is supported: the RANGE
			// level is still time, region is just a column.)
			if t.PartMode != "" && t.PartMode != partition.PartModeTimestamp {
				return fmt.Errorf("archiver.tables[%d].part_mode %q is only valid in partition-only mode; the cold tier is time-only", i, t.PartMode)
			}
			if t.HotPeriod == "" {
				return fmt.Errorf("archiver.tables[%d].hot_period is required in tiered mode", i)
			}
			hotDur, err := partition.ParseRetention(t.HotPeriod)
			if err != nil {
				return fmt.Errorf("archiver.tables[%d].hot_period: %w", i, err)
			}
			if t.RetentionPeriod != "" {
				retDur, err := partition.ParseRetention(t.RetentionPeriod)
				if err != nil {
					return fmt.Errorf("archiver.tables[%d].retention_period: %w", i, err)
				}
				if retDur <= hotDur {
					return fmt.Errorf("archiver.tables[%d].retention_period (%s) must exceed hot_period (%s)",
						i, t.RetentionPeriod, t.HotPeriod)
				}
			}
		} else {
			if t.HotPeriod != "" {
				return fmt.Errorf("archiver.tables[%d].hot_period is only valid in tiered mode (no iceberg/s3 configured)", i)
			}
			if t.RetentionPeriod == "" {
				return fmt.Errorf("archiver.tables[%d].retention_period is required", i)
			}
		}
		// part_mode / id_scheme: reuse BoundaryFor as the single validator of
		// the valid set, so config and the partition core never drift.
		if _, err := partition.BoundaryFor(t.PartMode, t.IDScheme); err != nil {
			return fmt.Errorf("archiver.tables[%d]: %w", i, err)
		}
		// expiration_strategy: enum, and "detach" only makes sense partition-only
		// (the tiered archiver drops after exporting to cold, so it would be a
		// silent no-op).
		switch t.ExpirationStrategy {
		case "", partition.StrategyDrop, partition.StrategyDetach:
		default:
			return fmt.Errorf("archiver.tables[%d].expiration_strategy %q must be %q or %q",
				i, t.ExpirationStrategy, partition.StrategyDetach, partition.StrategyDrop)
		}
		if icebergMode && t.ExpirationStrategy == partition.StrategyDetach {
			return fmt.Errorf("archiver.tables[%d].expiration_strategy %q is only valid in partition-only mode",
				i, partition.StrategyDetach)
		}
		if t.SubPartition != nil {
			if t.SubPartition.ValuesSource == "" {
				return fmt.Errorf("archiver.tables[%d].sub_partition.values_source is required", i)
			}
			// 2-level tables need the RANGE (time) column explicitly: on a first
			// run no LIST child exists yet to auto-detect it from.
			if t.PartitionColumn == "" {
				return fmt.Errorf("archiver.tables[%d].partition_column is required for 2-level (sub_partition) tables", i)
			}
		}
	}
	return nil
}
