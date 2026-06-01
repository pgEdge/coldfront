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

	"github.com/pgedge/coldfront/internal/config"
)

// Commands is the set of management subcommands both binaries expose. Each runs
// against coldfront.partition_config (the replicated source of truth) and is a
// thin, dependency-free SQL operation — so it works identically on a vanilla
// stock-PG partitioner node and an iceberg-backed archiver node.
var Commands = map[string]func(ctx context.Context, args []string) error{
	"register": runRegister,
	"list":     runList,
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
	return []string{"register", "list"}
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
		pool, err := pgxpool.New(ctx, d)
		if err != nil {
			return nil, fmt.Errorf("connect: %w", err)
		}
		if err := pool.Ping(ctx); err != nil {
			pool.Close()
			return nil, fmt.Errorf("ping: %w", err)
		}
		return pool, nil
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
	col := func(s string) string {
		if s == "" {
			return "NULL"
		}
		return "'" + strings.ReplaceAll(s, "'", "''") + "'"
	}
	return fmt.Sprintf(`INSERT INTO coldfront.partition_config
  (schema_name, table_name, partition_period, partition_column, future_partitions,
   part_mode, id_scheme, hot_period, retention_period, sub_part_values_source)
VALUES (%s, %s, %s, %s, %d, %s, %s, %s, %s, %s);`,
		col(r.schema), col(r.table), col(r.period), col(r.column), r.premake,
		col(r.partMode), col(r.idScheme), col(r.hot), col(r.retention), col(r.subValues))
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
