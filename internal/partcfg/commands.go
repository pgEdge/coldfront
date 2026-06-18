package partcfg

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/jackc/pgx/v5"
	"gopkg.in/yaml.v3"

	"github.com/pgedge/coldfront/internal/config"
	"github.com/pgedge/coldfront/internal/partition"
)

// command is one management subcommand: its name, a one-line summary for the
// top-level overview, and its handler. This slice is the SINGLE source for both
// dispatch (Run/IsCommand) and the overview (PrintTopLevelUsage), so adding a
// command in one place can't drift from the other. Each handler runs against
// coldfront.partition_config (the replicated source of truth) as a thin,
// dependency-free SQL operation — identical on a vanilla stock-PG partitioner
// node and an iceberg-backed archiver node.
type command struct {
	name, summary string
	run           func(ctx context.Context, args []string) error
}

var commands = []command{
	{"register", "add or adopt a partitioned table (validates the PK covers the partition key)", runRegister},
	{"list", "show the managed tables and their lifecycle", runList},
	{"set", "change a managed table's fields, or --enable / --disable it", runSet},
	{"remove", "stop managing a table (the table itself is left intact)", runRemove},
	{"import", "seed the config table from a deployment YAML's archiver.tables", runImport},
	{"export", "dump the active config to YAML or SQL (a git-reviewable copy)", runExport},
}

// IsCommand reports whether name is a management subcommand (so the binary
// routes to it instead of its default reconcile/archive run).
func IsCommand(name string) bool {
	for _, c := range commands {
		if c.name == name {
			return true
		}
	}
	return false
}

// Run dispatches a management subcommand (args is everything after the
// subcommand word). An explicit --help prints the subcommand's usage and is
// treated as success (exit 0), not an error.
func Run(ctx context.Context, name string, args []string) error {
	for _, c := range commands {
		if c.name == name {
			err := c.run(ctx, args)
			if errors.Is(err, flag.ErrHelp) {
				return nil
			}
			return err
		}
	}
	return fmt.Errorf("unknown command %q", name)
}

// CommandNames returns the subcommand words in order.
func CommandNames() []string {
	names := make([]string, len(commands))
	for i, c := range commands {
		names[i] = c.name
	}
	return names
}

// PrintTopLevelUsage prints the program synopsis + the subcommand overview, so
// the management commands are discoverable from `<binary>` / `<binary> --help`.
// defaultDesc says what the binary does with no subcommand (its --config run).
func PrintTopLevelUsage(w io.Writer, prog, defaultDesc string) {
	_, _ = fmt.Fprintf(w, `%s — coldfront partition lifecycle management.

USAGE:
  %s --config <yaml>      %s
  %s <command> [flags]    manage the partition_config table (any node; replicates on a mesh)

COMMANDS:
`, prog, prog, defaultDesc, prog)
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	for _, c := range commands {
		_, _ = fmt.Fprintf(tw, "  %s\t%s\n", c.name, c.summary)
	}
	_ = tw.Flush()
	_, _ = fmt.Fprintf(w, "\nRun \"%s <command> --help\" for detailed help and examples.\n", prog)
}

