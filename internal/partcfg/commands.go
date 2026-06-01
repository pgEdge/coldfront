package partcfg

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"gopkg.in/yaml.v3"

	"github.com/pgedge/coldfront/internal/config"
)

// Commands is the set of management subcommands both binaries expose. Each runs
// against coldfront.partition_config (the replicated source of truth) and is a
// thin, dependency-free SQL operation — so it works identically on a vanilla
// stock-PG partitioner node and an iceberg-backed archiver node.
var Commands = map[string]func(ctx context.Context, args []string) error{
	"register": runRegister,
	"list":     runList,
	"set":      runSet,
	"remove":   runRemove,
	"import":   runImport,
	"export":   runExport,
}

// IsCommand reports whether name is a management subcommand (so the binary
// routes to it instead of its default reconcile/archive run).
func IsCommand(name string) bool { _, ok := Commands[name]; return ok }

// Run dispatches a management subcommand. args is everything after the
// subcommand word.
func Run(ctx context.Context, name string, args []string) error {
	return Commands[name](ctx, args)
}

// CommandNames returns the subcommand words, for the binary's top-level usage.
func CommandNames() []string {
	return []string{"register", "list", "set", "remove", "import", "export"}
}

// addConn registers the shared --dsn / --config connection flags on fs and
// returns accessors. Management commands connect with --dsn directly, or read
// the DSN from the same --config YAML the runtime uses.
func addConn(fs *flag.FlagSet) func(context.Context) (*pgxpool.Pool, error) {
	dsn := fs.String("dsn", "", "PostgreSQL connection string (or use --config)")
	cfgPath := fs.String("config", "", "path to the deployment YAML; its postgres.dsn is used if --dsn is unset")
	return func(ctx context.Context) (*pgxpool.Pool, error) {
		d := *dsn
		if d == "" && *cfgPath != "" {
			cfg, err := config.Load(*cfgPath)
			if err != nil {
				return nil, fmt.Errorf("read --config: %w", err)
			}
			d = cfg.Postgres.DSN
		}
		if d == "" {
			return nil, fmt.Errorf("a connection is required: pass --dsn or --config")
		}
		return openPool(ctx, d)
	}
}

