package view

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/pgedge/coldfront/internal/sqlutil"
)

// DBTX abstracts *pgx.Conn and pgx.Tx for testability.
type DBTX interface {
	Exec(ctx context.Context, sql string, arguments ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ViewConfig holds all parameters needed to generate the view and triggers.
type ViewConfig struct {
	SourceSchema    string
	SourceTable     string // original table name — becomes the view name after swap
	IcebergTable    string // attached catalog ref, e.g. ice.default.events
	CutoffTime      time.Time
	PartitionColumn string
	Columns         []Column
}

// Column holds a column name, its DuckDB types, and key-participation flags.
// Populated by archiver's getColumns from PG's format_type via
// pgFormatTypeToDuckDB.
//
// Type is the **storage** type — what we declare to Iceberg via CREATE TABLE
// (BIGINT, VARCHAR, DECIMAL(20,5), …). For PG types Iceberg can't represent
// natively (jsonb/json, interval), Type is the closest Iceberg primitive
// (VARCHAR) and ViewCastType carries the user-facing type the view exposes by
// casting both UNION branches. ViewCastType is also set for native-storage
// types whose storage name isn't PG-parseable (bytea → bytea on BLOB, double
// precision → double precision on DOUBLE) so the hot-side cast spells a real
// PG type.
//
// ViewCastType empty → both branches cast to Type (the storage type).
// ViewCastType non-empty → view emits `col::<ViewCastType>` on hot side and
// `r['col']::<ViewCastType>` on cold side, so applications see the surface type
// (json, interval, bytea, double precision) regardless of the storage form.
type Column struct {
	Name         string
	Type         string // storage / DuckDB-CREATE-TABLE type, e.g. "BIGINT", "VARCHAR", "DECIMAL(20,5)"
	ViewCastType string // optional surface-type cast emitted by the view, e.g. "json", "interval", "bytea"
	IsIdentity   bool   // pg_attribute.attidentity = 'a' (GENERATED ALWAYS) — skip from INSERT
	IsPK         bool   // participates in primary key (pg_index.indisprimary)
}

// Generator creates and replaces the view and triggers.
type Generator struct {
	db DBTX
}

// NewGenerator creates a new view Generator.
func NewGenerator(db DBTX) *Generator {
	return &Generator{db: db}
}

// hasCutoff reports whether a watermark cutoff is set. A zero CutoffTime
// means the archiver has not yet archived any partition for this table, so
// the generated view has no cold side.
func (c ViewConfig) hasCutoff() bool {
	return !c.CutoffTime.IsZero()
}

// cutoffLiteral formats the cutoff as a SQL timestamp literal in UTC
// suitable for embedding in the generated view definition.
func (c ViewConfig) cutoffLiteral() string {
	return c.CutoffTime.UTC().Format("2006-01-02 15:04:05+00")
}

// fqSource returns the fully qualified original table name (which becomes the view).
func (c ViewConfig) fqSource() string {
	return pgx.Identifier{c.SourceSchema, c.SourceTable}.Sanitize()
}

// fqHot returns the fully qualified renamed hot table (_{source}).
func (c ViewConfig) fqHot() string {
	return pgx.Identifier{c.SourceSchema, "_" + c.SourceTable}.Sanitize()
}

// hotTable returns the renamed table name (_{source}) as a quoted, unqualified
// identifier. Used as the target of ALTER TABLE ... RENAME TO, which requires
// an unqualified identifier.
func (c ViewConfig) hotTable() string {
	return pgx.Identifier{"_" + c.SourceTable}.Sanitize()
}

// insertCols returns column names and NEW."col" refs for INSERT.
// Skips GENERATED ALWAYS AS IDENTITY columns (cannot accept explicit values).
// No per-type cast: the view exposes each column in its native PG type (jsonb
// stays jsonb, etc.), so NEW.col arrives at the trigger already matching the
// underlying _events column type.
func (c ViewConfig) insertCols() (colList, valList string) {
	var cols, vals []string
	for _, col := range c.Columns {
		if col.IsIdentity {
			continue
		}
		q := pgx.Identifier{col.Name}.Sanitize()
		cols = append(cols, q)
		vals = append(vals, "NEW."+q)
	}
	return strings.Join(cols, ", "), strings.Join(vals, ", ")
}

// coldInsertVals returns the format() args for the cold INSERT via
// duckdb.raw_query(format(...)). Identity columns are excluded (same as hot).
// Each arg pairs positionally with a %L placeholder from coldInsertPlaceholders.
//
//   - VARCHAR-backed rich types (jsonb/json/interval — Type=="VARCHAR" with a
//     ViewCastType): serialised via ::text, since their Iceberg column is VARCHAR.
//   - bytea (Type=="BLOB"): emitted as encode(NEW.col,'hex') and wrapped by a
//     from_hex(%L) placeholder. The cold INSERT goes through %L, which renders a
//     bytea as PG's '\xcafe' text — which DuckDB then MIS-parses into a BLOB
//     (\xca → 1 byte, fe → 2 literal bytes = 3 bytes, corruption). Round-tripping
//     the hex string through DuckDB's from_hex() rebuilds the exact bytes.
//   - everything else (incl. double precision, whose '2.5' text round-trips
//     cleanly through DuckDB): NEW.col as-is.
//
// This must stay consistent with the archiver's bulk-export path, which writes
// bytea natively because pg_duckdb scans it directly (no %L stringification).
func (c ViewConfig) coldInsertVals() string {
	var vals []string
	for _, col := range c.Columns {
		if col.IsIdentity {
			continue
		}
		q := pgx.Identifier{col.Name}.Sanitize()
		switch {
		case col.Type == "BLOB":
			vals = append(vals, "encode(NEW."+q+",'hex')")
		case col.Type == "VARCHAR" && col.ViewCastType != "":
			vals = append(vals, "NEW."+q+"::text")
		default:
			vals = append(vals, "NEW."+q)
		}
	}
	return strings.Join(vals, ", ")
}

// coldInsertPlaceholders returns positional value placeholders for the cold
// INSERT via PG's format() call.  Identity columns use literal NULL (Iceberg
// has no sequences); bytea uses from_hex(%L) so DuckDB reconstructs the exact
// bytes from the hex string (see coldInsertVals); all other columns use %L so
// format() quotes them safely. DuckDB/Iceberg does not support targeted inserts
// (INSERT INTO t(col) ...), so we emit a positional INSERT INTO t VALUES (...).
func (c ViewConfig) coldInsertPlaceholders() string {
	var ph []string
	for _, col := range c.Columns {
		switch {
		case col.IsIdentity:
			ph = append(ph, "NULL")
		case col.Type == "BLOB":
			ph = append(ph, "from_hex(%L)")
		default:
			ph = append(ph, "%L")
		}
	}
	return strings.Join(ph, ", ")
}

// GenerateSwapSQL generates the conditional rename of the source table to _{source}.
// Idempotent: only renames if the source is still a regular table (not already a view).
//
// Note: the WHERE clause compares against pg_class.relname / pg_namespace.nspname,
// which store the raw (unquoted) name. Those positions take SQL string literals
// (sqlutil.Literal), not identifier-quoted names. The ALTER TABLE target positions
// take identifiers (pgx.Identifier via fqSource / hotTable).
func GenerateSwapSQL(cfg ViewConfig) string {
	return fmt.Sprintf(`DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = %s AND c.relname = %s AND c.relkind = 'p') THEN
    ALTER TABLE %s RENAME TO %s;
  END IF;
END $$`,
		sqlutil.Literal(cfg.SourceSchema), sqlutil.Literal(cfg.SourceTable),
		cfg.fqSource(), cfg.hotTable())
}

// GenerateViewSQL generates the unified view replacing the original table name.
// Hot data comes from _{source}, cold data from iceberg_scan.
//
// IMPORTANT: column types in the projected view are stable across cutoffs.
// Bootstrap (cutoff=zero) emits the hot-only branch but with the same casts
// as a post-cutover view, so subsequent CREATE OR REPLACE VIEW calls don't
// trip PG's "cannot change data type of view column" rule.
func GenerateViewSQL(cfg ViewConfig) string {
	viewName := cfg.fqSource()

	col := pgx.Identifier{cfg.PartitionColumn}.Sanitize()
	coldColKey := strings.ReplaceAll(cfg.PartitionColumn, "'", "''")

	hotCols := make([]string, len(cfg.Columns))
	coldCols := make([]string, len(cfg.Columns))
	for i, c := range cfg.Columns {
		hotName := pgx.Identifier{c.Name}.Sanitize()
		coldKey := strings.ReplaceAll(c.Name, "'", "''")
		// surface = the type the view exposes for this column, and the type
		// BOTH UNION branches cast to. ViewCastType wins when the Iceberg
		// storage type isn't the surface we want (DOUBLE→double precision,
		// BLOB→bytea, VARCHAR→json/interval). Otherwise the storage type
		// IS the surface — every storage type in this branch (BIGINT, INTEGER,
		// VARCHAR, DECIMAL(P,S), TIMESTAMPTZ, …) is both PG-parseable and
		// DuckDB-valid by construction.
		//
		// Casting BOTH branches to the surface is what keeps the view's column
		// types identical at bootstrap (hot-only) and after cutover (UNION),
		// satisfying CREATE OR REPLACE VIEW's "cannot change data type" rule.
		// Without the hot-side cast, a native typmod (varchar(8)) would survive
		// bootstrap but the UNION with the un-typmod'd cold cast would drop it,
		// changing the column type on cutover.
		//
		// pg_duckdb takes over the whole query once iceberg_scan appears in the
		// FROM, so the cast runs inside DuckDB on the cutover view; on the
		// bootstrap (hot-only) view it runs in plain PG. The surface types are
		// valid in both engines, so the resulting PG column type matches.
		surface := c.Type
		if c.ViewCastType != "" {
			surface = c.ViewCastType
		}
		hotCols[i] = hotName + "::" + surface
		coldCols[i] = fmt.Sprintf("r['%s']::%s", coldKey, surface)
	}

	// Bootstrap path (no cutoff yet): hot-only, but cast columns to the
	// same types we'll project once the cold side appears.
	if !cfg.hasCutoff() {
		return fmt.Sprintf(
			"CREATE OR REPLACE VIEW %s AS\n  SELECT %s FROM %s",
			viewName, strings.Join(hotCols, ", "), cfg.fqHot())
	}

	cutoff := cfg.cutoffLiteral()
	// iceberg_scan('...') argument is a DuckDB string literal (the catalog
	// table ref), not a SQL identifier. Escape apostrophes only.
	iceArg := strings.ReplaceAll(cfg.IcebergTable, "'", "''")

	return fmt.Sprintf(
		`CREATE OR REPLACE VIEW %s AS
  SELECT %s FROM %s
  WHERE %s >= '%s'::timestamptz
  UNION ALL
  SELECT %s
  FROM iceberg_scan('%s') r
  WHERE r['%s'] < '%s'::timestamptz`,
		viewName,
		strings.Join(hotCols, ", "), cfg.fqHot(),
		col, cutoff,
		strings.Join(coldCols, ", "),
		iceArg,
		coldColKey, cutoff)
}

// GenerateTriggerFuncSQL generates the INSTEAD OF INSERT trigger function for
// the unified view. Hot inserts go to _{source}; cold inserts are forwarded
// to Iceberg via duckdb.raw_query. UPDATE/DELETE are handled by the
// coldfront C extension's post_parse_analyze_hook rewrite, not this trigger.
func GenerateTriggerFuncSQL(cfg ViewConfig) string {
	funcName := pgx.Identifier{"coldfront", cfg.SourceTable + "_write"}.Sanitize()
	fqHot := cfg.fqHot()
	col := pgx.Identifier{cfg.PartitionColumn}.Sanitize()

	cutoff := "'-infinity'::timestamptz"
	if cfg.hasCutoff() {
		cutoff = fmt.Sprintf("'%s'::timestamptz", cfg.cutoffLiteral())
	}

	colList, hotVals := cfg.insertCols()
	coldPlaceholders := cfg.coldInsertPlaceholders()
	coldVals := cfg.coldInsertVals()

	// cfg.IcebergTable is the ref DuckDB parses (not a PG identifier); embed
	// it in the format() template as-is, apostrophe-escaped so it survives
	// PG's outer string-literal scan.
	iceRef := strings.ReplaceAll(cfg.IcebergTable, "'", "''")

	return fmt.Sprintf(`CREATE OR REPLACE FUNCTION %s() RETURNS trigger AS $fn$
DECLARE
  cutoff timestamptz;
BEGIN
  SELECT cutoff_time INTO cutoff FROM coldfront.archive_watermark WHERE table_name = %s;
  IF cutoff IS NULL THEN
    cutoff := %s;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.%s < cutoff THEN
      PERFORM coldfront.ensure_attached();
      PERFORM duckdb.raw_query(format(
        'INSERT INTO %s VALUES (%s)',
        %s
      ));
      RETURN NEW;
    END IF;
    INSERT INTO %s (%s) VALUES (%s);
    RETURN NEW;
  END IF;
  RETURN NULL;
END;
$fn$ LANGUAGE plpgsql`,
		funcName,
		sqlutil.Literal(cfg.SourceTable),
		cutoff,
		col,
		iceRef, coldPlaceholders, coldVals,
		fqHot, colList, hotVals)
}

// GenerateTriggerSQL generates the DROP + CREATE TRIGGER on the unified view.
// INSERT-only: UPDATE/DELETE are rewritten by the coldfront hook before
// they reach the view, so no trigger is needed for those operations.
func GenerateTriggerSQL(cfg ViewConfig) string {
	trigName := pgx.Identifier{cfg.SourceTable + "_write_trigger"}.Sanitize()
	viewName := cfg.fqSource()
	funcName := pgx.Identifier{"coldfront", cfg.SourceTable + "_write"}.Sanitize()

	return fmt.Sprintf(`DROP TRIGGER IF EXISTS %s ON %s;
CREATE TRIGGER %s
  INSTEAD OF INSERT ON %s
  FOR EACH ROW EXECUTE FUNCTION %s()`,
		trigName, viewName,
		trigName, viewName, funcName)
}

// Recreate performs the table→view swap (if needed) and recreates the view + triggers.
func (g *Generator) Recreate(ctx context.Context, cfg ViewConfig) error {
	stmts := []string{
		GenerateSwapSQL(cfg),
		GenerateViewSQL(cfg),
		GenerateTriggerFuncSQL(cfg),
		GenerateTriggerSQL(cfg),
	}
	for _, sql := range stmts {
		if _, err := g.db.Exec(ctx, sql); err != nil { // nosemgrep
			return fmt.Errorf("recreate view: %w", err)
		}
	}
	return nil
}