// addConn registers the shared --dsn / --config connection flags on fs and
// returns accessors. Management commands connect with --dsn directly, or read
// the DSN from the same --config YAML the runtime uses.
func addConn(fs *flag.FlagSet) func(context.Context) (*pgx.Conn, error) {
	dsn := fs.String("dsn", "", "PostgreSQL connection string (or use --config)")
	cfgPath := fs.String("config", "", "path to the deployment YAML; its postgres.dsn is used if --dsn is unset")
	return func(ctx context.Context) (*pgx.Conn, error) {
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
		return openConn(ctx, d)
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
	strategy := fs.String("strategy", "drop", "partition-only expiry past retention: drop (DETACH+DROP, destroy) | detach (DETACH only, keep as a standalone table)")
	printSQL := fs.Bool("print-sql", false, "print the INSERT (and any DDL) instead of running it — for git/audit")
	dryRun := fs.Bool("dry-run", false, "validate everything but make no changes")
	fs.Usage = registerUsage(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if err := validateRegisterFlags(fs, *table, *period, *hot, *retention, *strategy); err != nil {
		return err
	}

	row := configRow{
		schema: *schema, table: *table, period: *period, column: *column,
		premake: *premake, partMode: *partMode, idScheme: *idScheme,
		hot: *hot, retention: *retention, subValues: *subValues,
		strategy: *strategy,
	}
	if *printSQL {
		fmt.Println(row.insertSQL())
		return nil
	}
	return registerToDB(ctx, connect, row, *dryRun)
}

// registerToDB runs the connect-and-validate tail of register: it connects,
// ensures the config table, validates the PK covers the partition key, checks
// the interval semantics, then INSERTs the row (or prints the dry-run summary).
func registerToDB(ctx context.Context, connect func(context.Context) (*pgx.Conn, error), row configRow, dryRun bool) error {
	twoLevel := row.subValues != ""
	insertSQL := row.insertSQL()
	conn, err := connect(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := EnsureTable(ctx, conn); err != nil {
		return err
	}
	// PK-superset validation: the cutover keys delta capture by the source PK,
	// so the PK must cover the partition key column(s). 2-level adds the RANGE
	// column (the LIST column comes from the catalog).
	if err := validatePKSuperset(ctx, conn, row.schema, row.table, row.column, twoLevel); err != nil {
		return err
	}
	// Period validity + retention>hot ordering are PostgreSQL interval semantics,
	// so they're checked against the connection (fail fast at register time; the
	// interval column type is the backstop for any direct write).
	if err := partition.ValidatePeriods(ctx, conn, row.hot, row.retention); err != nil {
		return err
	}
	if dryRun {
		fmt.Printf("dry-run OK: %s.%s validates; would run:\n%s\n", row.schema, row.table, insertSQL)
		return nil
	}
	if _, err := conn.Exec(ctx, insertSQL); err != nil { // nosemgrep
		return fmt.Errorf("register %s.%s: %w", row.schema, row.table, err)
	}
	fmt.Printf("registered %s.%s\n", row.schema, row.table)
	return nil
}

// validateRegisterFlags checks the register flag combination before any DB work:
// required flags are present, a destroy boundary is set, and --strategy is valid
// (detach is partition-only). It prints usage on the required-flag failure, matching
// the flag package's own convention.
func validateRegisterFlags(fs *flag.FlagSet, table, period, hot, retention, strategy string) error {
	if table == "" || period == "" {
		fs.Usage()
		return fmt.Errorf("--table and --period are required")
	}
	if retention == "" && hot == "" {
		return fmt.Errorf("set --retention (and/or --hot-period): a managed table needs a destroy boundary")
	}
	switch strategy {
	case partition.StrategyDrop, partition.StrategyDetach:
	default:
		return fmt.Errorf("--strategy %q must be %q or %q", strategy, partition.StrategyDetach, partition.StrategyDrop)
	}
	if strategy == partition.StrategyDetach && hot != "" {
		return fmt.Errorf("--strategy detach is only valid in partition-only mode (no --hot-period)")
	}
	return nil
}

func registerUsage(fs *flag.FlagSet) func() {
	return func() {
		_, _ = fmt.Fprint(fs.Output(), `register — add (or adopt) a partitioned table to partition lifecycle management.

Validates the table is partitioned and that its PRIMARY KEY covers the partition
key (required for race-safe cutover), then writes a coldfront.partition_config
row. Lifecycle rules are enforced at write time — structural rules by CHECK
constraints, period syntax by the interval column type, and retention > hot-period
by a calendar-aware interval comparison. --hot-period / --retention accept any
PostgreSQL interval (e.g. "1 month", "90 days", "1 year 2 mons").

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

EXAMPLES:
  partitioner list --config cf.yaml             # connect via the deployment YAML's DSN
  archiver     list --dsn "host=db dbname=app"  # or pass a DSN directly

FLAGS:
`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return err
	}
	conn, err := connect(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := EnsureTable(ctx, conn); err != nil {
		return err
	}
	rows, err := conn.Query(ctx, `
		SELECT schema_name, table_name, partition_period,
		       COALESCE(hot_period::text,'-'), COALESCE(retention_period::text,'-'),
		       CASE WHEN hot_period IS NULL THEN 'partition-only' ELSE 'tiered' END,
		       CASE WHEN sub_part_values_source IS NULL THEN 'flat' ELSE '2-level' END,
		       expiration_strategy, enabled
		FROM coldfront.partition_config ORDER BY schema_name, table_name`)
	if err != nil {
		return fmt.Errorf("query partition_config: %w", err)
	}
	defer rows.Close()
	return printList(os.Stdout, rows)
}

func printList(w io.Writer, rows pgx.Rows) error {
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "TABLE\tPERIOD\tHOT\tRETENTION\tMODE\tSHAPE\tEXPIRY\tENABLED")
	n := 0
	for rows.Next() {
		var schema, table, period, hot, ret, mode, shape, strategy string
		var enabled bool
		if err := rows.Scan(&schema, &table, &period, &hot, &ret, &mode, &shape, &strategy, &enabled); err != nil {
			return err
		}
		_, _ = fmt.Fprintf(tw, "%s.%s\t%s\t%s\t%s\t%s\t%s\t%s\t%t\n", schema, table, period, hot, ret, mode, shape, strategy, enabled)
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
	strategy                      string
}

func (r configRow) insertSQL() string {
	return fmt.Sprintf(`INSERT INTO coldfront.partition_config
  (schema_name, table_name, partition_period, partition_column, future_partitions,
   part_mode, id_scheme, hot_period, retention_period, sub_part_values_source, expiration_strategy)
VALUES (%s, %s, %s, %s, %d, %s, %s, %s, %s, %s, %s);`,
		lit(r.schema), lit(r.table), lit(r.period), lit(r.column), r.premake,
		lit(r.partMode), lit(r.idScheme), lit(r.hot), lit(r.retention), lit(r.subValues), lit(r.strategy))
}

// validatePKSuperset confirms the table's PRIMARY KEY covers the partition key.
// requiredCols = the parent's partition-key column(s); for a 2-level table the
// parent's key is the LIST column and the RANGE column (rangeCol) is added.
func validatePKSuperset(ctx context.Context, db DBTX, schema, table, rangeCol string, twoLevel bool) error {
	required, err := requiredPartKeyCols(ctx, db, schema, table, rangeCol, twoLevel)
	if err != nil {
		return err
	}
	return checkPKCovers(ctx, db, schema, table, required)
}

// requiredPartKeyCols reads the parent's partition key and returns the column
// set the PK must cover: the parent's key column(s) plus the RANGE column for a
// 2-level table. The first query's rows are closed explicitly (not deferred) so
// it does not overlap the PK query on the same connection.
func requiredPartKeyCols(ctx context.Context, db DBTX, schema, table, rangeCol string, twoLevel bool) (map[string]bool, error) {
	prows, err := db.Query(ctx, `
		SELECT pg_get_partkeydef(c.oid)
		FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'p'`, schema, table)
	if err != nil {
		return nil, fmt.Errorf("read partition key for %s.%s: %w", schema, table, err)
	}
	var partkeydef string
	for prows.Next() {
		if err := prows.Scan(&partkeydef); err != nil {
			prows.Close()
			return nil, err
		}
	}
	prows.Close()
	if err := prows.Err(); err != nil {
		return nil, err
	}
	if partkeydef == "" {
		return nil, fmt.Errorf("%s.%s is not a partitioned table (or does not exist)", schema, table)
	}
	return requiredColsFromPartKey(partkeydef, rangeCol, twoLevel), nil
}

// requiredColsFromPartKey parses a pg_get_partkeydef string into the set of
// partition-key columns, adding the explicit 2-level RANGE column when present.
func requiredColsFromPartKey(partkeydef, rangeCol string, twoLevel bool) map[string]bool {
	required := map[string]bool{}
	for _, c := range partKeyCols(partkeydef) {
		required[c] = true
	}
	if twoLevel && rangeCol != "" {
		required[rangeCol] = true
	}
	return required
}

// checkPKCovers reads the table's PRIMARY KEY and confirms it covers every
// required partition-key column.
func checkPKCovers(ctx context.Context, db DBTX, schema, table string, required map[string]bool) error {
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

// openConn connects and verifies the connection.
func openConn(ctx context.Context, dsn string) (*pgx.Conn, error) {
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	if err := conn.Ping(ctx); err != nil {
		_ = conn.Close(ctx)
		return nil, fmt.Errorf("ping: %w", err)
	}
	return conn, nil
}

// rowFrom maps a config.TableConfig (e.g. from a YAML being imported) onto a
// configRow, applying the same defaults as the YAML loader so the INSERT is valid.
func rowFrom(t config.TableConfig) configRow {
	r := configRow{
		schema: t.SourceSchema, table: t.SourceTable, period: t.PartitionPeriod,
		column: t.PartitionColumn, premake: t.FuturePartitions, partMode: t.PartMode,
		idScheme: t.IDScheme, hot: t.HotPeriod, retention: t.RetentionPeriod,
		strategy: t.ExpirationStrategy,
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
	if r.strategy == "" {
		r.strategy = partition.StrategyDrop
	}
	return r
}

// setVals holds the set-command flag values a clause builder may read.
type setVals struct {
	period, column            string
	premake                   int
	hot, retention, subValues string
	strategy                  string
}

// setClauses maps each set flag name to the UPDATE clause it emits. Only flags
// the user actually passed (via fs.Visit) are looked up here, so an unset flag
// never emits a clause — this is what lets --hot-period "" clear the column
// while an omitted --hot-period leaves it untouched. --enable/--disable ignore
// vals and emit a constant.
var setClauses = map[string]func(setVals) string{
	"period":            func(v setVals) string { return "partition_period=" + lit(v.period) },
	"column":            func(v setVals) string { return "partition_column=" + lit(v.column) },
	"premake":           func(v setVals) string { return fmt.Sprintf("future_partitions=%d", v.premake) },
	"hot-period":        func(v setVals) string { return "hot_period=" + lit(v.hot) },
	"retention":         func(v setVals) string { return "retention_period=" + lit(v.retention) },
	"sub-values-source": func(v setVals) string { return "sub_part_values_source=" + lit(v.subValues) },
	"strategy":          func(v setVals) string { return "expiration_strategy=" + lit(v.strategy) },
	"enable":            func(setVals) string { return "enabled=true" },
	"disable":           func(setVals) string { return "enabled=false" },
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
	strategy := fs.String("strategy", "", "change expiry strategy: drop | detach (partition-only)")
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
	vals := setVals{period: *period, column: *column, premake: *premake, hot: *hot, retention: *retention, subValues: *subValues, strategy: *strategy}
	sets := collectSetClauses(fs, vals)
	if len(sets) == 0 {
		return fmt.Errorf("nothing to change: pass a field flag or --enable/--disable")
	}
	sql := fmt.Sprintf("UPDATE coldfront.partition_config SET %s WHERE schema_name=%s AND table_name=%s;",
		strings.Join(sets, ", "), lit(*schema), lit(*table))
	if *printSQL {
		fmt.Println(sql)
		return nil
	}
	return execSet(ctx, connect, *schema, *table, sql)
}

// collectSetClauses walks the flags the user actually set (fs.Visit) and returns
// the SET clauses for the recognised field flags, in flag-declaration order.
func collectSetClauses(fs *flag.FlagSet, vals setVals) []string {
	var sets []string
	fs.Visit(func(f *flag.Flag) {
		if clause, ok := setClauses[f.Name]; ok {
			sets = append(sets, clause(vals))
		}
	})
	return sets
}

// execSet connects, ensures the config table, and runs the UPDATE; a zero
// row-count means the table isn't managed.
func execSet(ctx context.Context, connect func(context.Context) (*pgx.Conn, error), schema, table, sql string) error {
	conn, err := connect(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := EnsureTable(ctx, conn); err != nil {
		return err
	}
	tag, err := conn.Exec(ctx, sql) // nosemgrep
	if err != nil {
		return fmt.Errorf("set %s.%s: %w", schema, table, err)
	}
	if tag.RowsAffected() == 0 {
		return fmt.Errorf("%s.%s is not managed (no partition_config row)", schema, table)
	}
	fmt.Printf("updated %s.%s\n", schema, table)
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

EXAMPLES:
  partitioner remove --config cf.yaml --table events              # unregister
  partitioner remove --config cf.yaml --table events --print-sql  # review the DELETE first`)
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
	conn, err := connect(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := EnsureTable(ctx, conn); err != nil {
		return err
	}
	tag, err := conn.Exec(ctx, sql) // nosemgrep
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
	stmts := buildImportStmts(cfg.Archiver.Tables)
	if *printSQL {
		printStmts(stmts)
		return nil
	}
	d := *dsn
	if d == "" {
		d = cfg.Postgres.DSN
	}
	if d == "" {
		return fmt.Errorf("no DSN: set postgres.dsn in --config or pass --dsn")
	}
	return applyImport(ctx, d, cfg.Archiver.Tables, stmts, *dryRun)
}

// buildImportStmts renders one INSERT per table, index-aligned with tables so
// the exec loop can name the failing table by the same index.
func buildImportStmts(tables []config.TableConfig) []string {
	stmts := make([]string, len(tables))
	for i, t := range tables {
		stmts[i] = rowFrom(t).insertSQL()
	}
	return stmts
}

func printStmts(stmts []string) {
	for _, s := range stmts {
		fmt.Println(s)
	}
}

// applyImport connects, ensures the config table, then runs the import INSERTs
// (or prints the dry-run summary). tables and stmts must stay index-aligned so a
// failure names the right table.
func applyImport(ctx context.Context, dsn string, tables []config.TableConfig, stmts []string, dryRun bool) error {
	conn, err := openConn(ctx, dsn)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := EnsureTable(ctx, conn); err != nil {
		return err
	}
	if dryRun {
		fmt.Printf("dry-run OK: would import %d table(s)\n", len(stmts))
		return nil
	}
	for i, s := range stmts {
		if _, err := conn.Exec(ctx, s); err != nil {
			return fmt.Errorf("import %s: %w", tables[i].SourceTable, err)
		}
	}
	fmt.Printf("imported %d table(s) into coldfront.partition_config\n", len(stmts))
	return nil
}

// runExport dumps the active (enabled) managed tables to YAML or INSERT SQL —
// the GitOps clawback: keep a reviewable copy in git. Disabled tables (set
// --disable) are not included; the disabled state is management-only and not
// represented in the exported config.
func runExport(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	connect := addConn(fs)
	format := fs.String("format", "yaml", "output format: yaml | sql")
	fs.Usage = simpleUsage(fs, "export", `export — dump the active (enabled) config to YAML or INSERT SQL.

The GitOps clawback: commit the output to keep an auditable, version-controlled
copy of what is being managed. NOTE: only ENABLED tables are exported — a table
paused with "set --disable" is omitted (its disabled state is not round-tripped).

USAGE:
  <binary> export [--format yaml|sql] (--dsn <dsn> | --config <yaml>)

EXAMPLES:
  partitioner export --config cf.yaml > managed.yaml      # active config as YAML
  partitioner export --config cf.yaml --format sql        # active config as INSERT statements`)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *format != "yaml" && *format != "sql" {
		return fmt.Errorf("--format must be yaml or sql")
	}
	conn, err := connect(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = conn.Close(ctx) }()
	if err := EnsureTable(ctx, conn); err != nil {
		return err
	}
	tables, err := LoadTables(ctx, conn, AllOwners) // export is ownership-agnostic
	if err != nil {
		return err
	}
	if *format == "sql" {
		return exportSQL(tables)
	}
	return exportYAML(tables)
}

// exportSQL prints one INSERT statement per table.
func exportSQL(tables []config.TableConfig) error {
	for _, t := range tables {
		fmt.Println(rowFrom(t).insertSQL())
	}
	return nil
}

// exportYAML marshals the tables under an archiver: key and prints the document.
func exportYAML(tables []config.TableConfig) error {
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