// runRegister adds (or adopts) a managed table: it validates the table is
// partitioned and that its PRIMARY KEY covers the partition key, then INSERTs
// the partition_config row (whose CHECK constraints enforce the lifecycle rules).
func runRegister(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("register", flag.ContinueOnError)
	connect := addConn(fs)
	schema := fs.String("schema", "public", "schema of the partitioned table")
	table := fs.String("table", "", "name of the partitioned table (required)")
	period := fs.String("period", "", "partition cadence: monthly | daily (required)")
	column := fs.String("column", "", "the RANGE (time) key column; required for 2-level, else auto-detected")
	premake := fs.Int("premake", 3, "future partitions kept ahead of now")
	hot := fs.String("hot-period", "", "TIERED only: age at which a partition is tiered to cold Iceberg (e.g. \"1 month\"). Omit ⇒ partition-only.")
	retention := fs.String("retention", "", "age at which data is DROPPED (e.g. \"5 years\"). Tiered: drops cold rows (optional, must exceed hot-period). Partition-only: drops the hot partition (required).")
	partMode := fs.String("part-mode", "timestamp", "timestamp | id (id = RANGE on a time-ordered id, partition-only)")
	idScheme := fs.String("id-scheme", "", "uuidv7 | snowflake (required with --part-mode id)")
	subValues := fs.String("sub-values-source", "", "2-level only: SQL returning the LIST (level-1) values, e.g. \"SELECT region FROM regions\"")
	printSQL := fs.Bool("print-sql", false, "print the INSERT (and any DDL) instead of running it — for git/audit")
	dryRun := fs.Bool("dry-run", false, "validate everything but make no changes")
	fs.Usage = registerUsage(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *table == "" || *period == "" {
		fs.Usage()
		return fmt.Errorf("--table and --period are required")
	}
	if *retention == "" && *hot == "" {
		return fmt.Errorf("set --retention (and/or --hot-period): a managed table needs a destroy boundary")
	}

	row := configRow{
		schema: *schema, table: *table, period: *period, column: *column,
		premake: *premake, partMode: *partMode, idScheme: *idScheme,
		hot: *hot, retention: *retention, subValues: *subValues,
	}
	insertSQL := row.insertSQL()
	if *printSQL {
		fmt.Println(insertSQL)
		return nil
	}

	pool, err := connect(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := EnsureTable(ctx, pool); err != nil {
		return err
	}
	// PK-superset validation: the cutover keys delta capture by the source PK,
	// so the PK must cover the partition key column(s). 2-level adds the RANGE
	// column (the LIST column comes from the catalog).
	if err := validatePKSuperset(ctx, pool, *schema, *table, *column, *subValues != ""); err != nil {
		return err
	}
	if *dryRun {
		fmt.Printf("dry-run OK: %s.%s validates; would run:\n%s\n", *schema, *table, insertSQL)
		return nil
	}
	if _, err := pool.Exec(ctx, insertSQL); err != nil {
		return fmt.Errorf("register %s.%s: %w", *schema, *table, err)
	}
	fmt.Printf("registered %s.%s\n", *schema, *table)
	return nil
}

func registerUsage(fs *flag.FlagSet) func() {
	return func() {
		_, _ = fmt.Fprint(fs.Output(), `register — add (or adopt) a partitioned table to partition lifecycle management.

Validates the table is partitioned and that its PRIMARY KEY covers the partition
key (required for race-safe cutover), then writes a coldfront.partition_config
row. The row's CHECK constraints enforce the lifecycle rules at write time.

USAGE:
  <binary> register --table <name> --period <monthly|daily> [lifecycle flags] (--dsn <dsn> | --config <yaml>)

EXAMPLES:
  # Partition-only: keep a forward window, drop partitions older than 12 months.
  partitioner register --config cf.yaml --table events --period monthly --retention "12 months"

  # Tiered: tier to cold Iceberg after 1 month, drop cold data after 5 years.
  archiver register --dsn "host=db dbname=app" --table events --period monthly \
      --hot-period "1 month" --retention "5 years"

  # id-mode (single-column PRIMARY KEY (id) on a snowflake-keyed table; partition-only).
  partitioner register --config cf.yaml --table events --period monthly \
      --column id --part-mode id --id-scheme snowflake --retention "1 year"

  # 2-level LIST(region)→RANGE(ts), tiered; region values come from a table.
  archiver register --config cf.yaml --table regional --period monthly --column ts \
      --hot-period "1 month" --sub-values-source "SELECT region FROM regions"

  # Print the SQL for review/commit instead of running it (GitOps).
  partitioner register --table events --period monthly --retention "1 year" --print-sql

FLAGS:
`)
		fs.PrintDefaults()
	}
}

// runList prints the managed tables and their lifecycle.
func runList(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	connect := addConn(fs)
	fs.Usage = func() {
		_, _ = fmt.Fprint(fs.Output(), `list — show the tables under partition lifecycle management.

USAGE:
  <binary> list (--dsn <dsn> | --config <yaml>)

EXAMPLE:
  partitioner list --config cf.yaml

FLAGS:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	pool, err := connect(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := EnsureTable(ctx, pool); err != nil {
		return err
	}
	rows, err := pool.Query(ctx, `
		SELECT schema_name, table_name, partition_period,
		       COALESCE(hot_period,'-'), COALESCE(retention_period,'-'),
		       CASE WHEN hot_period IS NULL THEN 'partition-only' ELSE 'tiered' END,
		       CASE WHEN sub_part_values_source IS NULL THEN 'flat' ELSE '2-level' END,
		       enabled
		FROM coldfront.partition_config ORDER BY schema_name, table_name`)
	if err != nil {
		return fmt.Errorf("query partition_config: %w", err)
	}
	defer rows.Close()
	return printList(os.Stdout, rows)
}

func printList(w io.Writer, rows pgx.Rows) error {
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "TABLE\tPERIOD\tHOT\tRETENTION\tMODE\tSHAPE\tENABLED")
	n := 0
	for rows.Next() {
		var schema, table, period, hot, ret, mode, shape string
		var enabled bool
		if err := rows.Scan(&schema, &table, &period, &hot, &ret, &mode, &shape, &enabled); err != nil {
			return err
		}
		_, _ = fmt.Fprintf(tw, "%s.%s\t%s\t%s\t%s\t%s\t%s\t%t\n", schema, table, period, hot, ret, mode, shape, enabled)
		n++
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if n == 0 {
		_, _ = fmt.Fprintln(w, "(no managed tables)")
		return nil
	}
	return tw.Flush()
}

// configRow holds the register inputs and builds the parameterless INSERT (it
// quotes its own literals so --print-sql emits runnable, committable SQL).
type configRow struct {
	schema, table, period, column string
	premake                       int
	partMode, idScheme            string
	hot, retention, subValues     string
}

func (r configRow) insertSQL() string {
	return fmt.Sprintf(`INSERT INTO coldfront.partition_config
  (schema_name, table_name, partition_period, partition_column, future_partitions,
   part_mode, id_scheme, hot_period, retention_period, sub_part_values_source)
VALUES (%s, %s, %s, %s, %d, %s, %s, %s, %s, %s);`,
		lit(r.schema), lit(r.table), lit(r.period), lit(r.column), r.premake,
		lit(r.partMode), lit(r.idScheme), lit(r.hot), lit(r.retention), lit(r.subValues))
}

// validatePKSuperset confirms the table's PRIMARY KEY covers the partition key.
// requiredCols = the parent's partition-key column(s); for a 2-level table the
// parent's key is the LIST column and the RANGE column (rangeCol) is added.
func validatePKSuperset(ctx context.Context, db DBTX, schema, table, rangeCol string, twoLevel bool) error {
	prows, err := db.Query(ctx, `
		SELECT pg_get_partkeydef(c.oid)
		FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'p'`, schema, table)
	if err != nil {
		return fmt.Errorf("read partition key for %s.%s: %w", schema, table, err)
	}
	var partkeydef string
	for prows.Next() {
		if err := prows.Scan(&partkeydef); err != nil {
			prows.Close()
			return err
		}
	}
	prows.Close()
	if err := prows.Err(); err != nil {
		return err
	}
	if partkeydef == "" {
		return fmt.Errorf("%s.%s is not a partitioned table (or does not exist)", schema, table)
	}
	required := map[string]bool{}
	for _, c := range partKeyCols(partkeydef) {
		required[c] = true
	}
	if twoLevel && rangeCol != "" {
		required[rangeCol] = true
	}

	pkCols, err := primaryKeyCols(ctx, db, schema, table)
	if err != nil {
		return err
	}
	if len(pkCols) == 0 {
		return fmt.Errorf("%s.%s has no PRIMARY KEY — required so the cutover can key writes by source PK", schema, table)
	}
	pk := map[string]bool{}
	for _, c := range pkCols {
		pk[c] = true
	}
	for c := range required {
		if !pk[c] {
			return fmt.Errorf("%s.%s PRIMARY KEY (%s) does not cover partition key column %q — add it to the PK",
				schema, table, strings.Join(pkCols, ", "), c)
		}
	}
	return nil
}

func primaryKeyCols(ctx context.Context, db DBTX, schema, table string) ([]string, error) {
	rows, err := db.Query(ctx, `
		SELECT a.attname
		FROM pg_index i
		JOIN pg_class c ON c.oid = i.indrelid
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
		WHERE n.nspname = $1 AND c.relname = $2 AND i.indisprimary
		ORDER BY a.attnum`, schema, table)
	if err != nil {
		return nil, fmt.Errorf("read primary key: %w", err)
	}
	defer rows.Close()
	var cols []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			return nil, err
		}
		cols = append(cols, c)
	}
	return cols, rows.Err()
}

// partKeyCols extracts the column names from a pg_get_partkeydef string like
// "RANGE (ts)" or "LIST (region)".
func partKeyCols(def string) []string {
	lp := strings.Index(def, "(")
	rp := strings.LastIndex(def, ")")
	if lp < 0 || rp <= lp {
		return nil
	}
	var out []string
	for _, p := range strings.Split(def[lp+1:rp], ",") {
		if c := strings.TrimSpace(p); c != "" {
			out = append(out, c)
		}
	}
	return out
}

// lit renders a SQL literal: NULL for empty, else a single-quoted, escaped string.
func lit(s string) string {
	if s == "" {
		return "NULL"
	}
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// openPool connects and verifies the connection.
func openPool(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping: %w", err)
	}
	return pool, nil
}

// rowFrom maps a config.TableConfig (e.g. from a YAML being imported) onto a
// configRow, applying the same defaults as the YAML loader so the INSERT is valid.
func rowFrom(t config.TableConfig) configRow {
	r := configRow{
		schema: t.SourceSchema, table: t.SourceTable, period: t.PartitionPeriod,
		column: t.PartitionColumn, premake: t.FuturePartitions, partMode: t.PartMode,
		idScheme: t.IDScheme, hot: t.HotPeriod, retention: t.RetentionPeriod,
	}
	if t.SubPartition != nil {
		r.subValues = t.SubPartition.ValuesSource
	}
	if r.schema == "" {
		r.schema = "public"
	}
	if r.premake == 0 {
		r.premake = 3
	}
	if r.partMode == "" {
		r.partMode = "timestamp"
	}
	return r
}

// runSet updates lifecycle fields on a managed table (only the flags you pass),
// or pauses/resumes it with --disable/--enable.
func runSet(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("set", flag.ContinueOnError)
	connect := addConn(fs)
	schema := fs.String("schema", "public", "schema of the managed table")
	table := fs.String("table", "", "name of the managed table (required)")
	period := fs.String("period", "", "change cadence: monthly | daily")
	column := fs.String("column", "", "change the partition column")
	premake := fs.Int("premake", 0, "change the premake window")
	hot := fs.String("hot-period", "", "change the tier-to-cold age (empty value clears it ⇒ partition-only)")
	retention := fs.String("retention", "", "change the drop age (empty value clears it)")
	subValues := fs.String("sub-values-source", "", "change the 2-level LIST values query")
	enable := fs.Bool("enable", false, "resume managing this table")
	disable := fs.Bool("disable", false, "pause managing this table (keeps the row)")
	printSQL := fs.Bool("print-sql", false, "print the UPDATE instead of running it")
	fs.Usage = simpleUsage(fs, "set", `set — change lifecycle fields on a managed table (only the flags you pass change).

USAGE:
  <binary> set --table <name> [field flags | --enable | --disable] (--dsn <dsn> | --config <yaml>)

EXAMPLES:
  partitioner set --config cf.yaml --table events --retention "24 months"   # change retention
  archiver     set --config cf.yaml --table events --hot-period "2 weeks"    # change tier age
  partitioner set --config cf.yaml --table events --disable                  # pause (keep the row)
  partitioner set --config cf.yaml --table events --print-sql --premake 6    # review the UPDATE`)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *table == "" {
		fs.Usage()
		return fmt.Errorf("--table is required")
	}
	if *enable && *disable {
		return fmt.Errorf("--enable and --disable are mutually exclusive")
	}
	var sets []string
	fs.Visit(func(f *flag.Flag) {
		switch f.Name {
		case "period":
			sets = append(sets, "partition_period="+lit(*period))
		case "column":
			sets = append(sets, "partition_column="+lit(*column))
		case "premake":
			sets = append(sets, fmt.Sprintf("future_partitions=%d", *premake))
		case "hot-period":
			sets = append(sets, "hot_period="+lit(*hot))
		case "retention":
			sets = append(sets, "retention_period="+lit(*retention))
		case "sub-values-source":
			sets = append(sets, "sub_part_values_source="+lit(*subValues))
		case "enable":
			sets = append(sets, "enabled=true")
		case "disable":
			sets = append(sets, "enabled=false")
		}
	})
	if len(sets) == 0 {
		return fmt.Errorf("nothing to change: pass a field flag or --enable/--disable")
	}
	sql := fmt.Sprintf("UPDATE coldfront.partition_config SET %s WHERE schema_name=%s AND table_name=%s;",
		strings.Join(sets, ", "), lit(*schema), lit(*table))
	if *printSQL {
		fmt.Println(sql)
		return nil
	}
	pool, err := connect(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := EnsureTable(ctx, pool); err != nil {
		return err
	}
	tag, err := pool.Exec(ctx, sql)
	if err != nil {
		return fmt.Errorf("set %s.%s: %w", *schema, *table, err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("%s.%s is not managed (no partition_config row)", *schema, *table)
	}
	fmt.Printf("updated %s.%s\n", *schema, *table)
	return nil
}

// runRemove unregisters a table (deletes its config row); the table itself is
// left intact.
func runRemove(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("remove", flag.ContinueOnError)
	connect := addConn(fs)
	schema := fs.String("schema", "public", "schema of the managed table")
	table := fs.String("table", "", "name of the managed table (required)")
	printSQL := fs.Bool("print-sql", false, "print the DELETE instead of running it")
	fs.Usage = simpleUsage(fs, "remove", `remove — stop managing a table (delete its partition_config row).

The partitioned table itself is NOT dropped — only its lifecycle registration is
removed. Drop the table separately if you intend to destroy the data.

USAGE:
  <binary> remove --table <name> (--dsn <dsn> | --config <yaml>)

EXAMPLE:
  partitioner remove --config cf.yaml --table events`)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *table == "" {
		fs.Usage()
		return fmt.Errorf("--table is required")
	}
	sql := fmt.Sprintf("DELETE FROM coldfront.partition_config WHERE schema_name=%s AND table_name=%s;",
		lit(*schema), lit(*table))
	if *printSQL {
		fmt.Println(sql)
		return nil
	}
	pool, err := connect(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := EnsureTable(ctx, pool); err != nil {
		return err
	}
	tag, err := pool.Exec(ctx, sql)
	if err != nil {
		return fmt.Errorf("remove %s.%s: %w", *schema, *table, err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("%s.%s was not managed", *schema, *table)
	}
	fmt.Printf("unregistered %s.%s (the table itself is left intact)\n", *schema, *table)
	return nil
}

// runImport seeds partition_config from a deployment YAML's archiver.tables —
// the migration path off the YAML deprecation bridge.
func runImport(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	cfgPath := fs.String("config", "", "deployment YAML to import: its archiver.tables become partition_config rows (required)")
	dsn := fs.String("dsn", "", "connection DSN (default: postgres.dsn from --config)")
	printSQL := fs.Bool("print-sql", false, "print the INSERTs instead of running them")
	dryRun := fs.Bool("dry-run", false, "validate/parse but make no changes")
	fs.Usage = simpleUsage(fs, "import", `import — load a deployment YAML's archiver.tables into coldfront.partition_config.

The migration path off the YAML bridge: register every table from an existing
config file in one shot. Connection config (DSN, iceberg/S3) is NOT imported —
it stays per-node.

USAGE:
  <binary> import --config <yaml> [--dsn <dsn>]

EXAMPLES:
  partitioner import --config legacy.yaml                 # import its tables
  partitioner import --config legacy.yaml --print-sql     # review the INSERTs first`)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *cfgPath == "" {
		fs.Usage()
		return fmt.Errorf("--config is required (the YAML to import)")
	}
	cfg, err := config.Load(*cfgPath)
	if err != nil {
		return fmt.Errorf("read --config: %w", err)
	}
	if len(cfg.Archiver.Tables) == 0 {
		return fmt.Errorf("no archiver.tables in %s", *cfgPath)
	}
	stmts := make([]string, len(cfg.Archiver.Tables))
	for i, t := range cfg.Archiver.Tables {
		stmts[i] = rowFrom(t).insertSQL()
	}
	if *printSQL {
		for _, s := range stmts {
			fmt.Println(s)
		}
		return nil
	}
	d := *dsn
	if d == "" {
		d = cfg.Postgres.DSN
	}
	if d == "" {
		return fmt.Errorf("no DSN: set postgres.dsn in --config or pass --dsn")
	}
	pool, err := openPool(ctx, d)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := EnsureTable(ctx, pool); err != nil {
		return err
	}
	if *dryRun {
		fmt.Printf("dry-run OK: would import %d table(s)\n", len(stmts))
		return nil
	}
	for i, s := range stmts {
		if _, err := pool.Exec(ctx, s); err != nil {
			return fmt.Errorf("import %s: %w", cfg.Archiver.Tables[i].SourceTable, err)
		}
	}
	fmt.Printf("imported %d table(s) into coldfront.partition_config\n", len(stmts))
	return nil
}

// runExport dumps the managed tables back to YAML (round-trippable config) or as
// INSERT SQL — the GitOps clawback: keep a reviewable copy in git.
func runExport(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	connect := addConn(fs)
	format := fs.String("format", "yaml", "output format: yaml | sql")
	fs.Usage = simpleUsage(fs, "export", `export — dump partition_config to reviewable config (yaml) or INSERT SQL.

The GitOps clawback: commit the output to keep an auditable, version-controlled
copy of what is being managed.

USAGE:
  <binary> export [--format yaml|sql] (--dsn <dsn> | --config <yaml>)

EXAMPLES:
  partitioner export --config cf.yaml > managed.yaml      # round-trippable YAML
  partitioner export --config cf.yaml --format sql        # INSERT statements`)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *format != "yaml" && *format != "sql" {
		return fmt.Errorf("--format must be yaml or sql")
	}
	pool, err := connect(ctx)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := EnsureTable(ctx, pool); err != nil {
		return err
	}
	tables, err := LoadTables(ctx, pool)
	if err != nil {
		return err
	}
	if *format == "sql" {
		for _, t := range tables {
			fmt.Println(rowFrom(t).insertSQL())
		}
		return nil
	}
	doc := struct {
		Archiver config.ArchiverConfig `yaml:"archiver"`
	}{Archiver: config.ArchiverConfig{Tables: tables}}
	out, err := yaml.Marshal(doc)
	if err != nil {
		return fmt.Errorf("marshal yaml: %w", err)
	}
	fmt.Print(string(out))
	return nil
}

// simpleUsage builds a FlagSet usage func that prints help text then the flags.
func simpleUsage(fs *flag.FlagSet, _, help string) func() {
	return func() {
		_, _ = fmt.Fprint(fs.Output(), help+"\n\nFLAGS:\n")
		fs.PrintDefaults()
	}
}
