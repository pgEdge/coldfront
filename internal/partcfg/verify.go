package partcfg

import (
	"context"
	"fmt"

	"github.com/pgedge/coldfront/internal/config"
)

// configHome ends every refusal: configuration lives in the server, and a YAML
// that says otherwise is wrong, not a request.
const configHome = "configuration lives in the coldfront config tables, documented in " +
	"docs/usage.md: coldfront.partition_config (register, set, import), " +
	"coldfront.storage_secret (coldfront.set_storage_secret) and the " +
	"coldfront.warehouse and coldfront.lakekeeper_endpoint settings " +
	"(postgresql.conf); change it there, not in the YAML"

// check is one query that returns true when a YAML value agrees with what the
// server holds. what names the YAML value in the refusal.
type check struct {
	what string
	sql  string
	args []any
}

// verifyChecks lists one check per YAML value that has a stored counterpart:
// each table against its partition_config row, the cold-store stanza against
// the storage_secret row, and each iceberg key against its server setting. A
// value the file does not set is not checked.
func verifyChecks(cfg *config.Config) []check {
	var checks []check
	for i, t := range cfg.Archiver.Tables {
		r := rowFrom(t)
		checks = append(checks, check{
			what: fmt.Sprintf("archiver.tables[%d] (%s.%s)", i, r.schema, r.table),
			sql:  r.matchSQL(),
		})
	}
	switch {
	case cfg.Azure.ConnectionString != "":
		checks = append(checks, check{what: "azure", args: []any{cfg.Azure.ConnectionString},
			sql: `SELECT EXISTS (SELECT 1 FROM coldfront.storage_secret
			       WHERE NOT vended AND storage_type = 'azure' AND connection_string = $1)`})
	case cfg.S3.AccessKey != "":
		urlStyle := cfg.S3.URLStyle
		if urlStyle == "" {
			urlStyle = "path"
		}
		checks = append(checks, check{what: "s3",
			args: []any{cfg.S3.AccessKey, cfg.S3.SecretKey, cfg.S3.Endpoint, cfg.S3.Region, urlStyle, cfg.S3.UseSSL},
			sql: `SELECT EXISTS (SELECT 1 FROM coldfront.storage_secret
			       WHERE NOT vended AND storage_type = 's3' AND key_id = $1 AND secret = $2
			         AND COALESCE(endpoint, '') = $3 AND region = $4 AND url_style = $5 AND use_ssl = $6)`})
	}
	return append(checks, catalogChecks(cfg)...)
}

// catalogChecks lists the checks for the iceberg keys a file sets. The settings
// they name live in postgresql.conf, which an import cannot write, so `import`
// runs them before it writes anything.
func catalogChecks(cfg *config.Config) []check {
	var checks []check
	if cfg.Iceberg.Warehouse != "" {
		checks = append(checks, check{what: "iceberg.warehouse", args: []any{cfg.Iceberg.Warehouse},
			sql: `SELECT COALESCE(current_setting('coldfront.warehouse', true), '') = $1`})
	}
	if cfg.Iceberg.LakekeeperEndpoint != "" {
		checks = append(checks, check{what: "iceberg.lakekeeper_endpoint", args: []any{cfg.Iceberg.LakekeeperEndpoint},
			sql: `SELECT COALESCE(current_setting('coldfront.lakekeeper_endpoint', true), '') = $1`})
	}
	return checks
}

// Verify refuses a YAML that disagrees with the stored configuration in any
// value it sets. It runs after `import` has written the file (when the two
// agree by construction) and on every other run that was given a file.
func Verify(ctx context.Context, db DBTX, cfg *config.Config) error {
	return runChecks(ctx, db, verifyChecks(cfg))
}

// runChecks runs the checks in order and refuses on the first value that
// disagrees with the server, naming it.
func runChecks(ctx context.Context, db DBTX, checks []check) error {
	for _, c := range checks {
		rows, err := db.Query(ctx, c.sql, c.args...) // nosemgrep
		if err != nil {
			return fmt.Errorf("check %s against the server: %w", c.what, err)
		}
		same := false
		if rows.Next() {
			err = rows.Scan(&same)
		}
		rows.Close()
		if err != nil {
			return fmt.Errorf("check %s against the server: %w", c.what, err)
		}
		if !same {
			return fmt.Errorf("%s in the YAML disagrees with the stored configuration; %s", c.what, configHome)
		}
	}
	return nil
}
