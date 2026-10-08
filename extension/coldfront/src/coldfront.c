/*
 * coldfront.c
 *
 * post_parse_analyze_hook that intercepts INSERT/UPDATE/DELETE on registered
 * tiered views and rewrites the Query into a single-tier form based on the WHERE
 * clause predicate on the partition column, evaluated against the archive
 * watermark:
 *
 *   WHERE ts >= cutoff  → hot:  UPDATE public._events SET ... WHERE ...
 *   WHERE ts <  cutoff  → cold: SELECT duckdb.raw_query($MTQ$
 *                                 UPDATE ice.default.events SET ... WHERE ...
 *                               $MTQ$)
 *   predicate can't prove one tier → ERROR (would otherwise split a write
 *                                           across both tiers non-atomically:
 *                                           Iceberg writes are not WAL-logged).
 *
 * The hot rewrite is plain PG DML.  The cold rewrite wraps the DuckDB DML in
 * a SELECT so it doesn't trip pg_duckdb's mixed-write check (the PG
 * command-ID counter stays put), and duckdb.raw_query() runs as a regular C
 * function call.  In both cases the rewritten query holds no DuckDB table
 * function, so pg_duckdb's planner hook leaves it alone.
 *
 * INSERT is rewritten too (cf_emit_tiered_insert_path): with a watermark it
 * reads the source once and splits the rows by the partition column against
 * the cutoff into a hot INSERT into public._events and the cold sink
 * coldfront._cold_sink, which writes Iceberg in batches; with no watermark yet
 * every row is hot. Iceberg-only views short-circuit INSERT to the cold path.
 * The view has no INSTEAD OF trigger: the INSERT is rewritten off the view
 * (cf_reparse_and_replace) before the rewriter sees it, and a write the hook
 * does not rewrite fails in PostgreSQL. A MERGE runs on the tier its ON
 * condition bounds (cf_emit_merge_path): retargeted to the hot table, or in
 * DuckDB against the Iceberg table, each INSERT action guarding the inserted
 * partition value per row. Any of the four nested in a WITH entry is rewritten
 * in place, with the rewrite's own WITH entries lifted into the statement's
 * list (cf_splice_nested_dml).
 *
 * ATTACH requirement: the DuckDB 'ice' catalog alias must be attached in the
 * current session before cold DML fires.  The hook calls
 * coldfront.ensure_attached() via SPI on the cold path; it reads the
 * coldfront.warehouse / coldfront.lakekeeper_endpoint GUCs and issues
 * ATTACH IF NOT EXISTS.  The helper is installed by coldfront--1.0.sql.
 */

#include "postgres.h"

#include <ctype.h>
#include <sys/stat.h>

#include "access/attnum.h"
#include "access/relation.h"
#include "access/xact.h"
#include "catalog/dependency.h"
#include "catalog/namespace.h"
#include "catalog/objectaddress.h"
#include "catalog/pg_authid.h"
#include "catalog/pg_class.h"
#include "catalog/pg_collation.h"
#include "catalog/pg_inherits.h"
#include "catalog/pg_namespace.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type_d.h"
#include "commands/copy.h"
#include "commands/extension.h"
#include "common/string.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "nodes/makefuncs.h"
#include "nodes/parsenodes.h"
#include "nodes/nodeFuncs.h"
#include "nodes/params.h"
#include "nodes/pg_list.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "utils/pgstat_internal.h"
#include "optimizer/optimizer.h"
#include "optimizer/planner.h"
#include "parser/analyze.h"
#include "parser/parse_func.h"
#include "parser/parse_type.h"
#include "parser/parsetree.h"
#include "rewrite/rewriteHandler.h"
#include "storage/fd.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "tcop/tcopprot.h"
#include "tcop/utility.h"
#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"
#include "utils/regproc.h"
#include "utils/ruleutils.h"
#include "utils/syscache.h"
#include "utils/timeout.h"
#include "utils/timestamp.h"
#include "fmgr.h"
#include "libpq-fe.h"

PG_MODULE_MAGIC;

/* Re-entrancy guard: parse_analyze_fixedparams fires the hook again */
static bool coldfront_in_rewrite = false;

/* ===========================================================================
 * Cold-tier DML from inside plpgsql — the two problems and how this file
 * solves them. (Background for the param + dummy-table machinery below.)
 *
 * Cold DML works as a top-level statement, but from inside a plpgsql function /
 * DO block / trigger it faces TWO independent problems:
 *
 *   (1) Bound parameters. plpgsql (and any client using bind params / PREPARE
 *       / the extended protocol) compiles variable references into $N
 *       PARAM_EXTERN nodes whose VALUES are unknown at parse-analyze time —
 *       which is exactly when this hook runs (there is no executor hook). The
 *       deparser emits those $N as literal text, so the cold SQL handed to
 *       duckdb.raw_query carried "$N" with nothing to bind -> DuckDB error
 *       "Expected N parameters, but none were supplied". The hook keeps the
 *       params LIVE — it emits the cold SQL as a runtime
 *       format(<template>, $1, $2, ...) call (cold_sql_arg) and declares the
 *       param types on the re-parse, so PG binds the values at execution and
 *       DuckDB only ever sees finished literals. This applies EVERYWHERE (top
 *       level and plpgsql) and needs no table.
 *
 *   (2) Statement shape. The cold rewrite is a row-returning
 *       `SELECT coldfront._exec_iceberg_with_claim(...)`. At top level the
 *       client discards the row; but plpgsql rejects a bare result-returning
 *       SELECT with no INTO/PERFORM ("query has no destination for result
 *       data"). plpgsql only accepts a statement whose command tag is a DML
 *       (INSERT/UPDATE/DELETE) returning no rows. We can't add INTO/PERFORM
 *       (those are plpgsql source constructs, fixed before this hook runs and
 *       unreachable from it), and the cold "table" is a DuckDB-attached object,
 *       not a PG relation, so PG can't tag a real UPDATE/DELETE against it.
 *       Handled only where needed: when — and only when — this statement is
 *       parsed inside plpgsql, the hook wraps the cold call as a DML over the
 *       dummy carrier coldfront._dummy_dml_target (see cold_anchor_update + that
 *       table's comment in coldfront--1.0.sql). At top level the SELECT shape is
 *       kept byte-for-byte.
 *
 * Detecting "are we inside plpgsql?" without interfering with anything: when
 * plpgsql parses one of its statements it installs p_post_columnref_hook on the
 * ParseState (to resolve identifiers as plpgsql variables). A top-level
 * statement — including a parameterized one, which sets only p_paramref_hook —
 * never has it. So `pstate->p_post_columnref_hook != NULL` is a precise,
 * stateless, side-effect-free "in plpgsql" signal (cold_in_plpgsql), read off
 * the ParseState the hook already receives. No plugin, no global counter,
 * nothing that could collide with a debugger/profiler.
 * ===========================================================================
 */

/*
 * Bound params ($N) a cold rewrite carries when issued from plpgsql / a DO
 * block / PREPARE / the extended protocol. Their VALUES are unknown at
 * parse-analyze (they bind only at execution), so the cold SQL keeps the $N
 * live and renders them via format() at run time (see cold_sql_arg). maxid==0
 * means there are none (the path is then byte-identical to the plain literal path).
 */
#define COLDFRONT_MAX_PARAMS 1024       /* plpgsql dno+1; far above any real arity */
typedef struct ColdParamSet
{
    int  maxid;                         /* highest $N seen (0 = no params)        */
    Oid  types[COLDFRONT_MAX_PARAMS];   /* types[id-1] = $id's type OID           */
    bool seen[COLDFRONT_MAX_PARAMS];    /* which paramids actually occur (sparse) */
} ColdParamSet;

static bool
collect_params_walker(Node *node, void *ctx)
{
    ColdParamSet *ps = (ColdParamSet *) ctx;

    if (node == NULL)
        return false;
    /* A sub-Query (an INSERT's SELECT source, a sub-select) is walked too:
     * expression_tree_walker stops at it. */
    if (IsA(node, Query))
        return query_tree_walker((Query *) node, collect_params_walker, ctx, 0);
    if (IsA(node, Param))
    {
        Param *p = (Param *) node;
        if (p->paramkind == PARAM_EXTERN && p->paramid >= 1)
        {
            /* Hard-fail rather than silently drop: a dropped param would be
             * copied through as a literal $N the re-parse can't bind — exactly
             * the unbound-$N failure this path exists to prevent. The cap is
             * far above any real plpgsql datum count. */
            if (p->paramid > COLDFRONT_MAX_PARAMS)
                ereport(ERROR,
                        (errcode(ERRCODE_TOO_MANY_ARGUMENTS),
                         errmsg("cold-tier DML references parameter $%d, above coldfront's limit of %d",
                                p->paramid, COLDFRONT_MAX_PARAMS)));
            if (p->paramid > ps->maxid)
                ps->maxid = p->paramid;
            ps->types[p->paramid - 1] = p->paramtype;
            ps->seen[p->paramid - 1]  = true;
        }
        return false;
    }
    return expression_tree_walker(node, collect_params_walker, ctx);
}

/* Gather every PARAM_EXTERN in the Query (targetlist, quals, VALUES, sub-RTEs). */
static void
collect_cold_params(Query *query, ColdParamSet *ps)
{
    memset(ps, 0, sizeof(*ps));
    query_tree_walker(query, collect_params_walker, (void *) ps, 0);
}

/*
 * Once-per-session guard: the Iceberg 'ice' catalog is attached lazily on the
 * first query that touches a registered tiered view (read OR write), via
 * ensure_ice_attached_once().  The single, version-agnostic attach path
 * (works on PG 16/17/18).  Reset on transaction
 * ABORT (coldfront_xact_callback): a lazy ATTACH runs inside the user's
 * transaction, so an abort rolls the DuckDB ATTACH back.
 */
static bool coldfront_ice_attached = false;

/*
 * GUC: controls what happens when a WHERE clause cannot be proven to target
 * a single tier (TIER_AMBIGUOUS).  On (default): emit a dual-tier CTE that
 * writes to both sides in the same statement, enabling pg_duckdb's
 * unsafe_allow_mixed_transactions LOCAL so the pre-commit check passes.
 * Off: ereport(ERROR) and force the caller to narrow the predicate.
 */
static bool coldfront_allow_mixed_writes = true;
static int  coldfront_cold_write_batch_size = 10000;

/*
 * GUCs: the two levers over a probed vector search. Off gives the exact scan the
 * product performed before there was a layout to probe, and a positive nprobe
 * overrides the table's configured one. Both exist because the acceptance test for
 * the rewrite is that the same query answers identically with the probe disabled
 * and with it exhaustive, which needs a way to say each in one session.
 */
static bool coldfront_vector_probe  = true;
static int  coldfront_vector_nprobe = 0;

/*
 * GUCs: the deployment-config endpoint/DSN strings that ensure_attached() /
 * ensure_pg_attached() feed to DuckDB's ATTACH. Those helpers are SECURITY
 * DEFINER (they must run elevated so the side-loaded iceberg/postgres
 * extensions load past pg_duckdb's non-superuser LocalFileSystem block), so a
 * non-superuser must NOT be able to redirect the elevated ATTACH at an
 * attacker endpoint. Defining these formally as PGC_SUSET makes them settable
 * only by superusers / roles granted SET on them — operators still set them in
 * postgresql.conf, where they
 * ride physical replication unchanged. local_pg_dsn is GUC_SUPERUSER_ONLY too:
 * it can carry libpq credentials, so non-superusers must not read it back.
 * loopback_dsn is the DSN of the bakery's loopback, which runs claim statements
 * as its own user, so it is PGC_SUSET for the same reason: a role that could
 * set it would choose that user and its startup options. It stays readable
 * because the invoker-rights _bakery_armed() reads it on every cold write, so
 * it must name a unix socket, which needs no password (cf_loopback_get_conn).
 * The values are read through current_setting() or GetConfigOption(); these
 * backing vars exist only to anchor the GUC definitions.
 */
static char *coldfront_warehouse          = NULL;
static char *coldfront_lakekeeper_endpoint = NULL;
static char *coldfront_local_pg_dsn       = NULL;
static char *coldfront_loopback_dsn       = NULL;
/* The bakery's dead-peer window, the async-ordering switch and its build
 * marker, and two per-session values the SQL keeps with set_config. */
static int   coldfront_peer_alive_window_ms   = 10000;
static bool  coldfront_iceberg_async_parquet  = false;
static bool  coldfront_iceberg_bakery_patch   = false;
static char *coldfront_claimed                = NULL;
static bool  coldfront_async_downgrade_warned = false;

static post_parse_analyze_hook_type prev_post_parse_analyze_hook = NULL;
static planner_hook_type            prev_planner_hook            = NULL;

/* Previous ProcessUtility_hook (pg_duckdb's, since coldfront loads after it). */
static ProcessUtility_hook_type prev_process_utility_hook = NULL;

/*
 * Forward decl (defined with the DDL hook below): "is CREATE EXTENSION coldfront
 * present in THIS database?". The parse-analyze hook needs the same guard the
 * DDL hook uses — both are registered cluster-wide.
 */
static bool coldfront_registry_present(void);
/* Defined with it: run a registry read as the extension's owner. */
static int  as_coldfront_owner(Oid *save_uid, int *save_sec);
static void as_caller(Oid save_uid, int save_sec, int nest);

/*
 * Re-entrancy guard for the DDL hook. _rebuild_tiered_view issues CREATE VIEW /
 * CREATE TRIGGER via SPI; those utility statements re-enter ProcessUtility ->
 * our hook. When this is true the hook must do NO coldfront work and just chain
 * through to the real utility processor (mirrors coldfront_in_rewrite for the
 * parse-analyze hook).
 */
static bool coldfront_in_utility = false;

typedef struct {
    char        *hot_table;       /* e.g. "public._events"; NULL when is_iceberg_only */
    char        *iceberg_table;   /* e.g. "ice"."default"."events" */
    char        *partition_col;   /* e.g. "ts"; NULL when is_iceberg_only */
    bool         has_cutoff;      /* false → nothing archived yet */
    bool         is_iceberg_only; /* true → table lives entirely in Iceberg, no hot tier */
    bool         is_writable;     /* false → adopted read-only; DML is refused, reads are not */
    bool         has_vector;      /* the table carries clustered vector columns;
                                   * which ones is SQL's to answer (per-column
                                   * lookups keyed on the ref or the query). */
    TimestampTz  cutoff;          /* archive watermark            */
} TieredViewInfo;

static char *insert_targetlist_collist(Query *query);
static const char *skip_leading_collist(const char *rest);
static const char *skip_override_clause(const char *rest, OverridingKind override);
static char *rewrite_merge_inserts(const char *sql, Query *query,
                                   TieredViewInfo *info, bool cold);
static char *build_iceberg_only_insert_with_cluster(Query *query,
                                                   TieredViewInfo *info,
                                                   const char *source,
                                                   const char *col_list);
static char *add_cluster_set_item(Query *query, RangeTblEntry *rte,
                                  TieredViewInfo *info, const char *cold_dml);

/*
 * Which tier a DML statement targets, based on its WHERE clause predicate on
 * the partition column.  TIER_AMBIGUOUS means we cannot prove the predicate
 * restricts to a single tier — the hook rejects such statements rather than
 * attempting a non-atomic cross-tier write.
 */
typedef enum { TIER_HOT, TIER_COLD, TIER_AMBIGUOUS } TierClass;

/* ---------- catalog lookup -------------------------------------------- */

/*
 * Per-statement snapshot of the tiered registry.
 *
 * Both hooks ask "is this relation a registered view?" once per range-table
 * entry, and a statement may name several views, most of them not ours. The
 * registry holds one row per managed table, so the whole of it is read once per
 * statement and matched in memory, which keeps the cost off every view a
 * statement happens to reference.
 *
 * The snapshot is keyed on the command id, so a registration made earlier in
 * this transaction (create_iceberg_table(), then a write through the view it
 * created) belongs to an earlier command and the next statement reloads and
 * sees it. The rows live in a child context of TopTransactionContext that each
 * reload resets, so a superseded snapshot is freed at the next load rather
 * than accumulating until transaction end; the pointers are cleared in
 * coldfront_xact_callback, so a fresh transaction cannot match a stale
 * command id.
 */
typedef struct {
    char           *schema_name;
    char           *relname;
    TieredViewInfo  info;
} CfRegistryRow;

static List         *cf_registry     = NIL;              /* of CfRegistryRow * */
static CommandId     cf_registry_cid = InvalidCommandId; /* command it was read for */
static MemoryContext cf_registry_cxt = NULL;             /* holds the snapshot's rows */

static void
cf_load_registry(void)
{
    MemoryContext oldcxt;
    uint64        i;
    Oid           save_uid;
    int           save_sec;
    int           nest;

    cf_registry     = NIL;
    cf_registry_cid = GetCurrentCommandId(false);

    /* The snapshot's own context: created on first use, reset (freeing the
     * superseded snapshot) on every reload, freed with its parent at
     * transaction end. */
    if (cf_registry_cxt == NULL)
        cf_registry_cxt = AllocSetContextCreate(TopTransactionContext,
                                                "coldfront registry snapshot",
                                                ALLOCSET_SMALL_SIZES);
    else
        MemoryContextReset(cf_registry_cxt);

    /* Absent before CREATE EXTENSION, and while another extension's install
     * script runs a query the hooks see. No registered views, so no rewrite. */
    if (!coldfront_registry_present())
        return;
    if (SPI_connect() != SPI_OK_CONNECT)
        return;

    nest = as_coldfront_owner(&save_uid, &save_sec);
    if (SPI_execute(
            "SELECT tv.schema_name, tv.relname, tv.hot_table, tv.iceberg_table, "
            "       tv.partition_col, tv.is_iceberg_only, aw.cutoff_time, "
            "       tv.vec_columns IS NOT NULL, tv.is_writable "
            "FROM coldfront.tiered_views tv "
            "LEFT JOIN coldfront.archive_watermark aw "
            "  ON aw.schema_name = tv.schema_name AND aw.table_name = tv.relname",
            true, 0) == SPI_OK_SELECT)
    {
        oldcxt = MemoryContextSwitchTo(cf_registry_cxt);
        for (i = 0; i < SPI_processed; i++)
        {
            HeapTuple      tup = SPI_tuptable->vals[i];
            TupleDesc      td  = SPI_tuptable->tupdesc;
            CfRegistryRow *row = (CfRegistryRow *) palloc0(sizeof(CfRegistryRow));
            bool           isnull;
            Datum          d;

            row->schema_name   = SPI_getvalue(tup, td, 1);
            row->relname       = SPI_getvalue(tup, td, 2);
            /* hot_table and partition_col are NULLable for iceberg-only rows. */
            row->info.hot_table     = SPI_getvalue(tup, td, 3);
            row->info.iceberg_table = SPI_getvalue(tup, td, 4);
            row->info.partition_col = SPI_getvalue(tup, td, 5);

            d = SPI_getbinval(tup, td, 6, &isnull);
            row->info.is_iceberg_only = !isnull && DatumGetBool(d);

            d = SPI_getbinval(tup, td, 7, &isnull);
            row->info.has_cutoff = !isnull;
            if (!isnull)
                row->info.cutoff = DatumGetTimestampTz(d);

            d = SPI_getbinval(tup, td, 8, &isnull);
            row->info.has_vector = !isnull && DatumGetBool(d);

            d = SPI_getbinval(tup, td, 9, &isnull);
            row->info.is_writable = isnull || DatumGetBool(d);

            cf_registry = lappend(cf_registry, row);
        }
        MemoryContextSwitchTo(oldcxt);
    }
    as_caller(save_uid, save_sec, nest);

    SPI_finish();
}

/*
 * Find the registry row for relid, also carrying the archive watermark (if
 * any). vname must be get_rel_name(relid): the caller already has it, so we
 * avoid a redundant syscache hit. Returns true and populates *info, whose
 * strings belong to the snapshot and must not be modified, if found; false
 * otherwise. Matching is by name, as the registry is keyed (it replicates by
 * value across a mesh, where OIDs diverge), and the first match wins.
 */
static bool
lookup_tiered_view(Oid relid, const char *vname, TieredViewInfo *info)
{
    const char *nspname;
    ListCell   *lc;

    if (cf_registry_cid != GetCurrentCommandId(false))
        cf_load_registry();
    if (cf_registry == NIL)
        return false;

    nspname = get_namespace_name(get_rel_namespace(relid));
    if (nspname == NULL)
        return false;

    foreach(lc, cf_registry)
    {
        CfRegistryRow *row = (CfRegistryRow *) lfirst(lc);

        if (strcmp(row->relname, vname) == 0 &&       /* nosemgrep */
            strcmp(row->schema_name, nspname) == 0)   /* nosemgrep */
        {
            *info = row->info;
            return true;
        }
    }
    return false;
}

/*
 * True if the query reads from a registered tiered/iceberg-only view: a VIEW
 * RangeTblEntry resolving in coldfront.tiered_views, at any depth (a CTE, a
 * sub-select, a set-operation branch): pg_duckdb runs the whole statement in DuckDB
 * whichever branch names the view. Once the rewriter has expanded the view its RTE
 * is a subquery that keeps the view's relid, so the planner hook sees it too. Used
 * to lazily attach 'ice' before the read executes (the view body's read of
 * ice.<ns>.<table> only resolves once the catalog is attached) and to gate
 * the read rewrites. The cheap relkind syscache check gates the SPI lookup so plain
 * table queries (the OLTP hot path) never pay for it.
 */
static bool
reads_tiered_view_walker(Node *node, void *ctx)
{
    if (node == NULL)
        return false;
    if (IsA(node, RangeTblEntry))
    {
        RangeTblEntry *rte = (RangeTblEntry *) node;
        TieredViewInfo info;

        return (rte->rtekind == RTE_RELATION || rte->rtekind == RTE_SUBQUERY) &&
               OidIsValid(rte->relid) &&
               get_rel_relkind(rte->relid) == RELKIND_VIEW &&
               get_rel_namespace(rte->relid) != PG_CATALOG_NAMESPACE &&
               lookup_tiered_view(rte->relid, get_rel_name(rte->relid), &info);
    }
    if (IsA(node, Query))
        return query_tree_walker((Query *) node, reads_tiered_view_walker, ctx,
                                 QTW_EXAMINE_RTES_BEFORE);
    return expression_tree_walker(node, reads_tiered_view_walker, ctx);
}

static bool
query_reads_tiered_view(Query *query)
{
    return query_tree_walker(query, reads_tiered_view_walker, NULL,
                             QTW_EXAMINE_RTES_BEFORE);
}

/*
 * Count references to one relation OID anywhere in the query tree — the result
 * relation plus any self-join FROM/USING entry, sub-select, or CTE that resolves
 * to the same view.  QTW_EXAMINE_RTES_BEFORE makes the walker fire on each
 * RangeTblEntry; recursion into sub-Querys (RTE_SUBQUERY and SubLink subselects)
 * goes through the Query arm.  cf_reject_multi_reference refuses DML that names
 * a tiered view more than once by this count: the deparse rewrite only swaps
 * the leading result-relation token, so a second reference would be copied
 * through verbatim and fail confusingly.
 */
typedef struct { Oid relid; int count; } ViewRefCount;

static bool
count_view_refs_walker(Node *node, void *ctx)
{
    ViewRefCount *vrc = (ViewRefCount *) ctx;

    if (node == NULL)
        return false;
    if (IsA(node, RangeTblEntry))
    {
        RangeTblEntry *rte = (RangeTblEntry *) node;
        if (rte->rtekind == RTE_RELATION && rte->relid == vrc->relid)
            vrc->count++;
        /* let the default range-table walk recurse into a subquery RTE */
        return false;
    }
    if (IsA(node, Query))
        return query_tree_walker((Query *) node, count_view_refs_walker, ctx,
                                 QTW_EXAMINE_RTES_BEFORE);
    return expression_tree_walker(node, count_view_refs_walker, ctx);
}

static int
count_tiered_view_refs(Query *query, Oid view_oid)
{
    ViewRefCount vrc = { .relid = view_oid, .count = 0 };

    query_tree_walker(query, count_view_refs_walker, (void *) &vrc,
                      QTW_EXAMINE_RTES_BEFORE);
    return vrc.count;
}

/* ---------- tier classification --------------------------------------- */

/* True if `node` contains a Param or SubLink — neither can be evaluated as a
 * standalone scalar, so eval_partition_bound declines such operands. */
static bool
bound_noneval_walker(Node *node, void *ctx)
{
    if (node == NULL)
        return false;
    if (IsA(node, Param) || IsA(node, SubLink))
    {
        *((bool *) ctx) = true;
        return true;
    }
    return expression_tree_walker(node, bound_noneval_walker, ctx);
}

/*
 * Resolve a partition-bound operand to a timestamptz value known at parse time.
 * A literal Const yields its value directly. A non-Const operand is evaluated only
 * when it is a self-contained, stable timestamptz expression — no Vars, params,
 * sublinks, or volatile functions — so now()/CURRENT_* arithmetic (e.g.
 * now() - interval '1 hour') folds to its transaction-fixed value and the
 * predicate classifies to a single tier. Returns false (the caller treats it as
 * TIER_AMBIGUOUS) for anything not pinnable now. timestamptz is pass-by-value, so
 * the result outlives the throwaway executor state. The original expression stays
 * in the Query for execution; only the tier decision reads this value.
 */
static bool
eval_partition_bound(Node *node, TimestampTz *out)
{
    EState    *estate;
    ExprState *exprstate;
    Datum      d;
    bool       isnull, bad = false;

    if (IsA(node, Const))
    {
        Const *c = (Const *) node;
        if (c->consttype != TIMESTAMPTZOID || c->constisnull)
            return false;
        *out = DatumGetTimestampTz(c->constvalue);
        return true;
    }

    if (exprType(node) != TIMESTAMPTZOID || contain_var_clause(node) ||
        contain_volatile_functions(node))
        return false;
    (void) bound_noneval_walker(node, &bad);
    if (bad)
        return false;

    estate    = CreateExecutorState();
    exprstate = ExecPrepareExpr((Expr *) node, estate);
    d         = ExecEvalExprSwitchContext(exprstate,
                                          GetPerTupleExprContext(estate), &isnull);
    FreeExecutorState(estate);
    if (isnull)
        return false;
    *out = DatumGetTimestampTz(d);
    return true;
}

/*
 * Walk a qual node and return which tier the matching rows belong to.
 *
 * We handle direct comparisons of the partition column Var against a timestamptz
 * value — a literal Const or a stable expression resolved by eval_partition_bound
 * — and AND/OR combinations thereof.  Anything else is TIER_AMBIGUOUS.
 *
 * Tier boundary:  ts <  cutoff → cold,  ts >= cutoff → hot.
 */
static TierClass
classify_qual(Node *qual, Index result_rel, AttrNumber partcol_attno,
              TimestampTz cutoff)
{
    OpExpr     *op;
    Node       *a, *b, *other;
    Var        *var;
    bool        var_left;
    char       *opname;
    TimestampTz val;

    if (qual == NULL)
        return TIER_AMBIGUOUS;

    /* BoolExpr: AND (any deterministic arg wins); OR (all args must agree). */
    if (IsA(qual, BoolExpr))
    {
        BoolExpr *be = castNode(BoolExpr, qual);
        ListCell *lc;

        if (be->boolop == AND_EXPR)
        {
            foreach(lc, be->args)
            {
                TierClass tc = classify_qual((Node *) lfirst(lc),
                                             result_rel, partcol_attno, cutoff);
                if (tc != TIER_AMBIGUOUS)
                    return tc;
            }
            return TIER_AMBIGUOUS;
        }

        if (be->boolop == OR_EXPR)
        {
            TierClass agreed = TIER_AMBIGUOUS;
            foreach(lc, be->args)
            {
                TierClass tc = classify_qual((Node *) lfirst(lc),
                                             result_rel, partcol_attno, cutoff);
                if (tc == TIER_AMBIGUOUS)
                    return TIER_AMBIGUOUS;
                if (agreed == TIER_AMBIGUOUS)
                    agreed = tc;
                else if (agreed != tc)
                    return TIER_AMBIGUOUS;
            }
            return agreed;
        }

        return TIER_AMBIGUOUS;
    }

    /* ts IN (c1, c2, ...) → ScalarArrayOpExpr with useOr=true, opno == '='.
     * Tier-deterministic iff every array element classifies to the same tier. */
    if (IsA(qual, ScalarArrayOpExpr))
    {
        ScalarArrayOpExpr *sa = castNode(ScalarArrayOpExpr, qual);
        Node       *scalar, *array;
        char       *sa_opname;
        TierClass   agreed = TIER_AMBIGUOUS;
        ListCell   *lc;

        if (!sa->useOr || list_length(sa->args) != 2)
            return TIER_AMBIGUOUS;

        scalar = (Node *) linitial(sa->args);
        array  = (Node *) lsecond(sa->args);

        if (!IsA(scalar, Var))
            return TIER_AMBIGUOUS;
        {
            Var *v = castNode(Var, scalar);
            if ((Index) v->varno != result_rel || v->varattno != partcol_attno)
                return TIER_AMBIGUOUS;
        }

        sa_opname = get_opname(sa->opno);
        if (!sa_opname || strcmp(sa_opname, "=") != 0)
            return TIER_AMBIGUOUS;

        /* An IN list reaches the hook as an ArrayExpr of its elements; the
         * planner folds it into a Const array later. Any other array shape is
         * ambiguous. */
        if (!IsA(array, ArrayExpr))
            return TIER_AMBIGUOUS;

        foreach(lc, castNode(ArrayExpr, array)->elements)
        {
            Node  *elem = (Node *) lfirst(lc);
            Const *ec;
            TimestampTz ev;
            TierClass et;

            if (!IsA(elem, Const))
                return TIER_AMBIGUOUS;
            ec = castNode(Const, elem);
            if (ec->consttype != TIMESTAMPTZOID || ec->constisnull)
                return TIER_AMBIGUOUS;
            ev = DatumGetTimestampTz(ec->constvalue);
            et = (ev >= cutoff) ? TIER_HOT : TIER_COLD;
            if (agreed == TIER_AMBIGUOUS)
                agreed = et;
            else if (agreed != et)
                return TIER_AMBIGUOUS;
        }
        return agreed;
    }

    if (!IsA(qual, OpExpr))
        return TIER_AMBIGUOUS;

    op = castNode(OpExpr, qual);
    if (list_length(op->args) != 2)
        return TIER_AMBIGUOUS;

    a = (Node *) linitial(op->args);
    b = (Node *) lsecond(op->args);

    if (IsA(a, Var))
    {
        var = (Var *) a; other = b; var_left = true;
    }
    else if (IsA(b, Var))
    {
        var = (Var *) b; other = a; var_left = false;
    }
    else
        return TIER_AMBIGUOUS;

    /* Only the partition column of the target relation matters */
    if ((Index) var->varno != result_rel || var->varattno != partcol_attno)
        return TIER_AMBIGUOUS;

    /* The bound must be a timestamptz value known now: a literal, or a stable
     * expression (e.g. now() - interval '1 hour') we evaluate to its
     * transaction-fixed value. Anything else stays TIER_AMBIGUOUS. */
    if (!eval_partition_bound(other, &val))
        return TIER_AMBIGUOUS;

    opname = get_opname(op->opno);
    if (!opname)
        return TIER_AMBIGUOUS;

    /*
     * Normalise the predicate to "ts <op> val" shape: if the operand order
     * is reversed (val <op> ts), swap the operator to its semantic dual so
     * a single ladder covers both shapes.  '=' is symmetric so needs no
     * flip.  Tier rule: cold = ts < cutoff, hot = ts >= cutoff.
     */
    if (!var_left)
    {
        if      (strcmp(opname, "<")  == 0) opname = ">";
        else if (strcmp(opname, "<=") == 0) opname = ">=";
        else if (strcmp(opname, ">")  == 0) opname = "<";
        else if (strcmp(opname, ">=") == 0) opname = "<=";
    }

    if (strcmp(opname, "=")  == 0) return (val >= cutoff) ? TIER_HOT  : TIER_COLD;
    if (strcmp(opname, "<")  == 0) return (val <= cutoff) ? TIER_COLD : TIER_AMBIGUOUS;
    if (strcmp(opname, "<=") == 0) return (val <  cutoff) ? TIER_COLD : TIER_AMBIGUOUS;
    if (strcmp(opname, ">")  == 0) return (val >= cutoff) ? TIER_HOT  : TIER_AMBIGUOUS;
    if (strcmp(opname, ">=") == 0) return (val >= cutoff) ? TIER_HOT  : TIER_AMBIGUOUS;
    return TIER_AMBIGUOUS;
}

/*
 * A MERGE's ON condition: its own field from PostgreSQL 17, the join tree's
 * qualifier on 16.
 */
static Node *
merge_on_condition(Query *query)
{
#if PG_VERSION_NUM >= 170000
    return query->mergeJoinCondition;
#else
    return (Node *) query->jointree->quals;
#endif
}

/*
 * Entry point: classify the query's WHERE clause, a MERGE's ON condition.  If
 * nothing has been archived yet, all rows are hot by definition.
 */
static TierClass
classify_tier(Query *query, TieredViewInfo *info)
{
    RangeTblEntry *rte;
    AttrNumber     partcol_attno;

    /* Iceberg-only mode: every DML targets the cold tier unconditionally,
     * regardless of WHERE clause or watermark. hot_table and partition_col
     * are NULL on these rows; emit_hot must never be reached. */
    if (info->is_iceberg_only)
        return TIER_COLD;

    if (!info->has_cutoff)
        return TIER_HOT;

    rte           = (RangeTblEntry *) list_nth(query->rtable,
                                               query->resultRelation - 1);
    partcol_attno = get_attnum(rte->relid, info->partition_col);
    if (partcol_attno == InvalidAttrNumber)
        return TIER_AMBIGUOUS;

    return classify_qual(query->commandType == CMD_MERGE ? merge_on_condition(query)
                                                        : (Node *) query->jointree->quals,
                         (Index) query->resultRelation,
                         partcol_attno,
                         info->cutoff);
}

/* ---------- string helpers -------------------------------------------- */

/* drop_typmod: after substituting, skip a following "(...)" so a typmod that is
 * valid on the PG spelling but not on the DuckDB one does not survive. */
/* wrap: the replacement opens one paren more than the spelling it replaces
 * (to_json(array_agg( for jsonb_agg(), so a closing paren is added at the
 * matched call's own close. */
typedef struct {
    const char *pg;
    const char *duck;
    bool        drop_typmod;
    bool        wrap;
} CfSubst;

/* Deepest nesting of wrapped calls one statement may carry. */
#define CF_WRAP_MAX 16

/*
 * Cold-WRITE substitutions. The deparsed cold DML is handed to DuckDB inside a
 * duckdb.raw_query() string, so DuckDB-only spellings are fine. Multi-word PG
 * casts map to DuckDB's single-word names, and the boundary-aware jsonb→json
 * catch-all (cf_apply_subst's jsonb_catchall arm) maps every other jsonb token —
 * ::jsonb, jsonb_set, jsonb_extract_path, … — to its json_<rest> form. The few
 * whose DuckDB name is not json_<rest> are listed here, matched with the opening
 * paren so a column prefix can't false-match. A result DuckDB lacks (e.g.
 * json_set) errors in DuckDB — its boundary, not a rewrite coldfront withholds.
 *
 * The JSON aggregates are the one pair whose target is not a single name.
 * DuckDB has neither json_agg nor jsonb_agg, and its json_group_array is a macro
 * that refuses the ORDER BY an aggregate carries, so both spellings become
 * to_json(array_agg(...)): array_agg is a DuckDB aggregate and keeps the
 * ORDER BY. That target opens one paren more than the spelling it replaces,
 * which is what `wrap` closes.
 */
static const CfSubst cf_write_subst[] = {
    { "::timestamp with time zone",    "::timestamptz", false, false },
    { "::timestamp without time zone", "::timestamp",   false, false },
    { "::character varying",           "::varchar",     false, false },
    { "::double precision",            "::double",      false, false },
    /* pgvector's types are unknown to DuckDB, and the Iceberg column is FLOAT[].
     * The dimension typmod goes with the name: FLOAT[](3) is not a type. The
     * cast's operand is already bracketed here, since a vector Const deparses
     * through pgvector's own output function. */
    { "::vector",                      "::FLOAT[]",     true,  false },
    { "::halfvec",                     "::FLOAT[]",     true,  false },
    { "jsonb_build_object(",           "json_object(",  false, false },
    { "jsonb_build_array(",            "json_array(",   false, false },
    { "to_jsonb(",                     "to_json(",      false, false },
    { "jsonb_agg(",   "to_json(array_agg(",             false, true  },
    { "json_agg(",    "to_json(array_agg(",             false, true  },
};

/*
 * Tiered-READ substitutions. A rewritten SELECT is reparsed by PG and then planned
 * by DuckDB, so a translation must be valid in BOTH engines — which rules out the
 * write path's blanket catch-all. Only the jsonb type cast and the functions
 * verified identical in PG and DuckDB are translated; every other jsonb spelling is
 * left untouched, so DuckDB rejects it with a clear "… does not exist" (a documented
 * read limitation). Blanket-mapping would break two ways: jsonb_path_query →
 * json_path_query fails PG reparse (PG has no json_path_query), and
 * json_extract_path_text / json_type are signature- or vocabulary-incompatible in
 * DuckDB (array result; UBIGINT/VARCHAR vs number/string). json_array_length is
 * verified identical ([10,20,30]→3, []→0) and exists in both. DuckDB has no
 * date_bin; its time_bucket takes the same (interval, timestamp[tz], timestamp[tz])
 * arguments, pg_duckdb declares it PG-side, and the two agree on every fixed-width
 * bucket (a month or year width, which date_bin rejects, time_bucket accepts).
 * The JSON builders (jsonb_build_object, jsonb_agg) need more than a spelling and
 * are rewritten on the node tree instead, as is the <#> operator, which DuckDB
 * lacks and whose function it has: see cf_json_builder_mutator.
 */
static const CfSubst cf_read_subst[] = {
    { "::jsonb",             "::json",             false, false },
    { "jsonb_array_length(", "json_array_length(", false, false },
    { "date_bin(",           "time_bucket(",       false, false },
};

/*
 * Rewrite a deparsed SQL string token-by-token using `map`, optionally followed by
 * the boundary-aware jsonb→json catch-all. Returns a palloc'd result. Quote-aware:
 * skips substitution inside a single-quoted literal or double-quoted identifier, so
 * user text and identifiers are preserved verbatim; embedded '' and "" escapes stay
 * inside their literal/identifier.
 */
static char *
cf_apply_subst(const char *sql, const CfSubst *map, int map_len, bool jsonb_catchall)
{
    StringInfoData buf;
    const char    *p         = sql;
    bool           in_quote  = false;
    bool           in_dquote = false;
    int            depth     = 0;                /* paren depth, outside quotes */
    int            wrap_at[CF_WRAP_MAX];         /* depths owing a closing paren */
    int            nwrap     = 0;

    initStringInfo(&buf);
    while (*p)
    {
        /* Enter / leave / escape within single-quoted literals. */
        if (*p == '\'' && !in_dquote)
        {
            if (in_quote && *(p + 1) == '\'')
            {
                /* '' → escaped single quote; stay inside the literal. */
                appendStringInfoChar(&buf, '\'');
                appendStringInfoChar(&buf, '\'');
                p += 2;
                continue;
            }
            in_quote = !in_quote;
            appendStringInfoChar(&buf, *p++);
            continue;
        }

        /*
         * Enter / leave double-quoted identifier. pg_get_querydef emits "" for
         * an embedded double-quote inside an identifier; treat as escape and
         * stay inside.
         */
        if (*p == '"' && !in_quote)
        {
            if (in_dquote && *(p + 1) == '"')
            {
                appendStringInfoChar(&buf, '"');
                appendStringInfoChar(&buf, '"');
                p += 2;
                continue;
            }
            in_dquote = !in_dquote;
            appendStringInfoChar(&buf, *p++);
            continue;
        }

        /* Outside any quotes: look for a spelling to substitute. */
        if (!in_quote && !in_dquote)
        {
            bool replaced = false;
            int  i;
            for (i = 0; i < map_len; i++)
            {
                size_t plen = strlen(map[i].pg); /* nosemgrep */
                /* A function spelling must start the identifier: undate_bin( is not
                 * date_bin(. Cast spellings start at '::' and need no such check. */
                if (isalpha((unsigned char) map[i].pg[0]) && p > sql &&
                    (isalnum((unsigned char) p[-1]) || p[-1] == '_'))
                    continue;
                if (strncmp(p, map[i].pg, plen) == 0)
                {
                    appendStringInfoString(&buf, map[i].duck);
                    p += plen;
                    if (map[i].drop_typmod && *p == '(')
                    {
                        while (*p && *p != ')')
                            p++;
                        if (*p == ')')
                            p++;
                    }
                    /* A function spelling ends with its own '(', already
                     * consumed, so the call's arguments sit one level in and
                     * the depth must count it. The call's close is the ')'
                     * that brings the depth back to where it started, and a
                     * wrapped call owes an added close there. */
                    if (map[i].pg[plen - 1] == '(')
                    {
                        if (map[i].wrap)
                        {
                            if (nwrap == CF_WRAP_MAX)
                                ereport(ERROR,
                                        (errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
                                         errmsg("coldfront: JSON aggregates nested deeper than %d",
                                                CF_WRAP_MAX)));
                            wrap_at[nwrap++] = depth;
                        }
                        depth++;
                    }
                    replaced = true;
                    break;
                }
            }
            if (replaced)
                continue;

            /* Catch-all jsonb → json at an identifier boundary: rewrite the
             * `jsonb` token when it is preceded by a non-identifier char and not
             * followed by a letter/digit, so the cast and jsonb_* function names
             * map while an embedded identifier (my_jsonb_col) is left intact. */
            if (jsonb_catchall && strncmp(p, "jsonb", 5) == 0) /* nosemgrep */
            {
                char prev = (p == sql) ? ' ' : p[-1];
                char next = p[5];
                /* left edge not part of an identifier; right edge not a letter/
                 * digit ('_' allowed, so jsonb_set maps to json_set). */
                if (!(isalnum((unsigned char) prev) || prev == '_') &&
                    !isalnum((unsigned char) next))
                {
                    appendStringInfoString(&buf, "json");
                    p += 5;
                    continue;
                }
            }

            /* Track the depth the wrap flag closes against, and emit the added
             * paren when a wrapped call's own close is reached. */
            if (*p == '(')
                depth++;
            else if (*p == ')' && depth > 0)
            {
                depth--;
                if (nwrap > 0 && wrap_at[nwrap - 1] == depth)
                {
                    nwrap--;
                    appendStringInfoString(&buf, "))");
                    p++;
                    continue;
                }
            }
        }

        appendStringInfoChar(&buf, *p++);
    }
    return buf.data;
}

/* Cold-write path: full cast map + blanket jsonb→json (output goes to DuckDB). */
static char *
normalize_casts_for_duckdb(const char *sql)
{
    return cf_apply_subst(sql, cf_write_subst, lengthof(cf_write_subst), true);
}

/* Tiered-read path: whitelist only (output is reparsed by PG, then run by DuckDB). */
static char *
normalize_for_read(const char *sql)
{
    return cf_apply_subst(sql, cf_read_subst, lengthof(cf_read_subst), false);
}

/* ---------- read-path JSON builders ------------------------------------ */

/*
 * jsonb_build_object / json_build_object and jsonb_agg / json_agg have no DuckDB
 * counterpart a spelling can reach: PostgreSQL's grammar reserves json_object, so
 * that name never resolves to a function, and DuckDB's json_group_array is a macro
 * that refuses the ORDER BY an aggregate carries. Both engines share concat,
 * to_json, array_agg and the json cast, so a builder becomes those:
 *   jsonb_build_object(k1, v1, …)  →  concat('{', to_json(k1::text)::text, ':',
 *                                             COALESCE(to_json(v1)::text, 'null'),
 *                                             ',', …, '}')::json
 *   jsonb_agg(e ORDER BY …)         →  to_json(array_agg(e ORDER BY …))
 * to_json(NULL) is SQL NULL in both engines, so a value is COALESCEd to the JSON
 * null; a NULL key gives concat text the json cast rejects, as jsonb_build_object
 * rejects a NULL key. The result is JSON-equal to jsonb's rendering (jsonb also
 * sorts keys and pads punctuation). Pairing keys with values is exact on the
 * argument List; the emitted function OIDs come from the catalog, once per backend.
 * A VARIADIC array argument cannot be paired and is left alone.
 */
typedef struct { bool changed; } JsonBuilderCtx;

static Oid cf_to_json_oid       = InvalidOid;
static Oid cf_concat_oid        = InvalidOid;
static Oid cf_array_agg_oid     = InvalidOid;   /* array_agg(anynonarray) */
static Oid cf_array_agg_arr_oid = InvalidOid;   /* array_agg(anyarray)    */

static void
cf_resolve_json_builder_oids(void)
{
    List *array_agg = list_make2(makeString("pg_catalog"), makeString("array_agg"));
    Oid   argtype;

    if (OidIsValid(cf_to_json_oid))
        return;
    cf_to_json_oid = LookupFuncName(list_make2(makeString("pg_catalog"), makeString("to_json")),
                                    -1, NULL, false);
    cf_concat_oid  = LookupFuncName(list_make2(makeString("pg_catalog"), makeString("concat")),
                                    -1, NULL, false);
    argtype = ANYNONARRAYOID;
    cf_array_agg_oid     = LookupFuncName(array_agg, 1, &argtype, false);
    argtype = ANYARRAYOID;
    cf_array_agg_arr_oid = LookupFuncName(array_agg, 1, &argtype, false);
}

static bool
cf_is_pg_catalog_func(Oid funcid, const char *name, const char *alt)
{
    const char *fname;

    if (get_func_namespace(funcid) != PG_CATALOG_NAMESPACE)
        return false;
    fname = get_func_name(funcid);
    return strcmp(fname, name) == 0 || strcmp(fname, alt) == 0; /* nosemgrep */
}

static Node *
cf_text_const(const char *s)
{
    return (Node *) makeConst(TEXTOID, -1, DEFAULT_COLLATION_OID, -1,
                              CStringGetTextDatum(s), false, false);
}

static Node *
cf_cast_via_io(Node *arg, Oid type)
{
    CoerceViaIO *c = makeNode(CoerceViaIO);

    c->arg          = (Expr *) arg;
    c->resulttype   = type;
    c->resultcollid = (type == TEXTOID) ? DEFAULT_COLLATION_OID : InvalidOid;
    c->coerceformat = COERCE_EXPLICIT_CAST;
    c->location     = -1;
    return (Node *) c;
}

/* to_json(e)::text */
static Node *
cf_json_text(Node *e)
{
    FuncExpr *f = makeFuncExpr(cf_to_json_oid, JSONOID, list_make1(e),
                               InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);

    return cf_cast_via_io((Node *) f, TEXTOID);
}

/* COALESCE(to_json(v)::text, 'null'); a value that is already json (a nested
 * builder, a view's json column) needs only the cast. */
static Node *
cf_json_value(Node *v)
{
    CoalesceExpr *c = makeNode(CoalesceExpr);

    c->coalescetype   = TEXTOID;
    c->coalescecollid = DEFAULT_COLLATION_OID;
    c->args           = list_make2(exprType(v) == JSONOID ? cf_cast_via_io(v, TEXTOID)
                                                          : cf_json_text(v),
                                   cf_text_const("null"));
    c->location       = -1;
    return (Node *) c;
}

/* to_json(k::text)::text: a JSON key is a string whatever the key's type. */
static Node *
cf_json_key(Node *k)
{
    if (exprType(k) != TEXTOID)
        k = cf_cast_via_io(k, TEXTOID);
    return cf_json_text(k);
}

/* concat('{', key, ':', value, ',', …, '}')::json over the paired argument list. */
static Node *
cf_json_object(List *args)
{
    List     *cat = list_make1(cf_text_const("{"));
    ListCell *lc;
    int       i   = 0;

    foreach(lc, args)
    {
        Node *a = (Node *) lfirst(lc);

        if (i % 2 == 0)
        {
            if (i > 0)
                cat = lappend(cat, cf_text_const(","));
            cat = lappend(cat, cf_json_key(a));
            cat = lappend(cat, cf_text_const(":"));
        }
        else
            cat = lappend(cat, cf_json_value(a));
        i++;
    }
    cat = lappend(cat, cf_text_const("}"));
    return cf_cast_via_io((Node *) makeFuncExpr(cf_concat_oid, TEXTOID, cat, InvalidOid,
                                                DEFAULT_COLLATION_OID, COERCE_EXPLICIT_CALL),
                          JSONOID);
}

/* to_json(array_agg(e …)): the Aggref keeps its ORDER BY, FILTER and DISTINCT. */
static Node *
cf_json_agg(Aggref *agg, Oid elemtype, Oid arrtype)
{
    agg->aggfnoid = type_is_array(elemtype) ? cf_array_agg_arr_oid : cf_array_agg_oid;
    agg->aggtype  = arrtype;
    return (Node *) makeFuncExpr(cf_to_json_oid, JSONOID, list_make1(agg),
                                 InvalidOid, InvalidOid, COERCE_EXPLICIT_CALL);
}

static Node *
cf_json_builder_mutator(Node *node, void *ctx)
{
    JsonBuilderCtx *jc = (JsonBuilderCtx *) ctx;

    if (node == NULL)
        return NULL;
    if (IsA(node, Query))
        return (Node *) query_tree_mutator((Query *) node, cf_json_builder_mutator, ctx, 0);
    if (IsA(node, FuncExpr))
    {
        FuncExpr *f = (FuncExpr *) expression_tree_mutator(node, cf_json_builder_mutator, ctx);

        if (!f->funcvariadic &&
            cf_is_pg_catalog_func(f->funcid, "jsonb_build_object", "json_build_object"))
        {
            cf_resolve_json_builder_oids();
            jc->changed = true;
            return cf_json_object(f->args);
        }
        return (Node *) f;
    }
    if (IsA(node, Aggref))
    {
        Aggref *a = (Aggref *) expression_tree_mutator(node, cf_json_builder_mutator, ctx);

        if (list_length(a->aggargtypes) == 1 &&
            cf_is_pg_catalog_func(a->aggfnoid, "jsonb_agg", "json_agg"))
        {
            Oid elemtype = linitial_oid(a->aggargtypes);
            Oid arrtype  = get_array_type(elemtype);

            if (OidIsValid(arrtype))
            {
                cf_resolve_json_builder_oids();
                jc->changed = true;
                return cf_json_agg(a, elemtype, arrtype);
            }
        }
        return (Node *) a;
    }
    if (IsA(node, OpExpr))
    {
        OpExpr *op    = (OpExpr *) expression_tree_mutator(node, cf_json_builder_mutator, ctx);
        char   *fname = get_func_name(op->opfuncid);

        /* pg_duckdb hands an operator to DuckDB by its symbol. DuckDB has <=> and
         * <-> as aliases of its own list_cosine_distance and list_distance and has
         * no <#>, so that operator becomes a call of the function behind it, which
         * DuckDB has under the same name. */
        if (fname != NULL && list_length(op->args) == 2 &&
            strcmp(fname, "list_negative_inner_product") == 0)  /* nosemgrep */
        {
            jc->changed = true;
            return (Node *) makeFuncExpr(op->opfuncid, op->opresulttype, op->args,
                                         op->opcollid, op->inputcollid,
                                         COERCE_EXPLICIT_CALL);
        }
        return (Node *) op;
    }
    return expression_tree_mutator(node, cf_json_builder_mutator, ctx);
}

/* ---------- SQL builder ----------------------------------------------- */

/*
 * Result of deparsing + finding the leading target-relation prefix.
 * rest points into orig_sql, just past the matched prefix; verb always ends
 * with a space.
 *
 * pg_get_querydef() qualifies relation names only when the schema is not in
 * the search_path.  For the typical case of public.events with default
 * search_path, the deparsed string starts with "UPDATE events" or
 * "DELETE FROM events" (no schema prefix).  We try the unqualified form
 * first, then fall back to the schema-qualified form.
 *
 * alias is the view's name followed by a space when the statement reads a
 * second relation or a sub-select and gave the view no alias: the deparser
 * then qualifies the view's columns by its name, and the retargeted relation
 * takes that name as its alias so they keep resolving. Otherwise "".
 */
typedef struct {
    char       *orig_sql;   /* normalised, leading-whitespace-stripped */
    size_t      head_len;   /* bytes before the verb: a leading WITH clause, else 0 */
    const char *rest;       /* points into orig_sql, past the prefix   */
    const char *verb;       /* "UPDATE " / "DELETE FROM " / "INSERT INTO " / "MERGE INTO " */
    const char *alias;      /* "<view> " or "" */
} DeparseResult;

/*
 * Locate the "VERB <relation> " prefix in the deparsed DML: the first occurrence
 * outside any single-quoted string literal. A leading WITH clause puts the verb
 * past offset 0, so this scans rather than anchoring at the start; the bytes
 * before the match are that WITH preamble, which the builders carry through
 * verbatim. cf_reject_multi_reference guarantees the result relation is named
 * once, so the first out-of-literal hit is the statement's own target. Only one
 * of the unqualified / schema-qualified spellings can match (the deparser emits
 * one form). The spellings end in a space, which the text has after the
 * relation unless the statement ends there (a DELETE without WHERE). Returns
 * the match start and sets *matched to the spelling found; elogs if neither is
 * present.
 */
static const char *
find_dml_prefix(const char *orig_sql, const char *search_unqual,
                const char *search_qual, const char *vname,
                const char **matched)
{
    size_t      lu = strlen(search_unqual) - 1; /* nosemgrep */
    size_t      lq = strlen(search_qual) - 1;   /* nosemgrep */
    const char *p;
    bool        in_squote = false;

    for (p = orig_sql; *p; p++)
    {
        if (*p == '\'')
        {
            in_squote = !in_squote;
            continue;
        }
        if (in_squote)
            continue;
        if (strncmp(p, search_unqual, lu) == 0 && (p[lu] == ' ' || p[lu] == '\0')) { *matched = search_unqual; return p; } /* nosemgrep */
        if (strncmp(p, search_qual,   lq) == 0 && (p[lq] == ' ' || p[lq] == '\0')) { *matched = search_qual;   return p; } /* nosemgrep */
    }

    elog(ERROR,
         "coldfront: cannot locate result relation \"%s\" in deparsed DML: %s",
         vname, orig_sql);
    *matched = NULL;
    return NULL; /* unreachable */
}

/* pg_get_querydef's text on one line: newlines and tabs become spaces, and the
 * leading indent goes. */
static char *
deparse_flat(Query *query)
{
    char *sql = pg_get_querydef(query, false), *p;

    for (p = sql; *p; p++)
        if (*p == '\n' || *p == '\t') *p = ' ';
    while (*sql == ' ')
        sql++;
    return sql;
}

/* The two spellings pg_get_querydef can give the statement's verb and result
 * relation, unqualified and schema-qualified. It quotes mixed-case and reserved
 * identifiers, and quote_identifier returns a plain name unchanged. */
static void
dml_search_strings(Query *query, char *unqual, char *qual, size_t len,
                   const char **verb)
{
    RangeTblEntry *rte = rt_fetch(query->resultRelation, query->rtable);
    const char    *q_vname = quote_identifier(get_rel_name(rte->relid));
    const char    *q_ns = quote_identifier(get_namespace_name(get_rel_namespace(rte->relid)));

    *verb = query->commandType == CMD_UPDATE ? "UPDATE " :
            query->commandType == CMD_DELETE ? "DELETE FROM " :
            query->commandType == CMD_MERGE  ? "MERGE INTO " : "INSERT INTO ";
    snprintf(unqual, len, "%s%s ", *verb, q_vname);
    snprintf(qual, len, "%s%s.%s ", *verb, q_ns, q_vname);
}

static void
deparse_and_find_prefix(Query *query, DeparseResult *dr)
{
    char           search_unqual[256], search_qual[256];
    const char    *matched, *at;
    RangeTblEntry *rte = rt_fetch(query->resultRelation, query->rtable);

    dr->orig_sql = deparse_flat(query);
    dml_search_strings(query, search_unqual, search_qual, sizeof(search_unqual), &dr->verb);
    at = find_dml_prefix(dr->orig_sql, search_unqual, search_qual,
                         get_rel_name(rte->relid), &matched);
    dr->head_len = (size_t) (at - dr->orig_sql);
    dr->rest     = at + strlen(matched) - 1; /* nosemgrep */
    if (*dr->rest == ' ')
        dr->rest++;
    dr->alias    = query->commandType != CMD_INSERT && rte->alias == NULL &&
                   (list_length(query->rtable) > 1 || query->hasSubLinks)
                   ? psprintf("%s ", quote_identifier(get_rel_name(rte->relid))) : "";
}

/*
 * Open a rewritten statement's WITH clause: the statement's own entries
 * (dr->head_len bytes, before the verb) come first, so an entry that modifies
 * data stays at the top level where PostgreSQL requires it, and a comma leads
 * into the rewrite's own entries.
 */
static void
append_with_opener(StringInfo buf, const DeparseResult *dr)
{
    if (dr->head_len == 0)
    {
        appendStringInfoString(buf, "WITH ");
        return;
    }
    appendBinaryStringInfo(buf, dr->orig_sql, dr->head_len);
    while (buf->len > 0 && buf->data[buf->len - 1] == ' ')
        buf->len--;
    buf->data[buf->len] = '\0';
    appendStringInfoString(buf, ", ");
}

/*
 * Prepend the statement's leading WITH clause (dr->head_len bytes, before the
 * verb) to a row source. The decoupled INSERT ships its source to DuckDB inside
 * a parenthesised derived table, the only scope its CTEs are visible from
 * there. Returns source unchanged when there is no leading clause.
 */
static const char *
fold_leading_with(const DeparseResult *dr, const char *source)
{
    StringInfoData sb;

    if (dr->head_len == 0)
        return source;
    initStringInfo(&sb);
    appendBinaryStringInfo(&sb, dr->orig_sql, dr->head_len);
    appendStringInfoString(&sb, source);
    return sb.data;
}

/*
 * Build a DML string targeting info->hot_table. Preserves any RETURNING.
 */
static char *
build_hot_dml(DeparseResult *dr, TieredViewInfo *info)
{
    StringInfoData buf;
    initStringInfo(&buf);
    appendBinaryStringInfo(&buf, dr->orig_sql, dr->head_len);  /* leading WITH, if any */
    appendStringInfo(&buf, "%s%s %s%s", dr->verb, info->hot_table, dr->alias, dr->rest);
    return buf.data;
}

/*
 * Build a DML string targeting info->iceberg_table, with PG-specific casts
 * normalised to DuckDB equivalents.  The caller is expected to have already
 * cleared query->returningList on a cloned Query before calling
 * deparse_and_find_prefix(), so no RETURNING clause appears in dr->rest.
 */
static char *
build_cold_dml(DeparseResult *dr, TieredViewInfo *info, Query *query)
{
    StringInfoData buf;
    char          *sql;

    initStringInfo(&buf);
    appendBinaryStringInfo(&buf, dr->orig_sql, dr->head_len);  /* leading WITH, if any */
    appendStringInfo(&buf, "%s%s %s%s", dr->verb, info->iceberg_table, dr->alias, dr->rest);
    sql = normalize_casts_for_duckdb(buf.data);

    /* A cold UPDATE that sets the embedding re-derives the cluster in the same
     * statement.  Here rather than in a caller because both the cold and the
     * dual path build their cold half through this one function, and a row whose
     * embedding changes while its cluster does not is permanently invisible to
     * its own probe, silently. */
    if (query != NULL && query->commandType == CMD_UPDATE
        && info->has_vector)
    {
        RangeTblEntry *rte = (RangeTblEntry *) list_nth(query->rtable,
                                                        query->resultRelation - 1);
        char *restamped = add_cluster_set_item(query, rte, info, sql);
        if (restamped != NULL)
            sql = restamped;
    }
    return sql;
}

/*
 * Render a deparsed cold DML string as the SQL-text argument that
 * coldfront._exec_iceberg_with_claim(table, sql) receives.
 *
 * With no bound params (maxid==0) it is a plain quoted literal. With params it
 * is a format(<template>, $1, $2, ...) call: each out-of-literal $N becomes a
 * positional %P$L spec and stays LIVE as a format() arg, so PG binds the value
 * at execution and DuckDB only ever sees a finished literal. That is what lets
 * cold DML carry plpgsql / PREPARE / extended-protocol $N (Cause 1).
 *
 * Quote-aware (mirrors normalize_casts_for_duckdb): a '$N' inside a string
 * literal is user data, left alone; a literal '%' is doubled so format() passes
 * it through.
 *
 * The string reaches duckdb.raw_query (emit_cold / emit_dual), so a value
 * renders as a DuckDB literal: bytea -> from_hex(%P$L) / encode($K,'hex');
 * real[] (a vector column's view type) -> CAST(%P$L AS FLOAT[]) /
 * translate($K::text,'{}','[]'); any other array -> %P$s /
 * coldfront._render_cold_param($K); json/jsonb/interval -> %P$L / $K::text;
 * else %P$L / $K. With for_pg the string is the tiered stream's read, which
 * PostgreSQL runs: every value is %P$L / $K, a literal its own input reads
 * back, coerced by the projection's casts.
 */
static char *
cold_sql_arg(const char *cold_dml, ColdParamSet *ps, bool for_pg)
{
    StringInfoData tmpl, args, out;
    const char    *p = cold_dml;
    bool           in_quote = false, in_dquote = false;
    int            pos_of_id[COLDFRONT_MAX_PARAMS] = {0};
    int            next_pos = 1;

    if (ps->maxid == 0)
        return quote_literal_cstr(cold_dml);

    initStringInfo(&tmpl);
    initStringInfo(&args);
    while (*p)
    {
        if (*p == '\'' && !in_dquote)
        {
            if (in_quote && *(p + 1) == '\'')
            { appendStringInfoString(&tmpl, "''"); p += 2; continue; }
            in_quote = !in_quote;
            appendStringInfoChar(&tmpl, *p++);
            continue;
        }
        if (*p == '"' && !in_quote)
        {
            if (in_dquote && *(p + 1) == '"')
            { appendStringInfoString(&tmpl, "\"\""); p += 2; continue; }
            in_dquote = !in_dquote;
            appendStringInfoChar(&tmpl, *p++);
            continue;
        }
        if (*p == '%')                              /* format() metachar */
        { appendStringInfoString(&tmpl, "%%"); p++; continue; }
        if (*p == '$' && !in_quote && !in_dquote &&
            *(p + 1) >= '0' && *(p + 1) <= '9')
        {
            int         id = 0;
            const char *q  = p + 1;
            Oid         t;

            while (*q >= '0' && *q <= '9')
                id = id * 10 + (*q++ - '0');
            if (id >= 1 && id <= ps->maxid && ps->seen[id - 1])
            {
                t = ps->types[id - 1];
                if (pos_of_id[id - 1] == 0)         /* first sight: assign pos + arg */
                {
                    pos_of_id[id - 1] = next_pos++;
                    if (for_pg)
                        appendStringInfo(&args, ", $%d", id);
                    else if (t == BYTEAOID)
                        /* hex string, independent of the caller's bytea_output;
                         * from_hex rebuilds the exact bytes. */
                        appendStringInfo(&args, ", encode($%d,'hex')", id);
                    else if (t == FLOAT4ARRAYOID)
                        /* A vector column reaches this path as real[], the type the
                         * view exposes. PG spells that {1,2,3} and DuckDB's list
                         * cast takes [1,2,3], so translate rewrites the delimiters
                         * and the template supplies the cast. */
                        appendStringInfo(&args, ", translate($%d::text,'{}','[]')", id);
                    else if (type_is_array(t))
                        /* Any other array: coldfront._render_cold_param checks its
                         * shape and renders the DuckDB list an array column's value
                         * becomes, so the template takes the result as SQL. */
                        appendStringInfo(&args, ", coldfront._render_cold_param($%d)", id);
                    else if (t == JSONOID || t == JSONBOID || t == INTERVALOID)
                        appendStringInfo(&args, ", $%d::text", id);
                    else
                        appendStringInfo(&args, ", $%d", id);
                }
                if (for_pg)
                    appendStringInfo(&tmpl, "%%%d$L", pos_of_id[id - 1]);
                else if (t == BYTEAOID)
                    appendStringInfo(&tmpl, "from_hex(%%%d$L)", pos_of_id[id - 1]);
                else if (t == FLOAT4ARRAYOID)
                    appendStringInfo(&tmpl, "CAST(%%%d$L AS FLOAT[])", pos_of_id[id - 1]);
                else if (type_is_array(t))
                    appendStringInfo(&tmpl, "%%%d$s", pos_of_id[id - 1]);
                else
                    appendStringInfo(&tmpl, "%%%d$L", pos_of_id[id - 1]);
                p = q;
                continue;
            }
        }
        appendStringInfoChar(&tmpl, *p++);
    }

    initStringInfo(&out);
    appendStringInfo(&out, "format(%s%s)",
                     quote_literal_cstr(tmpl.data), args.data);
    return out.data;
}

/*
 * The cold serialization call expression:
 * coldfront._exec_iceberg_with_claim(<table>, <arg_sql>), where arg_sql is
 * cold_sql_arg() output. This is the single chokepoint for ALL cold-tier writes
 * (tiered and iceberg-only): its plpgsql wrapper self-selects the cluster-wide
 * R-A bakery (mesh) or a local advisory lock (vanilla), runs the cold DML via
 * duckdb.raw_query, and releases the claim at XACT_EVENT_COMMIT, after pg_duckdb
 * has committed the Iceberg transaction at XACT_EVENT_PRE_COMMIT, via the C
 * XactCallback. Callers wrap it in a SELECT (top level) or in
 * cold_anchor_update() (in plpgsql).
 */
static char *
cold_exec_call(const char *iceberg_table, const char *arg_sql)
{
    StringInfoData buf;
    initStringInfo(&buf);
    appendStringInfo(&buf, "coldfront._exec_iceberg_with_claim(%s, %s)",
                     quote_literal_cstr(iceberg_table), arg_sql);
    return buf.data;
}

/*
 * Cause-2 carrier (in-plpgsql only): turn a cold call expression into a
 * DML-tagged statement plpgsql accepts (a bare SELECT would raise "query has no
 * destination for result data" inside a function / DO block). The call runs
 * exactly once in the WHERE qual, evaluated against the single row of
 * coldfront._dummy_dml_target; because _exec_iceberg_with_claim returns void and
 * `void IS NULL` is always false, zero rows match and the table is NEVER written
 * (no dead rows, no WAL, no bloat). Used standalone for pure-cold, and as the
 * data-modifying WITH-CTE body for the dual / tiered-INSERT cases (a
 * data-modifying CTE always runs to completion, even unreferenced). See the
 * full rationale on the table in coldfront--1.0.sql.
 */
static char *
cold_anchor_update(const char *cold_call_expr, const char *test)
{
    StringInfoData buf;
    initStringInfo(&buf);
    appendStringInfo(&buf,
        "UPDATE coldfront._dummy_dml_target SET anchor = anchor WHERE %s %s",
        cold_call_expr, test);
    return buf.data;
}

/*
 * Returns true if the query's rtable contains any RTE_RELATION that's a
 * regular table or partitioned table other than the result relation.
 * Used by the hook to decide whether to call ensure_pg_attached_via_spi
 * (which is expensive on some pg_duckdb builds and potentially errors).
 */
static bool
rtable_has_pg_source_table(List *rtable, int result_rel_idx)
{
    ListCell *lc;
    int       idx = 0;
    foreach(lc, rtable)
    {
        RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);
        char           kind;
        idx++;
        if (rte->rtekind == RTE_SUBQUERY && rte->subquery != NULL)
        {
            if (rtable_has_pg_source_table(rte->subquery->rtable, 0))
                return true;
            continue;
        }
        if (rte->rtekind != RTE_RELATION) continue;
        if (idx == result_rel_idx) continue;
        kind = get_rel_relkind(rte->relid);
        if (kind == RELKIND_RELATION || kind == RELKIND_PARTITIONED_TABLE)
            return true;
    }
    return false;
}

static bool
query_has_pg_source_table(Query *query)
{
    return rtable_has_pg_source_table(query->rtable, query->resultRelation);
}

/*
 * Replace every reference to a non-result PG table in `sql` with the
 * `pglocal.` prefix so DuckDB's postgres extension (ATTACHed at session
 * start by coldfront.ensure_pg_attached) resolves the table over libpq.
 *
 * Used for the INSERT cold path: when a user writes `INSERT INTO <view>
 * SELECT ... FROM pg_source`, the deparsed SELECT references pg_source by
 * its PG-side name, but raw_query runs in DuckDB context where only
 * DuckDB-attached catalogs are visible. Prefixing each non-result
 * RTE_RELATION with `pglocal.` lets DuckDB resolve it through the
 * postgres extension and stream rows directly into the Iceberg writer
 * with no local materialisation.
 *
 * We walk the Query's rtable, build the qualified `<schema>.<table>`
 * string for each non-result RTE_RELATION, and substitute every
 * occurrence in sql with `pglocal.<schema>.<table>`. The substitution is
 * quote-aware: an occurrence inside a single-quoted string literal is user
 * data, not a table reference, and is left untouched; a word-boundary check
 * keeps a column or alias that merely shares the table's identifier from
 * being rewritten. quote_identifier matches what pg_get_querydef emits, so
 * the search patterns line up exactly.
 */
/* Walk an rtable and collect every PG-table relid, recursing into
 * RTE_SUBQUERY (INSERT … SELECT wraps the SELECT side in a subquery). */
static List *
collect_pg_source_relids(List *rtable, int result_rel_idx, List *acc)
{
    ListCell *lc;
    int       idx = 0;
    foreach(lc, rtable)
    {
        RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);
        idx++;
        if (rte->rtekind == RTE_SUBQUERY && rte->subquery != NULL)
        {
            acc = collect_pg_source_relids(rte->subquery->rtable, 0, acc);
            continue;
        }
        if (rte->rtekind != RTE_RELATION) continue;
        if (idx == result_rel_idx) continue;
        if (get_rel_relkind(rte->relid) != RELKIND_RELATION &&
            get_rel_relkind(rte->relid) != RELKIND_PARTITIONED_TABLE)
            continue;
        acc = lappend_oid(acc, rte->relid);
    }
    return acc;
}

/* Track single-quote string-literal state across a copied span: each ' toggles it.
 * A '' escape toggles twice (net no change), and no replacement target can sit
 * between the two quotes of '', so the state is exact at every match position.
 * Lets prefix_pg_tables_with_pglocal leave occurrences inside string literals
 * untouched while still rewriting double-quoted table identifiers. */
static bool
span_toggles_squote(const char *from, const char *to, bool in_squote)
{
    const char *c;
    for (c = from; c < to; c++)
        if (*c == '\'')
            in_squote = !in_squote;
    return in_squote;
}

static char *
prefix_pg_tables_with_pglocal(Query *query, char *sql)
{
    List     *relids = collect_pg_source_relids(query->rtable, query->resultRelation, NIL);
    ListCell *lc;

    foreach(lc, relids)
    {
        Oid            relid = lfirst_oid(lc);
        char           qualified[NAMEDATALEN * 2 + 8];
        char          *replacement;
        StringInfoData buf;
        const char    *p, *match;
        size_t         qlen, blen;
        bool           in_squote;
        char          *bare = NULL;
        const char    *q_n, *q_ns;

        {
            char       *name  = get_rel_name(relid);
            char       *ns    = get_namespace_name(get_rel_namespace(relid));
            q_n   = quote_identifier(name);
            q_ns  = quote_identifier(ns);
            snprintf(qualified, sizeof(qualified), "%s.%s", q_ns, q_n);
            replacement = psprintf("pglocal.%s.%s", q_ns, q_n);
            bare = pstrdup(q_n);
        }

        /* Pass 1: replace qualified `<schema>.<table>` occurrences that fall
         * outside any single-quoted string literal (a qualified name inside a
         * literal is user data, not a table reference). */
        qlen = strlen(qualified); /* nosemgrep */
        initStringInfo(&buf);
        p = sql;
        in_squote = false;
        while ((match = strstr(p, qualified)) != NULL)
        {
            in_squote = span_toggles_squote(p, match, in_squote);
            appendBinaryStringInfo(&buf, p, match - p);
            if (in_squote)
                appendBinaryStringInfo(&buf, match, qlen);  /* inside a literal — leave verbatim */
            else
                appendStringInfoString(&buf, replacement);
            p = match + qlen;
        }
        appendStringInfoString(&buf, p);
        sql = buf.data;

        /* Pass 2: replace bare `<table>` references that pg_get_querydef
         * emits when the schema is in search_path. Word-boundary check on
         * both sides avoids corrupting column names or aliases that share
         * the table's identifier. A "word" character is [A-Za-z0-9_$]; a
         * preceding `.` is also a word boundary because that means the
         * token has already been schema-qualified by pass 1 — skip. */
        blen = strlen(bare); /* nosemgrep */
        initStringInfo(&buf);
        p = sql;
        in_squote = false;
        while ((match = strstr(p, bare)) != NULL)
        {
            char before = (match == sql) ? ' ' : match[-1];
            char after  = match[blen];
            bool wb_before =
                !((before >= 'A' && before <= 'Z') ||
                  (before >= 'a' && before <= 'z') ||
                  (before >= '0' && before <= '9') ||
                  before == '_' || before == '$' ||
                  before == '.' || before == '"');
            bool wb_after =
                !((after  >= 'A' && after  <= 'Z') ||
                  (after  >= 'a' && after  <= 'z') ||
                  (after  >= '0' && after  <= '9') ||
                  after  == '_' || after  == '$' ||
                  after  == '"');
            in_squote = span_toggles_squote(p, match, in_squote);
            appendBinaryStringInfo(&buf, p, match - p);
            if (!in_squote && wb_before && wb_after)
                appendStringInfoString(&buf, replacement);
            else
                appendBinaryStringInfo(&buf, match, blen);
            p = match + blen;
        }
        appendStringInfoString(&buf, p);
        sql = buf.data;
    }
    return sql;
}

/* ---------- per-tier emitters ----------------------------------------- */

static char *
emit_hot(Query *query, TieredViewInfo *info)
{
    DeparseResult dr;
    char         *sql;

    deparse_and_find_prefix(query, &dr);
    sql = build_hot_dml(&dr, info);
    if (query->commandType == CMD_MERGE && info->has_cutoff)
        sql = rewrite_merge_inserts(sql, query, info, false);
    return sql;
}

static char *
emit_cold(Query *query, TieredViewInfo *info, ColdParamSet *ps, bool in_plpgsql)
{
    DeparseResult  dr;
    char          *cold_dml, *call;

    deparse_and_find_prefix(query, &dr);
    cold_dml = build_cold_dml(&dr, info, query);
    if (query->commandType == CMD_MERGE)
        cold_dml = rewrite_merge_inserts(cold_dml, query, info, true);

    /* An iceberg-only INSERT into a clustered table is re-emitted so the cluster
     * is derived in the same statement: a row whose cluster disagrees with its
     * vector is invisible to its own search and reports no error. */
    if (query->commandType == CMD_INSERT && info->is_iceberg_only
        && info->has_vector)
    {
        char *col_list = insert_targetlist_collist(query);
        char *with_cluster = build_iceberg_only_insert_with_cluster(
            query, info,
            fold_leading_with(&dr, skip_leading_collist(dr.rest)), col_list);
        if (with_cluster != NULL)
            cold_dml = normalize_casts_for_duckdb(with_cluster);
    }

    /* A PostgreSQL table the statement reads (an INSERT's or a MERGE's source,
     * an UPDATE's FROM, a DELETE's USING) gets the pglocal. prefix, so DuckDB
     * resolves it through the postgres extension. */
    cold_dml = prefix_pg_tables_with_pglocal(query, cold_dml);

    /* ALL cold-tier writes — tiered and iceberg-only alike — go through the
     * bakery wrapper. Every iceberg snapshot commit posts to the same
     * Lakekeeper CAS, so two concurrent committers to the same table (a cold
     * UPDATE on a peer, the archiver, another backend) would collide on a 409
     * regardless of which rows they touch. _exec_iceberg_with_claim serializes
     * them; it self-selects the R-A bakery (multi-node mesh) or a local
     * advisory lock (vanilla single-node), so this is correct in every
     * deployment. (Tiered INSERT uses a separate path, emit_tiered_insert.) */
    call = cold_exec_call(info->iceberg_table, cold_sql_arg(cold_dml, ps, false));

    /* Cause 2: inside plpgsql the statement must be a DML (cold_anchor_update);
     * at top level keep the byte-identical SELECT shape. */
    if (in_plpgsql)
        return cold_anchor_update(call, "IS NULL");
    {
        StringInfoData buf;
        initStringInfo(&buf);
        appendStringInfo(&buf, "SELECT %s", call);
        return buf.data;
    }
}

/*
 * emit_dual builds the dual-tier CTE used when coldfront.allow_mixed_writes
 * is on and the predicate is TIER_AMBIGUOUS.  Both sides run in the same
 * statement; pg_duckdb's XactCallback keeps the DuckDB transaction tied to
 * PG's, so ROLLBACK undoes both tiers (not crash-safe: orphaned S3 objects
 * on crash are Iceberg housekeeping's concern).
 *
 * The cold CTE is a SELECT (not DML), so PG would prune it as unreferenced
 * unless the outer query forces its execution.  We use a CROSS JOIN with
 * `cold` in the outer SELECT; see the body comment near the appendStringInfo
 * call for why MATERIALIZED alone would not be enough.
 *
 * The hot CTE gets RETURNING * so the outer SELECT can consume its output.
 * The statement's own RETURNING is refused before this
 * (reject_cold_returning), since the cold half returns no rows.
 */
static char *
emit_dual(Query *query, TieredViewInfo *info, ColdParamSet *ps, bool in_plpgsql)
{
    DeparseResult  dr;
    char          *hot_dml, *cold_dml, *call;
    StringInfoData buf;

    deparse_and_find_prefix(query, &dr);
    hot_dml  = build_hot_dml(&dr, info);
    cold_dml = build_cold_dml(&dr, info, query);
    call     = cold_exec_call(info->iceberg_table, cold_sql_arg(cold_dml, ps, false));

    initStringInfo(&buf);
    if (in_plpgsql)
    {
        /* Cause 2: the hot UPDATE/DELETE is the statement itself (the DML tag
         * plpgsql accepts, and the body a WITH entry keeps once
         * cf_splice_nested_dml lifts the rest out), behind the statement's own
         * WITH entries; the cold call rides in a data-modifying entry
         * (cold_anchor_update), which PG always runs to completion regardless of
         * references, so the cold write still happens when the hot side matches
         * no rows. */
        append_with_opener(&buf, &dr);
        appendStringInfo(&buf, "coldfront_cold AS (%s) %s%s %s%s",
                         cold_anchor_update(call, "IS NULL"), dr.verb, info->hot_table,
                         dr.alias, dr.rest);
    }
    else
    {
        /* Top level: the cold CTE is a SELECT, which PG would prune as
         * unreferenced (MATERIALIZED only prevents inlining), so a CROSS JOIN
         * with it in the outer SELECT forces its execution while keeping the row
         * set equal to the hot CTE's, which is DML and always runs. */
        appendStringInfo(&buf,
            "WITH coldfront_hot AS (%s RETURNING *)"
            ", coldfront_cold AS (SELECT %s)"
            " SELECT h.* FROM coldfront_hot h CROSS JOIN coldfront_cold c",
            hot_dml, call);
    }
    return buf.data;
}

/*
 * Build a comma-joined list of target column names from query->targetList
 * for an INSERT. resname is the target column name (id, ts, status, ...).
 * Returns a palloc'd string. Used by emit_tiered_insert to project the
 * staged source rows back to the target columns on both tiers.
 */
static char *
insert_targetlist_collist(Query *query)
{
    ListCell      *lc;
    StringInfoData buf;
    bool           first = true;
    initStringInfo(&buf);
    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);
        if (tle->resjunk || tle->resname == NULL) continue;
        if (!first) appendStringInfoString(&buf, ", ");
        appendStringInfoString(&buf, quote_identifier(tle->resname));
        first = false;
    }
    return buf.data;
}

/*
 * Skip a leading "(col, col, ...)" optional column list in an INSERT's
 * deparsed rest, returning the pointer to the source clause that starts
 * with "VALUES" or "SELECT". Whitespace before / between is tolerated.
 * If no parens, returns the input pointer (already at the source).
 */
static const char *
skip_leading_collist(const char *rest)
{
    while (*rest == ' ') rest++;
    if (*rest != '(') return rest;
    {
        int depth = 0;
        const char *p = rest;
        for (; *p; p++)
        {
            if (*p == '(') depth++;
            else if (*p == ')') { depth--; if (depth == 0) { p++; break; } }
        }
        while (*p == ' ') p++;
        return p;
    }
}

/*
 * Returns true iff `attname` matches (by string) any resname in `targeted`.
 */
static bool
name_in_list(List *targeted, const char *attname)
{
    ListCell *lc;
    foreach(lc, targeted)
    {
        char *name = (char *) lfirst(lc);
        if (strcmp(name, attname) == 0) return true;
    }
    return false;
}

/*
 * Format a TimestampTz as the SQL literal `'<text>'::timestamptz` so it
 * embeds verbatim in a SQL string.  PG's timestamptz_out is locale-stable
 * and round-trips cleanly through cstring → timestamptz on both PG and
 * DuckDB.  Returns palloc'd.
 */
static char *
format_timestamptz_literal(TimestampTz ts)
{
    char *txt = DatumGetCString(DirectFunctionCall1(timestamptz_out,
                                                     TimestampTzGetDatum(ts)));
    return psprintf("'%s'::timestamptz", txt);
}

/*
 * Find the statement's own WHERE in deparsed DML: the first " WHERE " at paren
 * depth zero and outside every literal.  Quotes are tracked before parens
 * because a literal can hold an unbalanced one, and depth matters because a
 * sublink carries its own WHERE a level down.  NULL when there is none, meaning
 * the insertion point is the end of the statement.
 */
static const char *
find_toplevel_where(const char *sql)
{
    const char *p;
    bool        in_squote = false, in_dquote = false;
    int         depth = 0;

    for (p = sql; *p; p++)
    {
        if (in_squote) { if (*p == '\'') in_squote = false; continue; }
        if (in_dquote) { if (*p == '"')  in_dquote = false; continue; }
        if (*p == '\'') { in_squote = true; continue; }
        if (*p == '"')  { in_dquote = true; continue; }
        if (*p == '(')  { depth++; continue; }
        if (*p == ')')  { depth--; continue; }
        if (depth == 0 && pg_strncasecmp(p, " WHERE ", 7) == 0)
            return p;
    }
    return NULL;
}

/*
 * Add one SET item to a deparsed UPDATE, before the statement's own WHERE or at
 * the end when it has none.  Returns palloc'd.
 */
static char *
add_set_item(const char *cold_dml, const char *set_item)
{
    const char    *w = find_toplevel_where(cold_dml);
    StringInfoData buf;

    initStringInfo(&buf);
    if (w == NULL)
        appendStringInfo(&buf, "%s, %s", cold_dml, set_item);
    else
    {
        appendBinaryStringInfo(&buf, cold_dml, w - cold_dml);
        appendStringInfo(&buf, ", %s%s", set_item, w);
    }
    return buf.data;
}

/*
 * Re-stamp the cluster on a cold UPDATE that sets an embedding.
 *
 * The derivation takes the text of the new embedding expression rather than a
 * value, which is what makes this tractable: this path never sees row contents.
 * The expression is evaluated twice, once for the column and once for the
 * cluster.  Returns the extended statement, or NULL to leave it untouched.
 *
 * Every SET column is offered to coldfront._vec_list_set_item, which answers
 * NULL for one that is not a clustered vector column: which columns qualify is
 * the registry's knowledge, consulted where it lives instead of copied here.
 * Every vector column the UPDATE sets gets its own item, because each has its
 * own cluster column and leaving one stale would make those rows invisible to
 * that column's probe while the others stayed correct.
 */
static char *
add_cluster_set_item(Query *query, RangeTblEntry *rte, TieredViewInfo *info,
                     const char *cold_dml)
{
    char     *out = NULL;
    ListCell *lc;

    foreach(lc, query->targetList)
    {
        TargetEntry   *tle = (TargetEntry *) lfirst(lc);
        char          *colname;
        List          *dpcontext;
        char          *e_text, *item = NULL;
        StringInfoData q;

        if (tle->resjunk)
            continue;
        colname = get_attname(rte->relid, tle->resno, true);
        if (colname == NULL)
            continue;

        dpcontext = deparse_context_for(get_rel_name(rte->relid), rte->relid);
        e_text    = deparse_expression((Node *) tle->expr, dpcontext, false, false);

        initStringInfo(&q);
        appendStringInfo(&q, "SELECT coldfront._vec_list_set_item(%s, %s, %s)",
                         quote_literal_cstr(info->iceberg_table),
                         quote_literal_cstr(colname),
                         quote_literal_cstr(e_text));
        if (SPI_connect() == SPI_OK_CONNECT)
        {
            if (SPI_execute(q.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
            {
                bool  itemnull;

                (void) SPI_getbinval(SPI_tuptable->vals[0],
                                     SPI_tuptable->tupdesc, 1, &itemnull);
                if (!itemnull)
                {
                    MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);
                    item = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
                    MemoryContextSwitchTo(oldcxt);
                }
            }
            SPI_finish();
        }
        if (item == NULL)
            continue;

        /* The item carries the caller's own PG spelling of the new embedding. */
        out = add_set_item(out ? out : cold_dml, normalize_casts_for_duckdb(item));
    }
    return out;
}

/*
 * Re-emit an iceberg-only INSERT so it carries the cluster assignment.
 *
 * The deparsed statement is targeted (`INSERT INTO t (cols) VALUES …`), so the
 * column and its value are added by naming both rather than by editing each
 * tuple: the source becomes a derived table and the assignment reads the vector
 * from it, which is the same shape the tiered cold half already writes. Returns
 * NULL when the table has no clustered vector column, leaving today's statement
 * untouched.
 */
static char *
build_iceberg_only_insert_with_cluster(Query *query, TieredViewInfo *info,
                                       const char *source, const char *col_list)
{
    StringInfoData sql, q;
    char          *prefix = NULL;
    char          *list_cols = NULL;   /* already quoted and comma-joined */

    if (!info->has_vector)
        return NULL;

    /* The assignment reads the vector out of the derived table. */
    initStringInfo(&q);
    appendStringInfo(&q,
        "SELECT coldfront._vec_list_cols_for_ref(%s), "
        "       coldfront._vec_list_prefix_for_ref(%s, %s)",
        quote_literal_cstr(info->iceberg_table),
        quote_literal_cstr(info->iceberg_table),
        quote_literal_cstr("coldfront_src."));
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        if (SPI_execute(q.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
        {
            MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);
            list_cols = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
            prefix   = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 2);
            MemoryContextSwitchTo(oldcxt);
        }
        SPI_finish();
    }
    if (prefix == NULL || list_cols == NULL)
        return NULL;

    /* Ordered by cluster, so this write's own row groups each hold about one
     * cluster and a probe skips the rest of the file. The cluster leads the
     * projection, hence ordinal 1. */
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "INSERT INTO %s (%s, %s) SELECT %s%s FROM (%s) AS coldfront_src(%s) ORDER BY 1",
        info->iceberg_table, list_cols, col_list,
        prefix, col_list, source, col_list);
    return sql.data;
}

/*
 * The hot table's columns in attnum order, read once per rewritten INSERT:
 * name, type, DEFAULT expression (NULL without one) and, for an identity
 * column, its sequence (NULL otherwise). Vector companions are left out, as in
 * every other place the cold tuple is built.
 */
typedef struct {
    int    n;
    char **name;
    char **type;
    char **dflt;
    char **seq;
} HotColumns;

static void
load_hot_columns(const char *hot_qualified, HotColumns *hc)
{
    StringInfoData sql;
    const char    *lit = quote_literal_cstr(hot_qualified);

    hc->n = 0;
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT a.attname, format_type(a.atttypid, a.atttypmod), "
        "       pg_get_expr(d.adbin, d.adrelid), "
        "       CASE WHEN a.attidentity <> '' "
        "            THEN pg_get_serial_sequence(%s, a.attname) END "
        "FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
        "WHERE n.nspname = (parse_ident(%s))[1] "
        "AND c.relname = (parse_ident(%s))[2] "
        "AND a.attnum > 0 AND NOT a.attisdropped "
        "AND NOT coldfront._is_vec_companion(a.attname, a.attgenerated) "
        "ORDER BY a.attnum",
        lit, lit, lit);
    if (SPI_connect() != SPI_OK_CONNECT)
        return;
    if (SPI_execute(sql.data, true, 0) == SPI_OK_SELECT && SPI_processed > 0)
    {
        MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);
        uint64        i;

        hc->n    = (int) SPI_processed;
        hc->name = palloc(sizeof(char *) * hc->n);
        hc->type = palloc(sizeof(char *) * hc->n);
        hc->dflt = palloc(sizeof(char *) * hc->n);
        hc->seq  = palloc(sizeof(char *) * hc->n);
        for (i = 0; i < SPI_processed; i++)
        {
            HeapTuple tup = SPI_tuptable->vals[i];

            hc->name[i] = SPI_getvalue(tup, SPI_tuptable->tupdesc, 1);
            hc->type[i] = SPI_getvalue(tup, SPI_tuptable->tupdesc, 2);
            hc->dflt[i] = SPI_getvalue(tup, SPI_tuptable->tupdesc, 3);
            hc->seq[i]  = SPI_getvalue(tup, SPI_tuptable->tupdesc, 4);
        }
        MemoryContextSwitchTo(oldcxt);
    }
    SPI_finish();
}

/* The hot-table type of one target column, or NULL when the hot table has no
 * column of that name. */
static const char *
hot_column_type(const HotColumns *hc, const char *name)
{
    int i;

    for (i = 0; i < hc->n; i++)
        if (strcmp(hc->name[i], name) == 0)
            return hc->type[i];
    return NULL;
}

/*
 * The rewritten INSERT's source CTE: the user's source as a derived table
 * named by the target columns, each cast to its hot-table type. PostgreSQL
 * resolved those coercions when it analyzed the user's statement (an untyped
 * literal against a jsonb column, say) and a derived table loses them, so the
 * cast restates them. It cannot accept anything that analysis refused, since
 * a refused statement never reaches this hook.
 */
static char *
build_src_cte(Query *query, const char *source, const char *col_list,
              const HotColumns *hc)
{
    StringInfoData sel;
    ListCell      *lc;
    bool           first = true;

    initStringInfo(&sel);
    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);
        const char  *type;

        if (tle->resjunk || tle->resname == NULL) continue;
        type = hot_column_type(hc, tle->resname);
        if (!first) appendStringInfoString(&sel, ", ");
        if (type != NULL)
            appendStringInfo(&sel, "%s::%s AS %s", quote_identifier(tle->resname),
                             type, quote_identifier(tle->resname));
        else
            appendStringInfoString(&sel, quote_identifier(tle->resname));
        first = false;
    }
    return psprintf("SELECT %s FROM (%s) AS coldfront_src(%s)", sel.data, source, col_list);
}

/*
 * The PostgreSQL type a streamed column is sent as, one DuckDB's postgres
 * extension maps to the Iceberg column's type. A vector is unknown to it and
 * would arrive as text, so it goes as real[]; jsonb, json and interval are
 * stored as VARCHAR and go as their text, the form the sink stores too.
 */
static const char *
cf_stream_cast(const char *type)
{
    if (strncmp(type, "vector", 6) == 0 || strncmp(type, "halfvec", 7) == 0)
        return "::real[]";
    if (strcmp(type, "jsonb") == 0 || strcmp(type, "json") == 0 ||
        strcmp(type, "interval") == 0)
        return "::text";
    return "";
}

/*
 * The cold rows' projection: every hot-table column in attnum order, named.
 * A target column is the source's value; an omitted identity column (or any
 * identity column under OVERRIDING USER VALUE) takes the next value of its
 * sequence, which the hot INSERT shares; an omitted column with a DEFAULT
 * takes that expression, evaluated by PostgreSQL per row as a hot INSERT
 * would; any other omitted column is NULL. For the sink the rows come from
 * the materialized source, already cast, and to_jsonb() of the row is what it
 * renders; for the stream they come from the source itself, so each is cast
 * to its hot type and then to the type it is sent as (cf_stream_cast).
 */
static char *
build_cold_projection(Query *query, const HotColumns *hc, bool stream)
{
    StringInfoData sel;
    List          *targeted = NIL;
    ListCell      *lc;
    int            i;

    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);

        if (!tle->resjunk && tle->resname != NULL)
            targeted = lappend(targeted, tle->resname);
    }
    initStringInfo(&sel);
    for (i = 0; i < hc->n; i++)
    {
        bool        in_target = name_in_list(targeted, hc->name[i]);
        const char *cast = stream ? cf_stream_cast(hc->type[i]) : "";
        char       *expr;

        if (hc->seq[i] != NULL &&
            (!in_target || query->override == OVERRIDING_USER_VALUE))
            expr = psprintf("nextval(%s::regclass)", quote_literal_cstr(hc->seq[i]));
        else if (in_target && stream)
            expr = psprintf("coldfront_src.%s::%s", quote_identifier(hc->name[i]),
                            hc->type[i]);
        else if (in_target)
            expr = psprintf("coldfront_source.%s", quote_identifier(hc->name[i]));
        else if (hc->dflt[i] != NULL)
            expr = psprintf("(%s)", hc->dflt[i]);
        else
            expr = psprintf("NULL::%s", hc->type[i]);
        /* An array reaches the sink as a jsonb list, which keeps no lower bound,
         * so its shape is checked here, while it is still an array. format_type
         * spells every array type with a trailing []. */
        if (pg_str_endswith(hc->type[i], "[]"))
            expr = psprintf("coldfront._cold_list(%s, %s)", expr,
                            quote_literal_cstr(hc->name[i]));
        if (cast[0] != '\0')
            expr = psprintf("(%s)%s", expr, cast);
        appendStringInfo(&sel, "%s%s AS %s", i > 0 ? ", " : "", expr,
                         quote_identifier(hc->name[i]));
    }
    return sel.data;
}

/* The hot half: a set-based INSERT into the hot table of the source rows at or
 * above the cutoff, read from the sink shape's materialized source or, in the
 * stream shape, from the source itself (select_list, from_clause). */
static char *
build_tiered_hot_dml(const char *hot_table, const char *col_list,
                     const char *override, const char *select_list,
                     const char *from_clause, const char *pc_expr,
                     const char *cutoff_lit)
{
    return psprintf("INSERT INTO %s (%s) %sSELECT %s %s WHERE %s >= %s",
                    hot_table, col_list, override, select_list, from_clause,
                    pc_expr, cutoff_lit);
}

/*
 * Whether a tiered INSERT's cold half can stream, and the tables its source
 * reads. The stream reads the source again from another session over libpq
 * (coldfront._tiered_cold_stream), so it is sound only when that session sees
 * what the hot half saw: coldfront.local_pg_dsn names it; the transaction is
 * READ COMMITTED, so the hot half's snapshot is the statement's and not an
 * older one; the source has no WITH entry; every function in it is IMMUTABLE,
 * since a volatile one yields other rows and a stable one (now(), the
 * timezone-dependent timestamptz arithmetic, a text-to-timestamptz cast) may
 * yield other values in a session with other settings; it reads no temporary
 * table, no view that reads one or calls such a function, nothing but tables;
 * and this transaction has written none of those tables. Anything else goes
 * to the sink shape, which reads the source once for both halves.
 */
typedef struct {
    Oid   result_relid;   /* the view being written, or the view being expanded */
    List *rels;           /* every table the source reads, views expanded */
} StreamCheck;

static bool cf_stream_blocker_walker(Node *node, void *ctx);

/* A relation the source reads blocks the stream when the other session cannot
 * see it as this one does: a temporary table; a view, through what it reads;
 * anything that is not a table. A table is collected for the written-in-
 * transaction check. A view's stored query names the view itself in its OLD
 * and NEW entries, which are skipped as the target is. */
static bool
cf_rel_blocks_stream(Oid relid, StreamCheck *sc)
{
    char relkind = get_rel_relkind(relid);

    if (get_rel_persistence(relid) == RELPERSISTENCE_TEMP)
        return true;
    if (relkind == RELKIND_VIEW)
    {
        Relation    rel = relation_open(relid, AccessShareLock);
        Query      *vq  = get_view_query(rel);
        StreamCheck inner = { relid, sc->rels };
        bool        blocked;

        blocked = contain_mutable_functions((Node *) vq) ||
                  query_tree_walker(vq, cf_stream_blocker_walker, &inner,
                                    QTW_EXAMINE_RTES_BEFORE);
        relation_close(rel, NoLock);
        sc->rels = inner.rels;
        return blocked;
    }
    if (relkind != RELKIND_RELATION && relkind != RELKIND_PARTITIONED_TABLE &&
        relkind != RELKIND_MATVIEW)
        return true;
    sc->rels = lappend_oid(sc->rels, relid);
    return false;
}

static bool
cf_stream_blocker_walker(Node *node, void *ctx)
{
    StreamCheck *sc = (StreamCheck *) ctx;

    if (node == NULL)
        return false;
    if (IsA(node, RangeTblEntry))
    {
        RangeTblEntry *rte = (RangeTblEntry *) node;

        switch (rte->rtekind)
        {
            case RTE_RELATION:
                return rte->relid != sc->result_relid &&
                       cf_rel_blocks_stream(rte->relid, sc);
            case RTE_SUBQUERY:
            case RTE_JOIN:
            case RTE_FUNCTION:
            case RTE_VALUES:
            case RTE_RESULT:
#if PG_VERSION_NUM >= 180000
            case RTE_GROUP:
#endif
                return false;
            default:        /* a WITH entry, XMLTABLE, a trigger's transition table */
                return true;
        }
    }
    if (IsA(node, Query))
        return query_tree_walker((Query *) node, cf_stream_blocker_walker, ctx,
                                 QTW_EXAMINE_RTES_BEFORE);
    return expression_tree_walker(node, cf_stream_blocker_walker, ctx);
}

/* The tables as a regclass[] literal: the stream's p_sources. */
static char *
cf_regclass_array(List *rels)
{
    StringInfoData buf;
    ListCell      *lc;

    if (rels == NIL)
        return "'{}'::regclass[]";
    initStringInfo(&buf);
    appendStringInfoString(&buf, "ARRAY[");
    foreach(lc, rels)
        appendStringInfo(&buf, "%s%u::oid::regclass",
                         lc == list_head(rels) ? "" : ", ", lfirst_oid(lc));
    appendStringInfoChar(&buf, ']');
    return buf.data;
}

/*
 * Whether this transaction has written any of these tables, or a partition of
 * one. The backend's pending statistics entry for a table keeps the live
 * transaction's counts on its subtransaction chain and folds them into the
 * pending totals at commit, where they stay until the next flush, so only the
 * chain says what this transaction did: the totals would also count a
 * commit made a moment ago by this backend, and the copy find_tabstat_entry
 * returns has the chain detached, so the entry is read in place. Without
 * track_counts there is no answer, which counts as written. The hook calls
 * this before it emits the stream, and coldfront._written_in_xact is the same
 * function for _tiered_cold_stream's check at execution.
 */
static bool
cf_written_in_xact(List *rels)
{
    ListCell *lc;

    if (rels == NIL)
        return false;
    if (!pgstat_track_counts)
        return true;
    foreach(lc, rels)
    {
        List     *all = find_all_inheritors(lfirst_oid(lc), NoLock, NULL);
        ListCell *lp;

        foreach(lp, all)
        {
            PgStat_EntryRef        *ref = pgstat_fetch_pending_entry(PGSTAT_KIND_RELATION,
                                                                     MyDatabaseId, lfirst_oid(lp));
            PgStat_TableStatus     *ts = ref ? (PgStat_TableStatus *) ref->pending : NULL;
            PgStat_TableXactStatus *trans;

            for (trans = ts ? ts->trans : NULL; trans != NULL; trans = trans->upper)
                if (trans->tuples_inserted + trans->tuples_updated + trans->tuples_deleted > 0)
                    return true;
        }
    }
    return false;
}

PG_FUNCTION_INFO_V1(coldfront_written_in_xact);
Datum
coldfront_written_in_xact(PG_FUNCTION_ARGS)
{
    ArrayType *arr = PG_GETARG_ARRAYTYPE_P(0);
    Datum     *elems;
    bool      *nulls;
    int        n, i;
    List      *rels = NIL;

    deconstruct_array(arr, REGCLASSOID, sizeof(Oid), true, TYPALIGN_INT,
                      &elems, &nulls, &n);
    for (i = 0; i < n; i++)
        if (!nulls[i])
            rels = lappend_oid(rels, DatumGetObjectId(elems[i]));
    PG_RETURN_BOOL(cf_written_in_xact(rels));
}

static bool
cf_tiered_insert_streams(Query *query, Oid view_relid, List **sources)
{
    StreamCheck sc = { view_relid, NIL };

    *sources = NIL;
    if (coldfront_local_pg_dsn == NULL || coldfront_local_pg_dsn[0] == '\0')
        return false;
    if (IsolationUsesXactSnapshot() || query->cteList != NIL)
        return false;
    if (contain_mutable_functions((Node *) query))
        return false;
    if (query_tree_walker(query, cf_stream_blocker_walker, &sc, QTW_EXAMINE_RTES_BEFORE))
        return false;
    if (cf_written_in_xact(sc.rels))
        return false;
    *sources = sc.rels;
    return true;
}

/* The row count of a VALUES source: the list's length, 1 when the one row's
 * expressions sit in the target list, 0 for a SELECT source. */
static int
cf_values_rows(Query *query)
{
    ListCell *lc;
    int       idx = 0;

    foreach(lc, query->rtable)
    {
        RangeTblEntry *rte = (RangeTblEntry *) lfirst(lc);

        idx++;
        if (idx == query->resultRelation)
            continue;
        return rte->rtekind == RTE_VALUES ? list_length(rte->values_lists) : 0;
    }
    return 1;
}

/* The partition column of the source's derived table, cast to its hot type:
 * an untyped literal is text there, which no comparison with the cutoff
 * accepts. */
static char *
cf_pc_expr(TieredViewInfo *info, const HotColumns *hc)
{
    const char *type = hot_column_type(hc, info->partition_col);

    return psprintf("coldfront_src.%s%s%s", quote_identifier(info->partition_col),
                    type ? "::" : "", type ? type : "");
}

/*
 * The stream's read, as the SQL-text argument coldfront._tiered_cold_stream
 * receives (cold_sql_arg): the cold projection over the source below the
 * cutoff. Deparsed with an empty search_path, so every relation, function and
 * operator is schema-qualified whatever the other session's path is, and with
 * ISO dates and PostgreSQL intervals, so its literals read the same under
 * that session's DateStyle and IntervalStyle.
 */
static char *
cf_stream_pg_select(Query *query, TieredViewInfo *info, const HotColumns *hc,
                    const char *col_list, ColdParamSet *ps)
{
    DeparseResult dr;
    const char   *source;
    char         *sql;
    int           nest = NewGUCNestLevel();

    (void) set_config_option("search_path", "", PGC_USERSET, PGC_S_SESSION,
                             GUC_ACTION_SAVE, true, 0, false);
    (void) set_config_option("DateStyle", "ISO, YMD", PGC_USERSET, PGC_S_SESSION,
                             GUC_ACTION_SAVE, true, 0, false);
    (void) set_config_option("IntervalStyle", "postgres", PGC_USERSET, PGC_S_SESSION,
                             GUC_ACTION_SAVE, true, 0, false);
    deparse_and_find_prefix(query, &dr);
    source = skip_override_clause(skip_leading_collist(dr.rest), query->override);
    sql = psprintf("SELECT %s FROM (%s) AS coldfront_src(%s) WHERE %s < %s",
                   build_cold_projection(query, hc, true), source, col_list,
                   cf_pc_expr(info, hc), format_timestamptz_literal(info->cutoff));
    AtEOXact_GUC(true, nest);
    return cold_sql_arg(sql, ps, true);
}

/* The hot table's column names, or types, as a text[] literal. */
static char *
cf_text_array(char **items, int n)
{
    StringInfoData buf;
    int            i;

    initStringInfo(&buf);
    appendStringInfoString(&buf, "ARRAY[");
    for (i = 0; i < n; i++)
        appendStringInfo(&buf, "%s%s", i ? ", " : "", quote_literal_cstr(items[i]));
    appendStringInfoString(&buf, "]::text[]");
    return buf.data;
}

/* The cold half of the sink shape: the statement coldfront._cold_sink_sql
 * builds over the source rows below the cutoff, each projected to every
 * hot-table column (build_cold_projection). */
static char *
build_cold_sink_select(const char *vschema, const char *vname, const HotColumns *hc,
                       const char *projection, const char *partition_col,
                       const char *cutoff_lit)
{
    char *sql = NULL;

    if (SPI_connect() != SPI_OK_CONNECT)
        elog(ERROR, "coldfront: SPI_connect failed while building the cold sink's statement");
    if (SPI_execute(psprintf("SELECT coldfront._cold_sink_sql(%s, %s, %s, %s, %s)",
                             quote_literal_cstr(vschema), quote_literal_cstr(vname),
                             cf_text_array(hc->name, hc->n), cf_text_array(hc->type, hc->n),
                             quote_literal_cstr(psprintf(
                                 "SELECT %s FROM coldfront_source WHERE coldfront_source.%s < %s",
                                 projection, quote_identifier(partition_col), cutoff_lit))),
                    true, 1) == SPI_OK_SELECT && SPI_processed == 1)
    {
        MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);

        sql = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
        MemoryContextSwitchTo(oldcxt);
    }
    SPI_finish();
    if (sql == NULL)
        elog(ERROR, "coldfront: coldfront._cold_sink_sql returned nothing");
    return sql;
}

/* The deparsed INSERT spells OVERRIDING SYSTEM VALUE or OVERRIDING USER VALUE
 * between the column list and the source; the hot INSERT restates it, so the
 * source text drops it. */
static const char *
skip_override_clause(const char *rest, OverridingKind override)
{
    const char *kw = override == OVERRIDING_SYSTEM_VALUE ? "OVERRIDING SYSTEM VALUE" :
                     override == OVERRIDING_USER_VALUE   ? "OVERRIDING USER VALUE"   : NULL;

    while (*rest == ' ') rest++;
    if (kw != NULL && strncmp(rest, kw, strlen(kw)) == 0)
    {
        rest += strlen(kw);
        while (*rest == ' ') rest++;
    }
    return rest;
}

/*
 * Wrap the hot INSERT and the cold half into one statement, behind the
 * statement's own WITH entries (dr->head_len bytes), which stay at the top
 * level: PostgreSQL allows an entry that modifies data nowhere else. The sink
 * shape adds the materialized source (src_cte) that both halves read.
 *
 * At top level the hot INSERT and the cold half are CTEs and the statement
 * reports (hot_rows, cold_rows): the sink's count, or the stream's, which is
 * NULL when the rows streamed (DuckDB keeps that count) and the count
 * otherwise. In plpgsql, and for an INSERT nested in WITH, the hot INSERT is
 * the statement itself (the DML tag plpgsql accepts, and the body the WITH
 * entry keeps once cf_splice_nested_dml lifts the rest out), and the cold half
 * rides in a data-modifying CTE (cold_anchor_update) that always runs to
 * completion and updates no row: the sink's count is never NULL, and the
 * stream's count is never negative, with NULL < 0 being no match.
 */
static char *
wrap_tiered_result(bool in_plpgsql, const DeparseResult *dr, const char *src_cte,
                   const char *hot_dml, const char *cold_select, const char *anchor_test)
{
    StringInfoData buf;

    initStringInfo(&buf);
    append_with_opener(&buf, dr);
    if (src_cte != NULL)
        appendStringInfo(&buf, "coldfront_source AS MATERIALIZED (%s), ", src_cte);
    if (in_plpgsql)
        appendStringInfo(&buf, "coldfront_cold AS (%s) %s",
                         cold_anchor_update(psprintf("(%s)", cold_select), anchor_test),
                         hot_dml);
    else
        appendStringInfo(&buf, "coldfront_hot AS MATERIALIZED (%s RETURNING 1), "
                         "coldfront_cold AS MATERIALIZED (%s) "
                         "SELECT (SELECT count(*) FROM coldfront_hot) AS hot_rows, "
                         "       (SELECT n FROM coldfront_cold) AS cold_rows",
                         hot_dml, cold_select);
    return buf.data;
}

/*
 * emit_tiered_insert rewrites a tiered-view INSERT into one statement that
 * splits the source by the partition column against the watermark, in one of
 * two shapes.
 *
 * The stream shape, when cf_tiered_insert_streams proves the source safe to
 * read twice:
 *
 *   WITH coldfront_hot AS MATERIALIZED (INSERT INTO <hot> (cols) SELECT <cols,
 *                                       each cast to its hot type> FROM
 *                                       (<source>) AS coldfront_src(cols)
 *                                       WHERE <partcol> >= <cutoff> RETURNING 1),
 *        coldfront_cold AS MATERIALIZED (SELECT coldfront._tiered_cold_stream(
 *                                        schema, view, <the cold projection over
 *                                        the source below the cutoff, as text>,
 *                                        <the tables the source reads>,
 *                                        <whether any row is cold>) AS n)
 *   SELECT hot_rows, cold_rows
 *
 * The hot half is plain PG: set-based, IDENTITY and DEFAULT fill server-side.
 * The cold half is one DuckDB statement: INSERT INTO <ice> SELECT ... FROM
 * postgres_query('pgstream', <that text>), so the rows go from PostgreSQL into
 * the Iceberg writer in one vectorized pass, with the identity values and
 * defaults the projection draws in PostgreSQL. A VALUES source's cold test is
 * the hot count against its row count; a SELECT source's is an EXISTS over
 * the source, so an all-hot INSERT stages nothing and takes no claim.
 *
 * The sink shape, for every other source:
 *
 *   WITH <the INSERT's own WITH entries, if any>,
 *        coldfront_source AS MATERIALIZED (<source, each column cast to its
 *                                          hot type>),
 *        coldfront_hot AS MATERIALIZED (INSERT INTO <hot> (cols) SELECT cols
 *                                       FROM coldfront_source
 *                                       WHERE <partcol> >= <cutoff> RETURNING 1),
 *        coldfront_cold AS MATERIALIZED (SELECT coldfront._cold_sink(schema,
 *                                        view, to_jsonb(r)) FROM (<every hot
 *                                        column FROM coldfront_source WHERE
 *                                        <partcol> < <cutoff>>) AS r)
 *   SELECT hot_rows, cold_rows
 *
 * Both halves read the one tuplestore, so a volatile source, or a row the
 * transaction wrote before the INSERT, lands exactly once; the sink renders
 * each row as a DuckDB VALUES tuple and writes a batch every
 * coldfront.cold_write_batch_size rows (coldfront--1.0.sql).
 *
 * Bound parameters ($N) stay in the source, which PostgreSQL runs, so they
 * bind natively; the stream's text carries them as format() arguments.
 * RETURNING is not preserved.
 */
static char *
emit_tiered_insert(Query *query, TieredViewInfo *info, ColdParamSet *ps,
                   bool in_plpgsql, Oid view_relid)
{
    DeparseResult  dr;
    HotColumns     hc;
    List          *sources;
    char          *col_list, *cutoff_lit, *hot_dml, *cold_select;
    const char    *source, *vname, *vschema, *override;

    deparse_and_find_prefix(query, &dr);
    col_list   = insert_targetlist_collist(query);
    source     = skip_override_clause(skip_leading_collist(dr.rest), query->override);
    cutoff_lit = format_timestamptz_literal(info->cutoff);
    override   = query->override == OVERRIDING_SYSTEM_VALUE ? "OVERRIDING SYSTEM VALUE " :
                 query->override == OVERRIDING_USER_VALUE   ? "OVERRIDING USER VALUE "   : "";
    vname      = get_rel_name(view_relid);
    vschema    = get_namespace_name(get_rel_namespace(view_relid));
    load_hot_columns(info->hot_table, &hc);

    if (cf_tiered_insert_streams(query, view_relid, &sources))
    {
        const char *src_select = build_src_cte(query, source, col_list, &hc);
        const char *pc_expr    = cf_pc_expr(info, &hc);
        int         nvalues    = cf_values_rows(query);
        char       *any_cold;

        hot_dml  = build_tiered_hot_dml(info->hot_table, col_list, override,
                                        src_select + strlen("SELECT "), "",
                                        pc_expr, cutoff_lit);
        any_cold = !in_plpgsql && nvalues > 0
            ? psprintf("(SELECT count(*) FROM coldfront_hot) < %d", nvalues)
            : psprintf("EXISTS (SELECT 1 FROM (%s) AS coldfront_src(%s) WHERE %s < %s)",
                       source, col_list, pc_expr, cutoff_lit);
        cold_select = psprintf("SELECT coldfront._tiered_cold_stream(%s, %s, %s, %s, %s) AS n",
                               quote_literal_cstr(vschema), quote_literal_cstr(vname),
                               cf_stream_pg_select(query, info, &hc, col_list, ps),
                               cf_regclass_array(sources), any_cold);
        return wrap_tiered_result(in_plpgsql, &dr, NULL, hot_dml, cold_select, "< 0");
    }

    hot_dml     = build_tiered_hot_dml(info->hot_table, col_list, override, col_list,
                                       "FROM coldfront_source",
                                       quote_identifier(info->partition_col), cutoff_lit);
    cold_select = build_cold_sink_select(vschema, vname, &hc,
                                         build_cold_projection(query, &hc, false),
                                         info->partition_col, cutoff_lit);
    return wrap_tiered_result(in_plpgsql, &dr, build_src_cte(query, source, col_list, &hc),
                              hot_dml, cold_select, "IS NULL");
}

/*
 * Call coldfront.ensure_attached() via SPI.  Used on the cold and dual
 * paths so duckdb.raw_query() has the Iceberg catalog attached.
 */
static void
ensure_attached_via_spi(void)
{
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        SPI_execute("SELECT coldfront.ensure_attached()", false, 0);
        SPI_finish();
    }
}

/*
 * Attach the Iceberg 'ice' catalog at most once per session.  The guard makes
 * repeat calls free, so both the read path (first tiered-view SELECT) and the
 * cold-DML path call it cheaply.  coldfront.ensure_attached() uses ATTACH IF
 * NOT EXISTS and has NO plpgsql EXCEPTION clause, so this runs in the top
 * transaction (pg_duckdb hard-rejects ATTACH inside a subtransaction).  Cleared
 * on transaction abort (coldfront_xact_callback).
 */
static void
ensure_ice_attached_once(void)
{
    if (coldfront_ice_attached)
        return;
    ensure_attached_via_spi();
    coldfront_ice_attached = true;
}

/*
 * Call coldfront.ensure_pg_attached() via SPI. Used on the INSERT cold
 * path so raw_query can resolve `pglocal.<schema>.<table>` references in
 * INSERT … SELECT FROM pg_source statements via DuckDB's postgres
 * extension. No-op (cheap) when coldfront.local_pg_dsn is unset.
 */
static void
ensure_pg_attached_via_spi(void)
{
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        SPI_execute("SELECT coldfront.ensure_pg_attached()", false, 0);
        SPI_finish();
    }
}

/*
 * Refuse a RETURNING clause on any write that touches the cold tier. duckdb-iceberg
 * 5edc45f0 (the pinned build) refuses RETURNING on every Iceberg write: a
 * BinderException "RETURNING clause not yet supported for ..." from
 * src/execution/operator/iceberg_insert.cpp, iceberg_update.cpp and
 * iceberg_delete.cpp, and a NotImplementedException from
 * merge_into/iceberg_merge_into.cpp; and pg_duckdb's row-returning entry
 * point (duckdb.query) runs a SELECT alone. Without this refusal a dual write
 * would return its hot rows alone, a cold write a void internal row, a tiered
 * INSERT nothing. Hot-only DML keeps RETURNING (plain PostgreSQL DML); the
 * cold, dual, tiered-INSERT and cross-tier-move paths call this, so the
 * emitters behind them deparse a statement without RETURNING. The journey
 * check "duckdb-iceberg refuses RETURNING on an Iceberg write" sends such a
 * write to DuckDB directly and fails once the pin accepts it.
 */
static void
reject_cold_returning(Query *query, const char *vname)
{
    if (query->returningList != NIL)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("RETURNING is not supported for writes to the cold tier of \"%s\"", vname),
                 errhint("The cold tier (Iceberg) cannot return affected rows: duckdb-iceberg "
                         "does not support RETURNING on writes. Re-run without RETURNING.")));
}

/*
 * Refuse a WITH entry that modifies data on a write that runs in DuckDB. DuckDB
 * 1.5.4 (the pinned build) has no data-modifying WITH: its parser takes only a
 * SELECT as an entry's body. DuckDB 2.0 (branch v2.0-cyanoptera) runs INSERT,
 * UPDATE and DELETE entries, so on it the WITH can ship whole, the entry's
 * write running through the pglocal attachment on the terms a source table
 * read has (committed rows, the attachment's role). That also needs
 * duckdb-postgres to return the rows of such a write, which it refuses
 * ("RETURNING clause not yet supported", src/storage/postgres_delete.cpp).
 * pg_regress cte_on_dml sends such a WITH to DuckDB directly and fails once
 * the pin accepts it.
 */
static void
reject_cold_modifying_cte(Query *query, const char *vname)
{
    if (query->hasModifyingCTE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("a cold-tier write on \"%s\" cannot use a data-modifying WITH query", vname),
                 errdetail("The cold tier runs the statement in DuckDB, where a WITH query must be a SELECT."),
                 errhint("Run the WITH query's write as a separate statement.")));
}

/* True when the query reads a WITH entry it does not define itself. */
static bool
reads_outer_cte_walker(Node *node, void *ctx)
{
    if (node == NULL)
        return false;
    if (IsA(node, RangeTblEntry))
    {
        RangeTblEntry *rte = (RangeTblEntry *) node;
        ListCell      *lc;

        if (rte->rtekind != RTE_CTE)
            return false;
        foreach(lc, (List *) ctx)
            if (strcmp(((CommonTableExpr *) lfirst(lc))->ctename, rte->ctename) == 0)
                return false;
        return true;
    }
    if (IsA(node, Query))
        return query_tree_walker((Query *) node, reads_outer_cte_walker, ctx,
                                 QTW_EXAMINE_RTES_BEFORE);
    return expression_tree_walker(node, reads_outer_cte_walker, ctx);
}

/*
 * Refuse a write that runs in DuckDB and reads a WITH entry it does not define:
 * only a write nested in WITH can (the entries around it), and DuckDB does not
 * see them.
 */
static void
reject_cold_outer_cte(Query *query, const char *vname)
{
    if (query_tree_walker(query, reads_outer_cte_walker, (void *) query->cteList,
                          QTW_EXAMINE_RTES_BEFORE))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("a cold-tier write on \"%s\" nested in WITH cannot read another WITH entry", vname),
                 errdetail("It runs in DuckDB, which does not see the statement's WITH entries."),
                 errhint("Run it as its own statement.")));
}

/*
 * Build the rewritten SQL for a tiered-view INSERT (bulk split-by-watermark).
 * Tiered without a watermark yet (no archive run): everything is hot; emit a
 * plain hot INSERT. With a watermark, some rows go cold (cannot RETURN them).
 */
static char *
cf_emit_tiered_insert_path(Query *query, Oid view_relid, TieredViewInfo *info,
                           ColdParamSet *ps, bool in_plpgsql, const char *vname)
{
    if (!info->has_cutoff)
        return emit_hot(query, info);

    /* A watermark-split INSERT sends some rows to the cold tier,
     * which cannot return them — refuse RETURNING rather than drop it. */
    reject_cold_returning(query, vname);
    return emit_tiered_insert(query, info, ps, in_plpgsql, view_relid);
}

/* Build the rewritten SQL for a cold-tier UPDATE/DELETE/INSERT/MERGE (TIER_COLD). */
static char *
cf_emit_cold_path(Query *query, TieredViewInfo *info, ColdParamSet *ps,
                  bool in_plpgsql, const char *vname)
{
    reject_cold_returning(query, vname);
    reject_cold_modifying_cte(query, vname);
    reject_cold_outer_cte(query, vname);
    ensure_ice_attached_once();
    /* A PostgreSQL table the statement reads is served through pglocal, so
     * that attachment is made first. A statement without one (VALUES,
     * generate_series, read_parquet) runs in DuckDB alone, and the ATTACH
     * itself fails on some pg_duckdb builds (the loopback recursion noted on
     * coldfront.ensure_pg_attached), so it is skipped then. */
    if (query_has_pg_source_table(query))
        ensure_pg_attached_via_spi();
    return emit_cold(query, info, ps, in_plpgsql);
}

/* Build the rewritten SQL for a dual-tier UPDATE/DELETE (TIER_AMBIGUOUS, only
 * when coldfront.allow_mixed_writes is on). */
static char *
cf_emit_dual_path(Query *query, TieredViewInfo *info, ColdParamSet *ps,
                  bool in_plpgsql, const char *vname)
{
    if (!coldfront_allow_mixed_writes)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("UPDATE/DELETE on tiered view \"%s\" must include "
                        "a WHERE condition on \"%s\" that targets one tier",
                        vname, info->partition_col),
                 errhint("Use \"%s >= <value>\" for hot-tier writes, "
                         "\"%s < <value>\" for cold-tier writes, or set "
                         "coldfront.allow_mixed_writes = on to permit a "
                         "non-atomic dual-tier rewrite.",
                         info->partition_col, info->partition_col)));

    /* A dual-tier rewrite returns only hot rows; refuse RETURNING rather
     * than silently return a partial result set. */
    reject_cold_returning(query, vname);
    reject_cold_modifying_cte(query, vname);
    reject_cold_outer_cte(query, vname);

    /* Permissive: clear pg_duckdb's mixed-write guard for this
     * transaction (GUC_ACTION_LOCAL resets it at tx end) and emit
     * a dual-tier CTE. */
    (void) set_config_option("duckdb.unsafe_allow_mixed_transactions",
                             "on",
                             PGC_USERSET, PGC_S_SESSION,
                             GUC_ACTION_LOCAL, true, 0, false);
    ensure_ice_attached_once();
    return emit_dual(query, info, ps, in_plpgsql);
}

/* Parse and analyze the rewritten SQL, guarded against re-entry, and replace
 * the original Query in place. The bound-param types declared so the rewritten
 * SQL's live $N re-bind at execution (unseen ids default to text). */
static void
cf_reparse_and_replace(Query *query, const char *new_sql, ColdParamSet *ps)
{
    List    *parsetree_list;
    RawStmt *raw;
    Query   *rewritten;

    coldfront_in_rewrite = true;
    PG_TRY();
    {
        parsetree_list = pg_parse_query(new_sql);
        if (list_length(parsetree_list) != 1)
            elog(ERROR,
                 "coldfront: unexpected parse result for rewritten query");

        raw       = linitial_node(RawStmt, parsetree_list);
        /* Declare the bound-param types so the rewritten SQL's live $N (Cause 1's
         * format() args, plus the native $N the hot/dual legs keep) re-bind at
         * execution; unseen ids in a sparse set default to text. */
        if (ps->maxid > 0)
        {
            Oid *ptypes = (Oid *) palloc(sizeof(Oid) * ps->maxid);
            int  i;
            for (i = 0; i < ps->maxid; i++)
                ptypes[i] = ps->seen[i] ? ps->types[i] : TEXTOID;
            rewritten = parse_analyze_fixedparams(raw, new_sql, ptypes, ps->maxid, NULL);
        }
        else
            rewritten = parse_analyze_fixedparams(raw, new_sql, NULL, 0, NULL);

        /* Replace the original Query in-place */
        memcpy(query, rewritten, sizeof(Query)); /* nosemgrep */
    }
    PG_FINALLY();
    {
        coldfront_in_rewrite = false;
    }
    PG_END_TRY();
}

/*
 * Hot-tier read routing. When a SELECT's WHERE provably restricts to the hot tier
 * (classify_qual → TIER_HOT: the predicate proves ts >= cutoff, and cold rows all
 * have ts < cutoff), the rows it can return are exactly those the hot heap already
 * holds. Re-point the tiered-view reference at that heap and reparse: the read then
 * runs in plain PostgreSQL — full jsonb, no DuckDB round-trip — instead of pg_duckdb
 * planning the whole hot/cold UNION in DuckDB. The reparse re-resolves column
 * types (the view casts data::json; the heap is native jsonb).
 *
 * Conservative by construction — only the simple single-relation shape (no join, CTE,
 * set-op, sub-link, or row-mark) and only a proven-HOT predicate reroute; anything
 * spanning tiers or ambiguous keeps the view, so cold rows can never be dropped.
 * Returns true if it rerouted (and replaced *query in place).
 */
static bool
cf_try_reroute_hot_read(Query *query)
{
    RangeTblEntry *view_rte;
    TieredViewInfo info;
    AttrNumber     partcol_attno;
    Oid            hot_oid;
    char           hot_relkind;
    Node          *quals;
    Query         *clone;
    RangeTblEntry *crte;
    char          *sql;
    ColdParamSet   ps;
    RangeVar      *rv;
    List          *names;

    if (query->cteList || query->setOperations || query->hasSubLinks ||
        query->rowMarks || list_length(query->rtable) != 1)
        return false;

    view_rte = (RangeTblEntry *) linitial(query->rtable);
    if (view_rte->rtekind != RTE_RELATION ||
        get_rel_relkind(view_rte->relid) != RELKIND_VIEW)
        return false;
    if (!lookup_tiered_view(view_rte->relid, get_rel_name(view_rte->relid), &info))
        return false;
    if (info.is_iceberg_only || !info.hot_table || !info.partition_col ||
        !info.has_cutoff)
        return false;

    /* The predicate must prove the read touches only the hot tier. */
    partcol_attno = get_attnum(view_rte->relid, info.partition_col);
    if (partcol_attno == InvalidAttrNumber)
        return false;
    quals = (query->jointree) ? query->jointree->quals : NULL;
    if (classify_qual(quals, 1, partcol_attno, info.cutoff) != TIER_HOT)
        return false;

    /* Resolve the hot heap (relname is a ready-to-use, possibly-quoted SQL name). */
    names = stringToQualifiedNameList(info.hot_table
#if PG_VERSION_NUM >= 160000
                                      , NULL
#endif
                                      );
    rv          = makeRangeVarFromNameList(names);
    hot_oid     = RangeVarGetRelid(rv, NoLock, true);
    hot_relkind = OidIsValid(hot_oid) ? get_rel_relkind(hot_oid) : '\0';
    if (hot_relkind != RELKIND_RELATION && hot_relkind != RELKIND_PARTITIONED_TABLE)
        return false;

    /* Re-point the relation at the heap, deparse, and reparse in place so column
     * types re-resolve and the query plans in plain PG. */
    clone = copyObject(query);
    crte  = (RangeTblEntry *) linitial(clone->rtable);
    crte->relid       = hot_oid;
    crte->relkind     = hot_relkind;
    crte->rellockmode = AccessShareLock;
    sql = pg_get_querydef(clone, false);

    collect_cold_params(query, &ps);
    cf_reparse_and_replace(query, sql, &ps);
    return true;
}

/*
 * Make a read DuckDB will run acceptable to it. A query against a tiered /
 * iceberg-only view runs entirely in DuckDB (the view body reads the Iceberg
 * table), which has no jsonb type, no date_bin, no JSON builders and no <#>
 * operator. Two passes over the analysed tree: the JSON builders and the <#>
 * operator are rewritten on the node tree (cf_json_builder_mutator, where
 * key/value pairing is exact and the operator's function is known), then the deparsed
 * text gets the read whitelist (normalize_for_read: the ::jsonb cast and the
 * functions verified equivalent in both engines), and the result is reparsed in
 * place. Nothing to rewrite ⇒ the query is left untouched (the common case: ->>/->
 * operators and plain reads never reparse). Other jsonb spellings pass through and
 * DuckDB rejects them clearly (documented).
 */
static void
cf_normalize_read(Query *query)
{
    JsonBuilderCtx jc   = { false };
    Query         *tree = query_tree_mutator(query, cf_json_builder_mutator, &jc, 0);
    char          *sql  = pg_get_querydef(tree, false);
    char          *norm = normalize_for_read(sql);
    ColdParamSet   ps;

    if (!jc.changed && strcmp(sql, norm) == 0)  /* nosemgrep */
        return;
    collect_cold_params(query, &ps);
    cf_reparse_and_replace(query, norm, &ps);
}

/*
 * Resolve a node through the grouping RTE. A grouped query's sort expression
 * references grouping expressions as Vars of RTE_GROUP, and the expression the
 * shape check needs is the one they stand for. On releases without the grouping
 * RTE, grouped queries carry the base-relation Vars directly, so this is the
 * identity there.
 */
static Node *
cf_unwrap_group_var(Query *query, Node *node)
{
#if PG_VERSION_NUM >= 180000
    if (node != NULL && IsA(node, Var))
    {
        Var *var = (Var *) node;

        if (var->varlevelsup == 0 &&
            var->varno >= 1 && var->varno <= list_length(query->rtable))
        {
            RangeTblEntry *rte = rt_fetch(var->varno, query->rtable);

            if (rte->rtekind == RTE_GROUP)
                return (Node *) list_nth(rte->groupexprs, var->varattno - 1);
        }
    }
#endif
    return node;
}

/* True for a reference to a column of the query's single range-table entry.
 * InvalidAttrNumber matches any column, for a caller that wants to learn which. */
static bool
cf_is_single_rel_var(Node *node, AttrNumber attno)
{
    Var *var;

    if (node == NULL || !IsA(node, Var))
        return false;
    var = (Var *) node;
    if (var->varno != 1 || var->varlevelsup != 0)
        return false;
    return attno == InvalidAttrNumber || var->varattno == attno;
}

/*
 * The query vector as a PostgreSQL literal, or NULL if this expression is not one.
 *
 * The vector has to be inlined: pg_duckdb converts neither a `vector` nor a
 * `real[]` bound parameter, on a custom plan as much as a generic one, so a probe
 * that could only be computed from a parameter's value could not have run the
 * search either. Constant-folded first, because the caller writes ARRAY[…]::real[]
 * (an ArrayExpr of constants) or a `vector` literal the operator's implicit cast
 * wraps, and neither is a Const until it is folded.
 */
static char *
cf_query_vector_literal(Node *expr)
{
    Const *c;
    Oid    typoutput;
    bool   typisvarlena;

    c = (Const *) expression_planner((Expr *) copyObject(expr));
    if (!IsA(c, Const) || c->constisnull || c->consttype != FLOAT4ARRAYOID)
        return NULL;
    getTypeOutputInfo(c->consttype, &typoutput, &typisvarlena);
    return OidOutputFunctionCall(typoutput, c->constvalue);
}

/*
 * The shape the probe rewrite recognises: a single-relation SELECT on a
 * registered view with a clustered vector column, ordered by one cosine distance
 * between that column and a constant, with a LIMIT. Grouping, aggregation,
 * windows and DISTINCT above that ORDER BY are part of the shape; they compute
 * over whatever the narrowed scan reads.
 *
 * The LIMIT is not a detail: a probe trades recall for reads, which is the
 * bargain a top-k asks for and not one to impose on a query that asked for every
 * row in order. Cosine only, because the centroids were trained under cosine and
 * ordering by another metric would route to the wrong clusters and report
 * nothing. Which column is being searched comes from the query rather than the
 * registry, because a table may carry several vector columns; a column with no
 * configuration resolves to no probe set downstream and the rewrite declines.
 *
 * On a match, *vec_name is the searched column and *vec_lit the query vector's
 * PostgreSQL literal.
 */
static bool
cf_probe_match(Query *query, char **vec_name, char **vec_lit)
{
    RangeTblEntry  *view_rte;
    TieredViewInfo  info;
    SortGroupClause *sgc;
    TargetEntry    *tle = NULL;
    ListCell       *lc;
    Node           *expr;
    List           *args;
    Oid             funcid;
    char           *fname;
    AttrNumber      vec_attno;
    Node           *lhs, *rhs, *other;
    int             nrte;

    nrte = list_length(query->rtable);
#if PG_VERSION_NUM >= 180000
    /* A grouped query carries an RTE_GROUP entry holding the grouping
     * expressions. It adds no second scan, so it does not disqualify the shape;
     * its Vars are unwrapped where the sort expression is matched. */
    if (nrte == 2 &&
        ((RangeTblEntry *) lsecond(query->rtable))->rtekind == RTE_GROUP)
        nrte = 1;
#endif
    if (query->cteList || query->setOperations || query->hasSubLinks ||
        query->rowMarks || nrte != 1 ||
        list_length(query->sortClause) != 1 || query->limitCount == NULL)
        return false;

    view_rte = (RangeTblEntry *) linitial(query->rtable);
    if (view_rte->rtekind != RTE_RELATION ||
        get_rel_relkind(view_rte->relid) != RELKIND_VIEW)
        return false;
    if (!lookup_tiered_view(view_rte->relid, get_rel_name(view_rte->relid), &info))
        return false;
    if (!info.has_vector)
        return false;

    /* The single sort key, which may be resjunk (ORDER BY an unselected expr). */
    sgc = (SortGroupClause *) linitial(query->sortClause);
    foreach(lc, query->targetList)
    {
        TargetEntry *t = (TargetEntry *) lfirst(lc);

        if (t->ressortgroupref == sgc->tleSortGroupRef)
        {
            tle = t;
            break;
        }
    }
    if (tle == NULL)
        return false;

    /* Written as an operator or as the function behind it; both name the same. */
    expr = cf_unwrap_group_var(query, (Node *) tle->expr);
    if (IsA(expr, OpExpr))
    {
        funcid = ((OpExpr *) expr)->opfuncid;
        args   = ((OpExpr *) expr)->args;
    }
    else if (IsA(expr, FuncExpr))
    {
        funcid = ((FuncExpr *) expr)->funcid;
        args   = ((FuncExpr *) expr)->args;
    }
    else
        return false;
    if (list_length(args) != 2)
        return false;
    fname = get_func_name(funcid);
    if (fname == NULL || strcmp(fname, "list_cosine_distance") != 0)  /* nosemgrep */
        return false;

    /* One side is a column of the view, the other is the query vector. */
    lhs = cf_unwrap_group_var(query, (Node *) linitial(args));
    rhs = cf_unwrap_group_var(query, (Node *) lsecond(args));
    if (cf_is_single_rel_var(lhs, InvalidAttrNumber))
    {
        vec_attno = ((Var *) lhs)->varattno;
        other     = rhs;
    }
    else if (cf_is_single_rel_var(rhs, InvalidAttrNumber))
    {
        vec_attno = ((Var *) rhs)->varattno;
        other     = lhs;
    }
    else
        return false;
    *vec_name = get_attname(view_rte->relid, vec_attno, true);
    if (*vec_name == NULL)
        return false;
    *vec_lit = cf_query_vector_literal(other);
    return *vec_lit != NULL;
}

/*
 * Probe injection. A top-k similarity search over a clustered tiered view
 * (cf_probe_match) is rewritten to read only the clusters nearest the query
 * vector, which is what turns the layout every write maintains into a shorter
 * read. Every other shape is left exactly as it was: that is an exact scan,
 * which is correct.
 *
 * The predicate cannot be added to the caller's query, because the column it
 * tests is deliberately in no branch of the view (see coldfront._vec_list_col).
 * So the view reference is replaced by the view's own definition with its cold
 * arm twice: once carrying the predicate, once carrying IS NULL for the rows
 * with no assignment. DuckDB pushes an IN into the scan but not an OR that
 * carries IS NULL, and the second arm costs nothing when every row is assigned.
 * That puts the test where the column exists and leaves the caller's query
 * surface alone. Nothing here is text surgery on the
 * caller's SQL: the substitution swaps one range-table entry for a subquery and
 * PostgreSQL deparses the result.
 *
 * Declining is silent and total. A table with no centroid generation, a probe
 * set that resolves to nothing, a view with no cold arm: all of them keep
 * today's query. The read is then slower than it could be, never wrong, which is
 * the right direction for a read to fail in (a WRITE that cannot resolve a
 * generation has to fail loudly instead).
 */
static void
cf_maybe_inject_probe(Query *query)
{
    RangeTblEntry  *view_rte;
    char           *vec_name;
    char           *vec_lit;
    char           *body = NULL;
    Query          *clone;
    RangeTblEntry  *crte;
    char           *sql;
    ColdParamSet    ps;
    StringInfoData  q;

    if (!coldfront_vector_probe)
        return;
    if (!cf_probe_match(query, &vec_name, &vec_lit))
        return;
    view_rte = (RangeTblEntry *) linitial(query->rtable);

    /* Resolve the probe set and the definition that carries it, in one round trip. */
    initStringInfo(&q);
    appendStringInfo(&q,
                     "SELECT coldfront._vec_probed_viewdef(%s, %s, %s, "
                     "coldfront._vec_probe_ids(%s, %s, %s, %s::real[], %s))",
                     quote_literal_cstr(get_namespace_name(
                                            get_rel_namespace(view_rte->relid))),
                     quote_literal_cstr(get_rel_name(view_rte->relid)),
                     quote_literal_cstr(vec_name),
                     quote_literal_cstr(get_namespace_name(
                                            get_rel_namespace(view_rte->relid))),
                     quote_literal_cstr(get_rel_name(view_rte->relid)),
                     quote_literal_cstr(vec_name),
                     quote_literal_cstr(vec_lit),
                     coldfront_vector_nprobe > 0
                         ? psprintf("%d", coldfront_vector_nprobe) : "NULL");
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        if (SPI_execute(q.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
        {
            MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);

            body = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
            MemoryContextSwitchTo(oldcxt);
        }
        SPI_finish();
    }
    if (body == NULL)
        return;

    /* Stand the probed definition in for the view, then deparse and reparse so the
     * whole statement is planned against it. */
    clone = copyObject(query);
    crte  = (RangeTblEntry *) linitial(clone->rtable);

    coldfront_in_rewrite = true;
    PG_TRY();
    {
        List    *parsetree_list = pg_parse_query(body);
        RawStmt *raw            = linitial_node(RawStmt, parsetree_list);

        crte->subquery = parse_analyze_fixedparams(raw, body, NULL, 0, NULL);
    }
    PG_FINALLY();
    {
        coldfront_in_rewrite = false;
    }
    PG_END_TRY();

    crte->rtekind       = RTE_SUBQUERY;
    crte->relid         = InvalidOid;
    crte->relkind       = 0;
    crte->rellockmode   = NoLock;
    crte->inh           = false;
    /* The caller's query names its columns by the view's name, so the subquery
     * answers to it too. */
    crte->alias         = makeAlias(crte->eref->aliasname, NIL);
#if PG_VERSION_NUM >= 160000
    crte->perminfoindex = 0;
#endif

    sql = pg_get_querydef(clone, false);
    collect_cold_params(query, &ps);
    cf_reparse_and_replace(query, sql, &ps);
}

/*
 * Read path for a SELECT that touches a registered tiered view. First try to
 * reroute a provably-hot read to the heap (runs in plain PG). Otherwise the read
 * spans the cold tier: lazily attach
 * 'ice' (once per session) so the view body's read of ice.<ns>.<table> resolves
 * (the version-agnostic cold-read attach, PG 16/17/18), narrow a recognised
 * similarity search to its probed clusters, and rewrite the spellings DuckDB (which
 * runs the whole view query) lacks into ones it accepts. The relkind check inside
 * query_reads_tiered_view keeps plain queries off the SPI path.
 */
static void
cf_maybe_attach_for_read(Query *query)
{
    if (query->commandType != CMD_SELECT || !query_reads_tiered_view(query))
        return;
    if (cf_try_reroute_hot_read(query))
        return;   /* rewritten to the hot heap; runs in plain PostgreSQL */
    if (!coldfront_ice_attached)
        ensure_ice_attached_once();
    cf_maybe_inject_probe(query);
    cf_normalize_read(query);
}

/* True when the DML `query` writes a registered tiered view; *rte and *info
 * describe it. */
static bool
cf_dml_target_view(Query *query, RangeTblEntry **rte, TieredViewInfo *info)
{
    if (query->resultRelation == 0)
        return false;
    *rte = rt_fetch(query->resultRelation, query->rtable);
    if ((*rte)->rtekind != RTE_RELATION ||
        get_rel_relkind((*rte)->relid) != RELKIND_VIEW)
        return false;
    return lookup_tiered_view((*rte)->relid, get_rel_name((*rte)->relid), info);
}

/*
 * Resolve the DML target: decide whether `query` is an INSERT/UPDATE/DELETE/
 * MERGE on a registered tiered view that this hook should rewrite. On the read
 * path (SELECT touching a tiered view) it lazily attaches 'ice' and returns
 * false. Returns true with *rte and *info populated when a rewrite is
 * warranted.
 */
static bool
cf_resolve_tiered_dml_target(Query *query, RangeTblEntry **rte,
                             TieredViewInfo *info)
{
    /* Intercept INSERT, UPDATE, DELETE and MERGE on registered tiered views.
     * INSERT is rewritten in both modes: a tiered INSERT splits by the
     * watermark cutoff (cf_emit_tiered_insert_path), an iceberg-only INSERT
     * goes straight to the cold path. A MERGE runs on the tier its ON
     * condition bounds (cf_emit_merge_path). */
    if (query->commandType != CMD_UPDATE &&
        query->commandType != CMD_DELETE &&
        query->commandType != CMD_INSERT &&
        query->commandType != CMD_MERGE)
    {
        cf_maybe_attach_for_read(query);
        return false;
    }

    return cf_dml_target_view(query, rte, info);
}

/*
 * The first WITH entry of `query` that is an INSERT, UPDATE, DELETE or MERGE
 * on a registered tiered view, or NULL; *nwrites counts them all. Only a
 * top-level statement can hold one (parse_cte.c, which admits a MERGE from
 * PostgreSQL 17), and parse_sub_analyze runs no post_parse_analyze_hook for
 * it, so the hook meets it here, inside the statement that holds it.
 */
static CommonTableExpr *
cf_find_nested_dml(Query *query, RangeTblEntry **rte, TieredViewInfo *info,
                   int *nwrites)
{
    CommonTableExpr *found = NULL;
    ListCell        *lc;

    *nwrites = 0;
    foreach(lc, query->cteList)
    {
        CommonTableExpr *cte = (CommonTableExpr *) lfirst(lc);
        Query           *q = (Query *) cte->ctequery;
        RangeTblEntry   *r;
        TieredViewInfo   i;

        if ((q->commandType != CMD_INSERT && q->commandType != CMD_UPDATE &&
             q->commandType != CMD_DELETE && q->commandType != CMD_MERGE) ||
            !cf_dml_target_view(q, &r, &i))
            continue;
        if (found == NULL)
        {
            found = cte;
            *rte = r;
            *info = i;
        }
        (*nwrites)++;
    }
    return found;
}

/*
 * Skip a quoted run ('…' or "…", a doubled quote included) or a balanced
 * parenthesised run, quoted runs inside it included; p is at its first byte.
 * The deparser never escapes a quote with a backslash, so quotes come in pairs.
 */
static const char *
skip_quoted_or_parens(const char *p)
{
    char q = *p;
    int  depth = 0;

    if (q == '\'' || q == '"')
    {
        for (p++; *p; p++)
            if (*p == q && *++p != q)
                return p;
        return p;
    }
    for (; *p; p++)
    {
        if (*p == '\'' || *p == '"')
            p = skip_quoted_or_parens(p) - 1;
        else if (*p == '(')
            depth++;
        else if (*p == ')' && --depth == 0)
            return p + 1;
    }
    return p;
}

/* The start of the WITH entry whose body opens at `open`: past the last
 * top-level comma before it, or past the WITH keyword. */
static const char *
with_entry_start(const char *sql, const char *open)
{
    const char *p = sql, *start = NULL;

    while (p < open)
    {
        if (*p == '\'' || *p == '"' || *p == '(')
        {
            p = skip_quoted_or_parens(p);
            continue;
        }
        if (*p == ',')
            start = p + 1;
        p++;
    }
    if (start == NULL)
        start = sql + (strncmp(sql, "WITH RECURSIVE ", 15) == 0 ? 15 : 5);
    while (*start == ' ')
        start++;
    return start;
}

/*
 * Split a rewritten statement into the entries of its leading WITH clause
 * (NULL without one) and the statement behind them. The clause is the
 * rewrite's own, so each entry is `name AS [MATERIALIZED] (…)` with no SEARCH
 * or CYCLE clause: it ends at its closing parenthesis, and the statement
 * starts where no further entry follows.
 */
static const char *
split_leading_with(const char *sql, const char **entries)
{
    const char *p, *start;
    size_t      len;

    *entries = NULL;
    if (strncmp(sql, "WITH ", 5) != 0)
        return sql;
    start = sql + 5;
    for (p = start;;)
    {
        while (*p && *p != '(')
            p++;
        p = skip_quoted_or_parens(p);
        while (*p == ' ')
            p++;
        if (*p != ',')
            break;
        p++;
    }
    len = (size_t) (p - start);
    while (len > 0 && start[len - 1] == ' ')
        len--;
    *entries = pnstrdup(start, len);
    return p;
}

/*
 * Splice the rewrite of a write nested in a WITH entry into the statement that
 * holds it. The rewrite is a DML statement, possibly behind WITH entries of
 * its own (the source and the cold sink of a tiered INSERT, the cold half of a
 * dual-tier write): the DML becomes the entry's new body, and those entries
 * are lifted into the outer WITH list just before it, after everything the
 * write may read, where a data-modifying entry is legal. The entry is found in
 * the deparsed statement at its verb on the view, the only one (a second write
 * to a tiered view is refused before this), and its body is the parenthesised
 * run around it.
 */
static char *
cf_splice_nested_dml(Query *query, Query *inner, RangeTblEntry *rte,
                     const char *rewritten)
{
    const char     *outer_sql = deparse_flat(query);
    const char     *vname = get_rel_name(rte->relid);
    char            search_unqual[256], search_qual[256];
    const char     *verb, *matched, *at, *open, *close, *start, *lifted, *body;
    StringInfoData  buf;

    body = split_leading_with(rewritten, &lifted);
    dml_search_strings(inner, search_unqual, search_qual, sizeof(search_unqual), &verb);
    at = find_dml_prefix(outer_sql, search_unqual, search_qual, vname, &matched);
    for (open = at; open > outer_sql && open[-1] == ' '; open--)
        ;
    if (open == outer_sql || *--open != '(')
        elog(ERROR, "coldfront: cannot locate the WITH entry of the nested write in: %s",
             outer_sql);
    close = skip_quoted_or_parens(open);      /* past the entry's ')' */
    start = with_entry_start(outer_sql, open);

    initStringInfo(&buf);
    appendBinaryStringInfo(&buf, outer_sql, start - outer_sql);
    if (lifted != NULL)
        appendStringInfo(&buf, "%s, ", lifted);
    appendBinaryStringInfo(&buf, start, open + 1 - start);   /* <name> AS ( */
    appendStringInfoString(&buf, body);
    appendStringInfoString(&buf, close - 1);                 /* ) and the rest */
    return buf.data;
}

/*
 * Reject a multi-reference UPDATE/DELETE/MERGE on a tiered view. The
 * deparse-and-swap rewrite substitutes only the leading result-relation
 * reference. A second reference to the SAME tiered view, a self-join (UPDATE …
 * FROM v), DELETE … USING v, a MERGE source, or a sub-select (… WHERE id IN
 * (SELECT … FROM v)), would be copied through verbatim and then fail
 * confusingly (PG cannot run the view's DuckDB read; DuckDB does not know it).
 * Reject it cleanly here; a structural multi-reference rewrite is out of scope.
 * (INSERT … SELECT routing is handled separately by emit_tiered_insert.)
 */
static void
cf_reject_multi_reference(Query *query, RangeTblEntry *rte)
{
    if ((query->commandType == CMD_UPDATE || query->commandType == CMD_DELETE ||
         query->commandType == CMD_MERGE) &&
        count_tiered_view_refs(query, rte->relid) > 1)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("%s on tiered view \"%s\" cannot reference it more than once",
                        query->commandType == CMD_UPDATE ? "UPDATE" :
                        query->commandType == CMD_DELETE ? "DELETE" : "MERGE",
                        get_rel_name(rte->relid)),
                 errhint("Self-joins, USING, a MERGE source and sub-selects over the same "
                         "tiered view are not supported; reference it once.")));
}

/*
 * The SET assignment for the partition column, if this UPDATE assigns it; else
 * NULL. Changing the partition column can move the row across the hot/cold
 * cutoff, so it gets special handling: a cross-tier MOVE when mixed writes are
 * on, a clean rejection when off (the in-place rewrite would otherwise strand
 * the row in its old tier where the view's tier predicate hides it). The
 * targetList here is post-parse-analyze, so it holds exactly the
 * SET-assigned columns (plus resjunk entries we skip) — not the full row.
 */
static TargetEntry *
partcol_set_target(Query *query, RangeTblEntry *rte, TieredViewInfo *info)
{
    AttrNumber  partcol_attno;
    ListCell   *lc;

    if (query->commandType != CMD_UPDATE || info->partition_col == NULL)
        return NULL;

    partcol_attno = get_attnum(rte->relid, info->partition_col);
    if (partcol_attno == InvalidAttrNumber)
        return NULL;

    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);
        if (!tle->resjunk && tle->resno == partcol_attno)
            return tle;
    }
    return NULL;
}

/*
 * Strict-mode (coldfront.allow_mixed_writes = off) rejection of a partition-
 * column SET: with mixed writes off there is no atomic cross-tier relocation to
 * fall back on, so reject rather than strand the row. Message/hint are stable
 * (golden: update_partition_key_blocked).
 */
static void
reject_partition_col_update(TieredViewInfo *info, const char *vname)
{
    ereport(ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("UPDATE of partition column \"%s\" on tiered view \"%s\" is not supported",
                    info->partition_col, vname),
             errhint("Changing \"%s\" can move the row across the hot/cold "
                     "boundary; that relocation is not yet supported. To "
                     "change \"%s\", delete the row and re-insert it with "
                     "the new value.",
                     info->partition_col, info->partition_col)));
}

/*
 * Walker context: true if any Var references a column OTHER than the partition
 * column (or a different range-table entry). The cross-tier move re-evaluates
 * the new partition-column expression e in three places (the PG hot legs and the
 * DuckDB cold legs) over different column spellings, so v1 supports only an e
 * that references the partition column or constants — anything else is rejected
 * cleanly upstream rather than mis-evaluated.
 */
typedef struct { Index result_rel; AttrNumber partcol_attno; bool other; } VarRefCtx;

static bool
expr_refs_other_col_walker(Node *node, void *ctx)
{
    VarRefCtx *c = (VarRefCtx *) ctx;
    if (node == NULL)
        return false;
    if (IsA(node, Var))
    {
        Var *v = (Var *) node;
        if ((Index) v->varno != c->result_rel || v->varattno != c->partcol_attno)
            c->other = true;
        return false;
    }
    return expression_tree_walker(node, expr_refs_other_col_walker, ctx);
}


/*
 * Reject the cross-tier-move shapes v1 does not support, each with a stable
 * message: cold RETURNING; a WHERE referencing other tables or sub-queries (the
 * cold tier is read through DuckDB, which can't correlate with Postgres tables);
 * bound params (e and WHERE are deparsed to literal text at parse-analyze, where
 * a param's value is not yet known); a multi-column SET; a VOLATILE e; an e that
 * references other columns; a bare-NULL e. (in_plpgsql is rejected by the caller:
 * the move's cold read can't run nested inside a function/DO.)
 */
static void
cf_reject_unsupported_move(Query *query, RangeTblEntry *rte,
                           TieredViewInfo *info, ColdParamSet *ps,
                           TargetEntry *pc_tle, const char *vname)
{
    Node     *e = (Node *) pc_tle->expr;
    ListCell *lc;

    reject_cold_returning(query, vname);

    /* The move replays the deparsed WHERE against one relation at a time (the hot
     * heap, and the catalog read for the cold tier), so it cannot reference other
     * tables: the cold tier is read through DuckDB, which can't correlate with
     * Postgres tables. Reject UPDATE ... FROM and sub-query predicates with a clear
     * message rather than the opaque "missing FROM-clause entry" they fail with. */
    if (query->hasSubLinks || list_length(query->rtable) > 1)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("a cross-tier move on tiered view \"%s\" cannot reference other tables or sub-queries", vname),
                 errhint("The cold tier is read through DuckDB, which can't join other Postgres tables; the WHERE may use only \"%s\"'s own columns (no UPDATE ... FROM, no sub-select).", vname)));

    if (ps->maxid > 0)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("a cross-tier move on tiered view \"%s\" cannot use bound parameters", vname),
                 errhint("Run the UPDATE with literal values for the partition column and WHERE clause.")));

    /* Only the partition column may be SET in a move: a second SET target
     * would have to be re-projected across all four legs. */
    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);
        if (!tle->resjunk && tle != pc_tle)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("a cross-tier move on tiered view \"%s\" cannot also set other columns", vname),
                     errhint("Move the row by setting only \"%s\"; update other columns in a separate statement.",
                             info->partition_col)));
    }

    /* Reject VOLATILE — never STABLE. clock_timestamp()/random()/nextval() evaluate
     * differently per call, so they could classify a row into different tiers
     * across the move's legs. STABLE expressions (e.g. timestamptz + interval,
     * which depends on the session timezone) evaluate consistently within this
     * one transaction, so the legs agree; they are the intended row-dependent
     * move (SET ts = ts + interval '1 month'). */
    if (contain_volatile_functions(e))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("the new value for partition column \"%s\" on tiered view \"%s\" must not be VOLATILE",
                        info->partition_col, vname),
                 errhint("clock_timestamp()/random()/nextval() can classify a row into different tiers across the move's legs; use a constant or a stable expression over \"%s\" only.",
                         info->partition_col)));

    {
        VarRefCtx vc = { (Index) query->resultRelation,
                         get_attnum(rte->relid, info->partition_col), false };
        if (expr_refs_other_col_walker(e, &vc) || vc.other)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("the new value for partition column \"%s\" on tiered view \"%s\" may reference only \"%s\"",
                            info->partition_col, vname, info->partition_col),
                     errhint("A cross-tier move supports a constant or an expression over \"%s\" (e.g. \"%s + interval '1 month'\").",
                             info->partition_col, info->partition_col)));
    }

    /* A NULL new value matches no tier and the NOT-NULL partition column would
     * error mid-move; reject when the expression is provably NULL (a bare NULL
     * constant). Non-constant NULLs are caught at execution by the column's
     * NOT NULL constraint on the hot legs. */
    if (IsA(e, Const) && ((Const *) e)->constisnull)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("the new value for partition column \"%s\" on tiered view \"%s\" cannot be NULL",
                        info->partition_col, vname)));
}

/*
 * Permissive-mode (coldfront.allow_mixed_writes = on) cross-tier move path.
 * Validates the move (cf_reject_unsupported_move), then deparses the user WHERE
 * and the new partition-column expression e over the VIEW's column names and
 * returns the rewrite "SELECT coldfront._cross_tier_move(schema, view, where, e)".
 * That function does the relocation: it arms its own GUCs, attaches 'ice', and
 * routes matched rows into the four tier cases. The work lives there (not in a
 * hook-installed Query) because cold→hot rows are read through DuckDB, which
 * pg_duckdb runs in DuckDB only as a standalone read — not as the modifying Query
 * the hook installs — and only inside a function with the unsafe-execution GUC.
 */
static char *
cf_emit_cross_tier_move_path(Query *query, RangeTblEntry *rte,
                             TieredViewInfo *info, ColdParamSet *ps,
                             TargetEntry *pc_tle, const char *vname)
{
    List          *dpcontext;
    char          *e_text, *where_text;
    const char    *ns;
    StringInfoData buf;

    cf_reject_unsupported_move(query, rte, info, ps, pc_tle, vname);

    /* cf_reject_multi_reference guarantees a single base reference, so the result
     * relation is the sole rangetable entry (varno 1) and the deparse context maps
     * the view's columns by it. Defensive: fall back to the strict rejection on an
     * unexpected shape rather than emit a wrong rewrite. */
    if (query->resultRelation != 1)
        reject_partition_col_update(info, vname);

    dpcontext  = deparse_context_for(get_rel_name(rte->relid), rte->relid);
    e_text     = deparse_expression((Node *) pc_tle->expr, dpcontext, false, false);
    where_text = (query->jointree && query->jointree->quals)
                 ? deparse_expression((Node *) query->jointree->quals, dpcontext, false, false)
                 : pstrdup("true");
    ns = get_namespace_name(get_rel_namespace(rte->relid));

    initStringInfo(&buf);
    appendStringInfo(&buf,
        "SELECT coldfront._cross_tier_move(%s, %s, %s, %s)",
        quote_literal_cstr(ns), quote_literal_cstr(vname),
        quote_literal_cstr(where_text), quote_literal_cstr(e_text));
    return buf.data;
}

/* ---------- MERGE ------------------------------------------------------- */

/* True when an UPDATE action of the MERGE sets the partition column. */
static bool
merge_sets_partcol(Query *query, AttrNumber partcol_attno)
{
    ListCell *lc, *lc2;

    foreach(lc, query->mergeActionList)
    {
        MergeAction *action = lfirst_node(MergeAction, lc);

        if (action->commandType != CMD_UPDATE)
            continue;
        foreach(lc2, action->targetList)
        {
            TargetEntry *tle = (TargetEntry *) lfirst(lc2);

            if (!tle->resjunk && tle->resno == partcol_attno)
                return true;
        }
    }
    return false;
}

/*
 * A cold MERGE's INSERT action builds its row in DuckDB, which can neither draw
 * the next identity value nor evaluate a PostgreSQL DEFAULT, so every hot-table
 * column that has one must be given a value. An identity column under
 * OVERRIDING USER VALUE takes the next value, so it counts as left out.
 */
static void
reject_cold_merge_insert_omissions(Query *query, TieredViewInfo *info,
                                   const char *vname)
{
    HotColumns hc;
    ListCell  *lc;
    int        i;

    load_hot_columns(info->hot_table, &hc);
    foreach(lc, query->mergeActionList)
    {
        MergeAction *action = lfirst_node(MergeAction, lc);
        List        *targeted = NIL;
        ListCell    *lc2;

        if (action->commandType != CMD_INSERT)
            continue;
        foreach(lc2, action->targetList)
            targeted = lappend(targeted, ((TargetEntry *) lfirst(lc2))->resname);
        for (i = 0; i < hc.n; i++)
        {
            bool given = name_in_list(targeted, hc.name[i]) &&
                         !(hc.seq[i] != NULL && action->override == OVERRIDING_USER_VALUE);

            if ((hc.seq[i] != NULL || hc.dflt[i] != NULL) && !given)
                ereport(ERROR,
                        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                         errmsg("a MERGE into the cold tier of tiered view \"%s\" must give a value for column \"%s\"",
                                vname, hc.name[i]),
                         errdetail("The row is built in DuckDB, which cannot draw the column's next identity value or evaluate its default."),
                         errhint("List \"%s\" in the INSERT action, with OVERRIDING SYSTEM VALUE for a GENERATED ALWAYS identity column.",
                                 hc.name[i])));
        }
    }
}

#if PG_VERSION_NUM >= 170000
/*
 * A NOT MATCHED BY SOURCE action acts on the target rows no source row matches.
 * The statement runs on one tier, and the other tier's rows, which the ON
 * condition's bound keeps from matching, would be acted on by the statement
 * PostgreSQL would run on the whole view, so the action's own condition must
 * bound the same tier.
 */
static void
reject_merge_by_source_other_tier(Query *query, TieredViewInfo *info,
                                  AttrNumber partcol_attno, TierClass tier,
                                  const char *vname, const char *cutoff_lit)
{
    ListCell *lc;

    foreach(lc, query->mergeActionList)
    {
        MergeAction *action = lfirst_node(MergeAction, lc);

        if (action->matchKind == MERGE_WHEN_NOT_MATCHED_BY_SOURCE &&
            classify_qual(action->qual, (Index) query->resultRelation,
                          partcol_attno, info->cutoff) != tier)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("a WHEN NOT MATCHED BY SOURCE action on tiered view \"%s\" must bound \"%s\" to the %s tier, as the ON condition does",
                            vname, info->partition_col, tier == TIER_HOT ? "hot" : "cold"),
                     errdetail("The statement runs on that tier alone, and no source row matches the other tier's rows either."),
                     errhint("Add \"AND %s %s %s\" to the action's condition.",
                             info->partition_col, tier == TIER_HOT ? ">=" : "<", cutoff_lit)));
    }
}
#endif

/* The next `kw` in `p` outside literals, quoted identifiers and parentheses. */
static const char *
find_toplevel_keyword(const char *p, const char *kw)
{
    size_t len = strlen(kw); /* nosemgrep */

    for (; *p; p++)
    {
        if (*p == '\'' || *p == '"' || *p == '(')
            p = skip_quoted_or_parens(p) - 1;
        else if (strncmp(p, kw, len) == 0) /* nosemgrep */
            return p;
    }
    return NULL;
}

/* The end of the list element starting at `p`: its top-level comma, or the
 * parenthesis that closes the list. */
static const char *
list_element_end(const char *p)
{
    for (; *p; p++)
    {
        if (*p == '\'' || *p == '"' || *p == '(')
            p = skip_quoted_or_parens(p) - 1;
        else if (*p == ',' || *p == ')')
            return p;
    }
    return p;
}

/*
 * The INSERT actions of a deparsed MERGE, in the statement's order. With a
 * cutoff the partition-column value gets the tier's per-row guard: the hot
 * statement runs in PostgreSQL, where coldfront._hot_only refuses a row below
 * the cutoff; the cold one runs in DuckDB, where a CASE on error() refuses a
 * row at or after it. A cold statement also loses each action's OVERRIDING
 * clause, which DuckDB does not know. "THEN INSERT (" marks an action: the
 * deparser spells keywords in upper case and quotes an identifier that is one,
 * so no CASE branch reads that way.
 */
static char *
rewrite_merge_inserts(const char *sql, Query *query, TieredViewInfo *info,
                      bool cold)
{
    RangeTblEntry *rte = rt_fetch(query->resultRelation, query->rtable);
    const char    *vname = get_rel_name(rte->relid);
    AttrNumber     partcol_attno = info->has_cutoff ?
                       get_attnum(rte->relid, info->partition_col) : InvalidAttrNumber;
    const char    *p = sql;
    StringInfoData buf;
    ListCell      *lc;

    initStringInfo(&buf);
    foreach(lc, query->mergeActionList)
    {
        MergeAction *action = lfirst_node(MergeAction, lc);
        const char  *at, *q, *vals, *e_end;
        char        *e, *cutoff_lit;
        int          k = -1, i = 0;
        ListCell    *lc2;

        if (action->commandType != CMD_INSERT || action->targetList == NIL)
            continue;
        foreach(lc2, action->targetList)
        {
            if (((TargetEntry *) lfirst(lc2))->resno == partcol_attno)
                k = i;
            i++;
        }
        at = find_toplevel_keyword(p, "THEN INSERT (");
        if (at == NULL)
            elog(ERROR, "coldfront: cannot locate an INSERT action in deparsed MERGE: %s", sql);
        q = skip_quoted_or_parens(at + strlen("THEN INSERT ")); /* nosemgrep */
        appendBinaryStringInfo(&buf, p, q - p);                  /* up to the column list's ) */
        p = skip_override_clause(q, action->override);          /* at "VALUES (" */
        if (cold)
            appendStringInfoChar(&buf, ' ');
        else
            appendBinaryStringInfo(&buf, q, p - q);
        if (k < 0)
            continue;
        vals = p + strlen("VALUES ("); /* nosemgrep */
        for (i = 0; i < k; i++)
            vals = list_element_end(vals) + 1;
        while (*vals == ' ')
            vals++;
        e_end = list_element_end(vals);
        e = pnstrdup(vals, e_end - vals);
        cutoff_lit = format_timestamptz_literal(info->cutoff);
        appendBinaryStringInfo(&buf, p, vals - p);
        if (cold)
            appendStringInfo(&buf, "CASE WHEN %s >= %s THEN error(%s || CAST(%s AS VARCHAR) || %s) ELSE %s END",
                             e, cutoff_lit,
                             quote_literal_cstr(psprintf("a MERGE into the cold tier of tiered view \"%s\" cannot insert a row with \"%s\" = ",
                                                         vname, info->partition_col)),
                             e,
                             quote_literal_cstr(", which is at or after the cutoff; insert it with INSERT, which splits rows by the cutoff"),
                             e);
        else
            appendStringInfo(&buf, "coldfront._hot_only(%s, %s, %s, %s)",
                             e, cutoff_lit, quote_literal_cstr(vname),
                             quote_literal_cstr(info->partition_col));
        p = e_end;
    }
    appendStringInfoString(&buf, p);
    return buf.data;
}

/*
 * A MERGE runs on the tier its ON condition bounds the partition column to: a
 * hot one is the statement retargeted to the hot table, a cold one runs in
 * DuckDB against the Iceberg table, and either sees its tier's rows alone. A
 * source row that matches a row of the other tier would look unmatched, so a
 * MERGE that bounds neither tier is refused, and the INSERT actions guard the
 * inserted partition value per row (rewrite_merge_inserts). A MERGE that sets
 * the partition column is refused: a cross-tier move replays a single-relation
 * WHERE per tier, and a MERGE's matched set is a join with its source.
 */
static char *
cf_emit_merge_path(Query *query, RangeTblEntry *rte, TieredViewInfo *info,
                   ColdParamSet *ps, bool in_plpgsql, const char *vname)
{
    TierClass tier;

    if (info->has_vector)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("MERGE INTO \"%s\" is not supported on a table with a clustered vector column", vname),
                 errhint("Use INSERT, UPDATE and DELETE, which assign each written row its cluster.")));

    tier = classify_tier(query, info);
    if (info->has_cutoff)
    {
        AttrNumber partcol_attno = get_attnum(rte->relid, info->partition_col);
        char      *cutoff_lit = format_timestamptz_literal(info->cutoff);

        if (merge_sets_partcol(query, partcol_attno))
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("a MERGE that sets partition column \"%s\" on tiered view \"%s\" is not supported",
                            info->partition_col, vname),
                     errhint("Run the change of \"%s\" as an UPDATE; with coldfront.allow_mixed_writes on it moves the rows across the cutoff.",
                             info->partition_col)));
        if (tier == TIER_AMBIGUOUS)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("MERGE INTO tiered view \"%s\" must bound \"%s\" to one tier in its ON condition",
                            vname, info->partition_col),
                     errdetail("Each tier runs in its own engine and sees its own rows alone, so a source row matching a row of the other tier would look unmatched."),
                     errhint("Add \"AND %s >= %s\" for the hot tier or \"AND %s < %s\" for the cold tier to ON, or split the statement by tier.",
                             info->partition_col, cutoff_lit, info->partition_col, cutoff_lit)));
#if PG_VERSION_NUM >= 170000
        reject_merge_by_source_other_tier(query, info, partcol_attno, tier, vname, cutoff_lit);
#endif
        if (tier == TIER_COLD)
            reject_cold_merge_insert_omissions(query, info, vname);
    }
    if (tier == TIER_HOT)
        return emit_hot(query, info);
    return cf_emit_cold_path(query, info, ps, in_plpgsql, vname);
}

/*
 * Reject a multi-reference UPDATE/DELETE/MERGE on a tiered view, then pick the
 * emit path (MERGE by its ON condition, tiered-INSERT split, hot, cold, or
 * dual) and return the rewritten SQL. Returns NULL on the unreachable default
 * tier (caller treats as a no-op).
 */
static char *
cf_dispatch_emit(Query *query, RangeTblEntry *rte, TieredViewInfo *info,
                 ColdParamSet *ps, bool in_plpgsql, const char *vname)
{
    TierClass    tier;
    TargetEntry *pc_tle;

    cf_reject_multi_reference(query, rte);

    if (query->commandType == CMD_MERGE)
        return cf_emit_merge_path(query, rte, info, ps, in_plpgsql, vname);

    /* A partition-column SET can move the row across the hot/cold cutoff — but
     * only once something is archived. With a cutoff: mixed writes off → reject;
     * on → cross-tier move: rewrite to
     * SELECT coldfront._cross_tier_move(...). Without a cutoff every row is hot, so
     * a partition-column UPDATE is a plain hot UPDATE — fall through to the normal
     * classification (emit_hot). Also falls through when the partition column is not
     * in the SET targetlist. */
    pc_tle = partcol_set_target(query, rte, info);
    if (pc_tle != NULL && info->has_cutoff)
    {
        if (!coldfront_allow_mixed_writes)
            reject_partition_col_update(info, vname);
        /* The rewrite is a row-returning SELECT (the function returns void): inside
         * a plpgsql function or DO block a bare SELECT has no destination, and as
         * a WITH entry's body it would not run. The top-level form is the path. */
        if (in_plpgsql)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("a cross-tier move of partition column \"%s\" on tiered view \"%s\" is not supported inside a function, a DO block or a WITH entry",
                            info->partition_col, vname),
                     errhint("Run the partition-column UPDATE as a top-level statement.")));
        return cf_emit_cross_tier_move_path(query, rte, info, ps, pc_tle, vname);
    }

    /* Tiered-view INSERT: bulk split-by-watermark via emit_tiered_insert.
     * Iceberg-only INSERT falls through to the unconditional cold path
     * (classify_tier short-circuits to TIER_COLD for iceberg-only). */
    if (query->commandType == CMD_INSERT && !info->is_iceberg_only)
        return cf_emit_tiered_insert_path(query, rte->relid, info, ps, in_plpgsql, vname);

    tier = classify_tier(query, info);

    if (tier == TIER_HOT)
        return emit_hot(query, info);
    if (tier == TIER_COLD)
        return cf_emit_cold_path(query, info, ps, in_plpgsql, vname);
    if (tier == TIER_AMBIGUOUS)
        return cf_emit_dual_path(query, info, ps, in_plpgsql, vname);
    return NULL;        /* unreachable */
}

/* ---------- DuckDB spill directory -------------------------------------- */

/*
 * DuckDB names every spill file from a per-instance counter that starts at zero
 * (duckdb_temp_storage_<class>-<index>.tmp), and an instance being torn down
 * deletes each duckdb_temp_* file in its temp directory. Backends sharing one
 * duckdb.temporary_directory thus write the same paths and delete each other's
 * spills, so a backend takes a subdirectory of the configured path named after
 * its own PID. pg_duckdb reads the setting when it builds the instance and
 * refuses a later change, hence the parse-analyze hook: it sees the session's
 * first statement, ahead of any DuckDB planning.
 */
#define CF_TEMP_DIR_GUC "duckdb.temporary_directory"

/*
 * Unlink the spill files in one departed backend's directory, counting them and
 * the bytes they held. True when nothing is left in it. Any other entry belongs
 * to whoever put it there and keeps the directory.
 */
static bool
cf_drain_temp_dir(const char *path, int *nfiles, int64 *nbytes)
{
    DIR           *dir = AllocateDir(path);
    struct dirent *de;
    bool           drained = true;

    if (dir == NULL)
        return false;

    while ((de = ReadDir(dir, path)) != NULL)
    {
        char       *file;
        struct stat st;

        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0)
            continue;
        if (strncmp(de->d_name, "duckdb_temp_", sizeof("duckdb_temp_") - 1) != 0)
        {
            drained = false;
            continue;
        }
        file = psprintf("%s/%s", path, de->d_name);
        if (stat(file, &st) == 0)
            *nbytes += (int64) st.st_size;
        if (unlink(file) != 0)
            drained = false;
        else
            (*nfiles)++;
        pfree(file);
    }
    FreeDir(dir);
    return drained;
}

/*
 * Reclaim the subdirectories of `base` named for a PID that no backend holds.
 * A directory whose PID is live belongs to a session that is still spilling.
 * Reclaiming a hard-killed backend's spills is the one case that touches real
 * data, so it is reported with what it freed and what it cost.
 */
static void
cf_reclaim_temp_dirs(const char *base)
{
    DIR           *dir    = AllocateDir(base);
    TimestampTz    start  = GetCurrentTimestamp();
    int            ndirs  = 0;
    int            nfiles = 0;
    int64          nbytes = 0;
    struct dirent *de;

    /* Nothing has spilled under this path yet. */
    if (dir == NULL)
        return;

    while ((de = ReadDir(dir, base)) != NULL)
    {
        char *end;
        long  pid = strtol(de->d_name, &end, 10);
        char *path;

        if (*end != '\0' || pid <= 0 || pid == (long) MyProcPid ||
            BackendPidGetProc((int) pid) != NULL)
            continue;

        path = psprintf("%s/%s", base, de->d_name);
        if (cf_drain_temp_dir(path, &nfiles, &nbytes) && rmdir(path) == 0)
            ndirs++;
        pfree(path);
    }
    FreeDir(dir);

    if (nfiles > 0 || ndirs > 0)
        ereport(LOG,
                (errmsg("coldfront: reclaimed %d DuckDB spill %s (%d file(s), "
                        INT64_FORMAT " bytes) under \"%s\" in %ld ms",
                        ndirs, ndirs == 1 ? "directory" : "directories",
                        nfiles, nbytes, base,
                        TimestampDifferenceMilliseconds(start,
                                                        GetCurrentTimestamp()))));
}

/*
 * Give this backend's DuckDB spills a directory of its own, reclaiming what
 * departed backends left under the configured path on the way. Runs once, on
 * the session's first statement, where pg_duckdb has yet to build its instance
 * and still reads this setting.
 *
 * PGC_S_OVERRIDE keeps the value off the transactional GUC stack, so it holds
 * for the session even if the transaction that set it rolls back. A session
 * that sets the path itself outranks that source and keeps what it asked for.
 * DEBUG3 leaves pg_duckdb's refusal (its instance already built) a log detail
 * rather than an error on an unrelated statement.
 */
static void
cf_own_duckdb_temp_dir(void)
{
    static bool  owned = false;
    const char  *base;
    char         pid[16];

    /* A parallel worker runs on the leader's settings, this one included, and a
     * GUC cannot be set inside a parallel operation at all. */
    if (owned || IsInParallelMode())
        return;

    base = GetConfigOption(CF_TEMP_DIR_GUC, true, false);

    /* No pg_duckdb in this backend, or DuckDB spills nowhere. */
    if (base == NULL || base[0] == '\0')
        return;

    owned = true;
    cf_reclaim_temp_dirs(base);
    snprintf(pid, sizeof(pid), "%d", MyProcPid);
    set_config_option(CF_TEMP_DIR_GUC, psprintf("%s/%s", base, pid),
                      PGC_SUSET, PGC_S_OVERRIDE, GUC_ACTION_SET, true, DEBUG3, false);
}

/* ---------- hook -------------------------------------------------------- */

/*
 * The coldfront post-parse-analyze hook: rewrite INSERT/UPDATE/DELETE on a
 * writable registered view to the hot/cold/dual emit path. Reject DML on an
 * adopted read-only view before it reaches Iceberg.
 *
 * The hook is registered cluster-wide via shared_preload_libraries, so it
 * also fires in databases/sessions where CREATE EXTENSION coldfront was
 * never run — including mid-bootstrap while ANOTHER extension is being
 * created. Notably CREATE EXTENSION spock (>= 5.0.8) reads
 * spock.channel_table_stats during its own setup; our lazy tiered-view
 * lookup below would then SPI-query a non-existent coldfront.tiered_views
 * and abort that unrelated statement ("relation coldfront.tiered_views does
 * not exist"). With no coldfront registry there is nothing tiered to
 * rewrite, so do nothing — the same guard the DDL hook already applies.
 */
static void
coldfront_post_parse_analyze(ParseState *pstate, Query *query,
                              JumbleState *jstate)
{
    TieredViewInfo   info, nested_info;
    char            *new_sql;
    RangeTblEntry   *rte, *nested_rte;
    ColdParamSet     ps;
    bool             in_plpgsql, top;
    const char      *vname;
    CommonTableExpr *cte;
    Query           *inner = query;
    int              nwrites;

    /* Chain to any previous hook first */
    if (prev_post_parse_analyze_hook)
        prev_post_parse_analyze_hook(pstate, query, jstate);

    /* Any DuckDB query can spill, tiered or not, so this precedes the registry
     * check below. */
    cf_own_duckdb_temp_dir();

    /* Re-entrancy guard */
    if (coldfront_in_rewrite)
        return;

    if (!coldfront_registry_present())
        return;

    /* The statement itself, or one write nested in its WITH, writes a tiered
     * view. The rewrite stands in for one write: a second one would stay in the
     * statement unrewritten, so it is refused. */
    top = cf_resolve_tiered_dml_target(query, &rte, &info);
    cte = cf_find_nested_dml(query, &nested_rte, &nested_info, &nwrites);
    if (!top && cte == NULL)
        return;
    if (nwrites + (top ? 1 : 0) > 1)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("a statement may write a tiered view only once"),
                 errhint("Split the writes into separate statements.")));
    if (top)
        cte = NULL;
    else
    {
        rte   = nested_rte;
        info  = nested_info;
        inner = (Query *) cte->ctequery;
    }

    vname = get_rel_name(rte->relid);

    /* A relation adopted from an existing catalog without p_writable carries the
     * read path and nothing else. One check ahead of the emit paths covers all
     * three verbs, because each of them would otherwise reach Iceberg. */
    if (!info.is_writable)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("coldfront: \"%s.%s\" is adopted read-only",
                        get_namespace_name(get_rel_namespace(rte->relid)), vname),
                 errhint("Release it with coldfront.release_iceberg_table() and adopt again with p_writable => true to arm INSERT/UPDATE/DELETE.")));

    /* The rewrite's own WITH entries are lifted beside the statement's; a
     * WITH clause on the nested write itself has no place to go. */
    if (cte != NULL && inner->cteList != NIL)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("a write to tiered view \"%s\" nested in WITH cannot have a WITH clause of its own", vname),
                 errhint("Move its entries to the statement's WITH clause.")));

    /* Bound params ($N) from a plpgsql / DO / PREPARE / extended-protocol
     * caller, collected once over the whole statement (Cause 1). in_plpgsql
     * gates the Cause-2 statement shape, a DML statement: plpgsql installs
     * p_post_columnref_hook on the ParseState (top-level, even parameterized,
     * does not), and a nested write needs that shape for the body of its WITH
     * entry. See the architecture block at the top of this file and the
     * coldfront._dummy_dml_target comment in coldfront--1.0.sql. */
    collect_cold_params(query, &ps);
    in_plpgsql = cte != NULL || pstate->p_post_columnref_hook != NULL;

    new_sql = cf_dispatch_emit(inner, rte, &info, &ps, in_plpgsql, vname);
    if (new_sql == NULL)
        return;     /* unreachable default tier */
    if (cte != NULL)
        new_sql = cf_splice_nested_dml(query, inner, rte, new_sql);

    /* Parse and analyze the rewritten SQL, guarded against re-entry */
    cf_reparse_and_replace(query, new_sql, &ps);
}

/* ---------- Bakery release deferral via XactCallback ------------------ */

/*
 * Pending release tickets accumulate in this session-local list during the
 * outer PG transaction. _exec_iceberg_with_claim plpgsql calls
 * coldfront._enqueue_release(ticket) right after queuing the iceberg DML
 * (duckdb.raw_query); the actual DELETE-from-claims is deferred to the
 * XactCallback below.
 *
 * Why deferred: pg_duckdb commits the iceberg snapshot at outer-tx-commit
 * time (via its own XactCallback). Releasing the claim before that commit
 * lands creates a window where the next bakery winner sees no claim and
 * races into Lakekeeper alongside us, and one of the two commits fails with
 * HTTP 409 and aborts its transaction. Conversely,
 * releasing inside the same outer tx (so it's atomic with iceberg) makes
 * the release invisible to peers until commit, which is correct on COMMIT
 * but leaves a stale claim on ROLLBACK.
 *
 * pg_duckdb commits the Iceberg transaction at XACT_EVENT_PRE_COMMIT and this
 * callback DELETEs the claim at XACT_EVENT_COMMIT, so on COMMIT the iceberg
 * snapshot is durably committed before the claim goes. On ABORT this callback
 * runs before pg_duckdb discards its staged Iceberg work (PostgreSQL calls the
 * most recently registered callback first, and coldfront registers after
 * pg_duckdb); that order is harmless, since duckdb-iceberg's rollback deletes
 * staged data files and sends nothing to the catalog, and the claim row
 * (committed on its own over the loopback) still has to go so the next writer
 * does not block.
 *
 * Allocated in TopMemoryContext so it survives across PG xacts within one
 * backend session.
 *
 * The async ordering's appends queue their CLAIM the same way
 * (coldfront._enqueue_claim): the statement stages its parquet and the
 * callback takes the queued claims at XACT_EVENT_PRE_COMMIT, through
 * coldfront._take_iceberg_claim over SPI, while the transaction is still open
 * and before pg_duckdb's own PRE_COMMIT callback commits the Iceberg
 * transaction (the same registration order as above). So the serializer is
 * held for the commit POST alone, and an open transaction with staged cold
 * writes blocks no other writer. ABORT drops the queue: nothing was committed
 * and nothing was claimed.
 */
static List *coldfront_pending_releases = NIL;
static List *coldfront_pending_claims   = NIL;    /* of char *: Iceberg refs */

/* The node's loopback: one libpq connection per backend, opened lazily from the
 * GUC coldfront.loopback_dsn and kept for the backend's lifetime. Every bakery
 * statement that must commit on its own runs here: the claim, the apply
 * trigger's acks and reaps, the waiter's poke, and the release. Only C holds it,
 * and SQL reaches it only through coldfront._loopback(), which PUBLIC cannot
 * execute. */
static PGconn *coldfront_loopback_conn = NULL;

/* cf_loopback_get_conn returns the loopback, reconnecting when it is absent or
 * has failed. A new connection gets a 30 s statement_timeout, the backstop for
 * a statement stuck on a lock, and search_path = pg_catalog, so the statements
 * and trigger functions it runs as the loopback's user resolve unqualified
 * names in pg_catalog only. A connection that cannot be opened is reported at
 * elevel, and NULL comes back when elevel is below ERROR. */
static PGconn *
cf_loopback_get_conn(int elevel)
{
    const char       *connstr;
    PGresult         *res;
    PQconninfoOption *opts, *opt;
    char             *parse_err = NULL;

    if (coldfront_loopback_conn != NULL &&
        PQstatus(coldfront_loopback_conn) == CONNECTION_OK)
        return coldfront_loopback_conn;

    if (coldfront_loopback_conn != NULL)
    {
        PQfinish(coldfront_loopback_conn);
        coldfront_loopback_conn = NULL;
    }

    connstr = GetConfigOption("coldfront.loopback_dsn", true, false);
    if (connstr == NULL || connstr[0] == '\0')
    {
        ereport(elevel,
                (errmsg("coldfront: coldfront.loopback_dsn is unset, so the bakery has no loopback connection")));
        return NULL;
    }

    /* Every onboarded role can read the DSN (_bakery_armed reads it), so it must
     * never need a password: a unix socket under peer or trust auth, never TCP. */
    opts = PQconninfoParse(connstr, &parse_err);
    if (opts == NULL)
    {
        char *msg = pstrdup(parse_err != NULL ? parse_err : "");

        PQfreemem(parse_err);
        ereport(elevel,
                (errmsg("coldfront: coldfront.loopback_dsn is not a valid connection string: %s", msg)));
        return NULL;
    }
    for (opt = opts; opt->keyword != NULL; opt++)
    {
        if (opt->val == NULL || opt->val[0] == '\0')
            continue;
        if ((strcmp(opt->keyword, "host") == 0 && opt->val[0] != '/') ||
            strcmp(opt->keyword, "hostaddr") == 0)
        {
            char *kw = pstrdup(opt->keyword);
            char *val = pstrdup(opt->val);

            PQconninfoFree(opts);
            ereport(elevel,
                    (errmsg("coldfront: coldfront.loopback_dsn must name a unix socket (host=/directory), not %s=%s",
                            kw, val)));
            return NULL;
        }
    }
    PQconninfoFree(opts);

    coldfront_loopback_conn = PQconnectdb(connstr);
    if (PQstatus(coldfront_loopback_conn) != CONNECTION_OK)
    {
        char   *msg = pstrdup(PQerrorMessage(coldfront_loopback_conn));

        PQfinish(coldfront_loopback_conn);
        coldfront_loopback_conn = NULL;
        ereport(elevel,
                (errmsg("coldfront: cannot open the loopback connection: %s", msg)));
        return NULL;
    }
    res = PQexec(coldfront_loopback_conn,
                 "SET statement_timeout = '30s'; SET search_path = pg_catalog");
    if (res != NULL)
        PQclear(res);
    return coldfront_loopback_conn;
}

/* cf_loopback_exec runs one statement on the loopback and returns its result,
 * which the caller clears; a failure is reported at elevel, and NULL comes back
 * when elevel is below ERROR. A statement that fails because the connection
 * broke (its backend was terminated, the socket dropped) runs once more on a new
 * connection, so every statement sent here must be safe to repeat. PQexec
 * blocks this backend until the loopback answers, so a cancel or terminate
 * aimed at it takes effect only after the statement has finished: nothing the
 * loopback runs outlives the backend that asked for it. */
static PGresult *
cf_loopback_exec(const char *sql, int elevel)
{
    int         attempt;

    for (attempt = 0; attempt < 2; attempt++)
    {
        PGconn         *conn = cf_loopback_get_conn(elevel);
        PGresult       *res;
        ExecStatusType  st;
        char           *msg;

        if (conn == NULL)
            return NULL;
        res = PQexec(conn, sql);
        st = res != NULL ? PQresultStatus(res) : PGRES_FATAL_ERROR;
        if (st == PGRES_COMMAND_OK || st == PGRES_TUPLES_OK)
            return res;
        if (attempt == 0 && PQstatus(conn) != CONNECTION_OK)
        {
            if (res != NULL)
                PQclear(res);
            continue;
        }
        msg = pstrdup(res != NULL ? PQresultErrorMessage(res) : PQerrorMessage(conn));
        if (res != NULL)
            PQclear(res);
        ereport(elevel,
                (errmsg("coldfront: loopback statement failed: %s", msg),
                 errdetail("Statement: %s", sql)));
        return NULL;
    }
    return NULL;
}

/*
 * Drain the per-session pending-release queue at outer-tx end. Runs at
 * XACT_EVENT_COMMIT, after pg_duckdb's XACT_EVENT_PRE_COMMIT commit of the
 * Iceberg transaction, so the iceberg snapshot has landed before we DELETE the
 * claim; on ABORT it runs before pg_duckdb discards its staged work, which is
 * harmless (see coldfront_xact_callback).
 *
 * We use libpq directly rather than SPI because SPI inside an
 * XACT_EVENT_COMMIT / XACT_EVENT_ABORT callback would try to start a
 * fresh PG transaction while the previous one is still finalizing — that
 * triggers PANIC ("cannot abort transaction N, it was already
 * committed"). libpq runs over its own TCP/loopback session and doesn't
 * touch the calling backend's xact state.
 */
/* cf_release_one_ticket runs one queued claim release over the loopback: an
 * idempotent DELETE-by-ticket; a failure is a WARNING, not an ERROR, because
 * we are mid-finalize. Split out of coldfront_xact_callback to keep it readable. */
static void
cf_release_one_ticket(int64 ticket)
{
    char        query[160];
    PGresult   *res;

    snprintf(query, sizeof(query),
             "DELETE FROM coldfront.claims WHERE ticket = %lld",
             (long long) ticket);

    res = cf_loopback_exec(query, WARNING);
    if (res != NULL)
        PQclear(res);
}

/* Whether the statement that ends this transaction had statement_timeout
 * running, by the rule enable_statement_timeout applies and the timer's own
 * start time: PostgreSQL enables the timer in start_xact_command, so a timer
 * started inside this transaction belongs to its latest statement, and a
 * backend that commits without one (a background worker) never started it. A
 * timer still running belongs to the CALL a procedure's COMMIT runs under,
 * which keeps it. */
static bool
cf_statement_timeout_applies(void)
{
    TimestampTz started = get_timeout_start_time(STATEMENT_TIMEOUT);

    return StatementTimeout > 0
#if PG_VERSION_NUM >= 170000
        && (TransactionTimeout == 0 || StatementTimeout < TransactionTimeout)
#endif
        && !get_timeout_active(STATEMENT_TIMEOUT)
        && started > 0 && started >= GetCurrentTransactionStartTimestamp();
}

/* cf_take_pending_claims takes the claims the async ordering's appends queued,
 * at PRE_COMMIT: the transaction is still open, so SPI runs here under a
 * snapshot pushed for it (no statement is active at this point), and the ERROR
 * a timeout or a refused claim raises aborts the transaction, whose ABORT
 * event then drops the queue. PostgreSQL switches statement_timeout off before
 * commit processing (finish_xact_command), so the wait for the claim, whose
 * protocol has no timeout of its own, would be the one part of the statement
 * the setting does not bound: the timer runs again, at the statement's own
 * deadline, for the claims alone. */
static void
cf_take_pending_claims(void)
{
    ListCell *lc;
    bool      bounded;

    if (coldfront_pending_claims == NIL)
        return;
    bounded = cf_statement_timeout_applies();
    if (bounded)
        enable_timeout_at(STATEMENT_TIMEOUT, get_timeout_finish_time(STATEMENT_TIMEOUT));
    PushActiveSnapshot(GetTransactionSnapshot());
    if (SPI_connect() != SPI_OK_CONNECT)
        elog(ERROR, "coldfront: SPI_connect failed while taking the cold writes' claims");
    foreach(lc, coldfront_pending_claims)
    {
        Oid   argtypes[1] = { TEXTOID };
        Datum values[1]   = { CStringGetTextDatum((char *) lfirst(lc)) };

        if (SPI_execute_with_args("SELECT coldfront._take_iceberg_claim($1)",
                                  1, argtypes, values, NULL, false, 0) != SPI_OK_SELECT)
            elog(ERROR, "coldfront: taking the claim on %s failed", (char *) lfirst(lc));
    }
    SPI_finish();
    PopActiveSnapshot();
    if (bounded)
        disable_timeout(STATEMENT_TIMEOUT, false);
    list_free_deep(coldfront_pending_claims);
    coldfront_pending_claims = NIL;
}

static void
coldfront_xact_callback(XactEvent event, void *arg)
{
    ListCell *lc;

    if (event == XACT_EVENT_PRE_COMMIT)
    {
        cf_take_pending_claims();
        return;
    }
    if (event != XACT_EVENT_COMMIT && event != XACT_EVENT_ABORT)
        return;

    list_free_deep(coldfront_pending_claims);
    coldfront_pending_claims = NIL;

    /* The registry snapshot's context is a child of TopTransactionContext,
     * which this transaction's end frees. Drop the pointers with it, so the
     * next transaction reloads rather than matching a repeated command id. */
    cf_registry     = NIL;
    cf_registry_cid = InvalidCommandId;
    cf_registry_cxt = NULL;

    /* A lazy 'ice' ATTACH runs inside the user's transaction, so an abort rolls
     * the DuckDB ATTACH back.  Clear the once-per-session guard so the next
     * tiered-view query re-attaches.  Before the pending-release early-return
     * below (a read-only session has no releases queued). */
    if (event == XACT_EVENT_ABORT)
        coldfront_ice_attached = false;

    if (coldfront_pending_releases == NIL)
        return;

    if (cf_loopback_get_conn(WARNING) == NULL)
    {
        /* No connection: the claims stay behind as orphans, which the
         * reaper removes (see coldfront._insert_claim). Drop the queue. */
        list_free_deep(coldfront_pending_releases);
        coldfront_pending_releases = NIL;
        return;
    }

    foreach(lc, coldfront_pending_releases)
        cf_release_one_ticket(*((int64 *) lfirst(lc)));

    list_free_deep(coldfront_pending_releases);
    coldfront_pending_releases = NIL;
}

/* coldfront_loopback backs coldfront._loopback: it runs one statement on the
 * loopback, so the statement commits on its own, and returns the first column
 * of the first row as text, or NULL when there is none. It runs SQL as the
 * loopback's user, so the extension script revokes it from PUBLIC. */
PG_FUNCTION_INFO_V1(coldfront_loopback);
Datum
coldfront_loopback(PG_FUNCTION_ARGS)
{
    char       *sql = text_to_cstring(PG_GETARG_TEXT_PP(0));
    PGresult   *res = cf_loopback_exec(sql, ERROR);
    char       *val = NULL;

    if (PQresultStatus(res) == PGRES_TUPLES_OK && PQntuples(res) > 0 &&
        PQnfields(res) > 0 && !PQgetisnull(res, 0, 0))
        val = pstrdup(PQgetvalue(res, 0, 0));
    PQclear(res);
    if (val == NULL)
        PG_RETURN_NULL();
    PG_RETURN_TEXT_P(cstring_to_text(val));
}

/* Queue a bakery ticket for release after the outer transaction commits or
 * aborts; the transaction callback drains it rather than releasing it here. */
PG_FUNCTION_INFO_V1(coldfront_enqueue_release);
Datum
coldfront_enqueue_release(PG_FUNCTION_ARGS)
{
    int64           ticket = PG_GETARG_INT64(0);
    MemoryContext   old;
    int64          *p;

    old = MemoryContextSwitchTo(TopMemoryContext);
    p = palloc(sizeof(*p));
    *p = ticket;
    coldfront_pending_releases = lappend(coldfront_pending_releases, p);
    MemoryContextSwitchTo(old);

    PG_RETURN_VOID();
}

/* Queue an Iceberg table's claim for the transaction callback to take at
 * PRE_COMMIT; a table queued twice is claimed once. */
PG_FUNCTION_INFO_V1(coldfront_enqueue_claim);
Datum
coldfront_enqueue_claim(PG_FUNCTION_ARGS)
{
    char           *table = text_to_cstring(PG_GETARG_TEXT_PP(0));
    MemoryContext   old;
    ListCell       *lc;

    foreach(lc, coldfront_pending_claims)
        if (strcmp((char *) lfirst(lc), table) == 0)
            PG_RETURN_VOID();
    old = MemoryContextSwitchTo(TopMemoryContext);
    coldfront_pending_claims = lappend(coldfront_pending_claims, pstrdup(table));
    MemoryContextSwitchTo(old);

    PG_RETURN_VOID();
}

/* ---------- DDL synchronization (ProcessUtility_hook) ----------------- */

/*
 * Registry row matched for a DDL target. The DDL fires on the hot heap (or the
 * view); we match it by resolved OID, and the row carries the transparent
 * view's (schema, relname) — the registry key — for the rebuild/update helpers.
 */
typedef struct {
    char *view_schema;     /* registry key part 1: the view's namespace */
    char *view_relname;    /* registry key part 2: the view's name */
    char *hot_table;       /* quoted qualified, e.g. "public"."_events" */
    char *iceberg_table;   /* DuckDB ref, e.g. "ice"."default"."events" */
    char *partition_col;   /* the tier partition column */
} TieredDDLInfo;

/*
 * Is the coldfront registry present in THIS database? The ProcessUtility hook
 * is registered cluster-wide via shared_preload_libraries, so it fires on DDL
 * in every database and session — including ones where CREATE EXTENSION
 * coldfront was never run (a co-located Lakekeeper catalog DB, template1, a
 * database mid-bootstrap before the extension is created). In those there is
 * nothing tiered to protect, and the SPI lookups below would error with
 * "relation coldfront.tiered_views does not exist", aborting unrelated DDL.
 *
 * This is a pure catalog lookup (no SPI, no parse of a possibly-missing
 * relation): resolve the coldfront schema, then the tiered_views relation
 * within it. Cheap enough to call on every intercepted DDL.
 */
static bool
coldfront_registry_present(void)
{
    Oid nsoid;

    /* The COMMIT or ROLLBACK that ends a failed transaction block reaches the
     * hooks after the transaction's resources are released, when no catalog
     * lookup can run, and it has nothing tiered to act on. */
    if (!IsTransactionState())
        return false;
    nsoid = get_namespace_oid("coldfront", true);
    if (!OidIsValid(nsoid))
        return false;
    return OidIsValid(get_relname_relid("tiered_views", nsoid));
}

/*
 * Switch to the owner of schema coldfront, with search_path pinned to
 * pg_catalog, pg_temp: the caller's functions are out of reach, and its
 * temporary types come after pg_catalog's. The hooks read the registry this
 * way, so a role using a table or view of its own needs no access to the
 * schema, which calling a SECURITY DEFINER function there would need, and the
 * DDL hook keeps a registered view and its registry rows in step with a user's
 * DDL this way (spi_exec_ddl). Returns the GUC nest level for as_caller; an
 * error restores both with the transaction.
 */
static int
as_coldfront_owner(Oid *save_uid, int *save_sec)
{
    HeapTuple tup = SearchSysCache1(NAMESPACEOID,
                                    ObjectIdGetDatum(get_namespace_oid("coldfront", false)));
    int       nest;

    if (!HeapTupleIsValid(tup))
        elog(ERROR, "coldfront: cache lookup failed for schema coldfront");
    GetUserIdAndSecContext(save_uid, save_sec);
    SetUserIdAndSecContext(((Form_pg_namespace) GETSTRUCT(tup))->nspowner,
                           *save_sec | SECURITY_LOCAL_USERID_CHANGE);
    ReleaseSysCache(tup);
    nest = NewGUCNestLevel();
    (void) set_config_option("search_path", "pg_catalog, pg_temp", PGC_USERSET, PGC_S_SESSION,
                             GUC_ACTION_SAVE, true, 0, false);
    return nest;
}

static void
as_caller(Oid save_uid, int save_sec, int nest)
{
    AtEOXact_GUC(true, nest);
    SetUserIdAndSecContext(save_uid, save_sec);
}

/*
 * Find the registry row that `match`, an SQL condition, selects. Populates
 * *out (palloc'd in CurTransactionContext) and returns true on a match.
 *
 * Matching is done in SQL with to_regclass, which resolves a stored name
 * schema-aware (never assumes a schema), so this is correct regardless of
 * search_path or the incoming RangeVar's qualification. One query, no
 * SPI_tuptable clobbering, run as the extension's owner (as_coldfront_owner).
 */
static bool
lookup_ddl_info(const char *match, TieredDDLInfo *out)
{
    bool           found = false;
    StringInfoData sql;
    Oid            save_uid;
    int            save_sec;
    int            nest;

    if (SPI_connect() != SPI_OK_CONNECT)
        return false;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT schema_name, relname, hot_table, iceberg_table, partition_col "
        "FROM coldfront.tiered_views WHERE %s LIMIT 1", match);

    nest = as_coldfront_owner(&save_uid, &save_sec);
    if (SPI_execute(sql.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
    {
        MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);
        char   *hot, *pc;
        out->view_schema   = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 1));
        out->view_relname  = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 2));
        hot = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3);
        out->hot_table     = hot ? pstrdup(hot) : NULL;
        out->iceberg_table = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 4));
        pc = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 5);
        out->partition_col = pc ? pstrdup(pc) : NULL;
        MemoryContextSwitchTo(oldcxt);
        found = true;
    }
    as_caller(save_uid, save_sec, nest);

    pfree(sql.data);
    SPI_finish();
    return found;
}

/* The tiered registry row whose HOT table resolves to relid. */
static bool
lookup_tiered_by_hot_oid(Oid relid, TieredDDLInfo *out)
{
    return OidIsValid(relid) && lookup_ddl_info(
        psprintf("hot_table IS NOT NULL AND to_regclass(hot_table)::oid = %u", relid), out);
}

/* The decoupled registry row whose wrapper view is relid; out->hot_table is
 * NULL, which is how the DDL helpers below tell a decoupled table apart. */
static bool
lookup_iceberg_only_by_view_oid(Oid relid, TieredDDLInfo *out)
{
    return OidIsValid(relid) && lookup_ddl_info(
        psprintf("is_iceberg_only AND "
                 "to_regclass(format('%%I.%%I', schema_name, relname))::oid = %u", relid), out);
}

/*
 * Returns true if relid is a registered tiered relation, either the hot table
 * or the transparent view. The utility hook blocks DROP/TRUNCATE on either side
 * with it. When has_hot is given it reports whether the registration has a hot
 * table (false for an iceberg-only view). Single query, schema-safe via
 * to_regclass (see lookup_ddl_info), run as the extension's owner.
 */
static bool
relid_is_tiered(Oid relid, bool *has_hot)
{
    bool           found = false;
    StringInfoData sql;
    Oid            save_uid;
    int            save_sec;
    int            nest;

    if (!OidIsValid(relid))
        return false;
    if (SPI_connect() != SPI_OK_CONNECT)
        return false;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT hot_table IS NOT NULL FROM coldfront.tiered_views "
        "WHERE (schema_name = %s AND relname = %s) "
        "   OR (hot_table IS NOT NULL AND to_regclass(hot_table)::oid = %u) "
        "LIMIT 1",
        quote_literal_cstr(get_namespace_name(get_rel_namespace(relid))),
        quote_literal_cstr(get_rel_name(relid)),
        relid);
    nest = as_coldfront_owner(&save_uid, &save_sec);
    if (SPI_execute(sql.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
    {
        bool isnull;

        found = true;
        if (has_hot)
            *has_hot = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 1,
                                                  &isnull)) && !isnull;
    }
    as_caller(save_uid, save_sec, nest);
    pfree(sql.data);

    SPI_finish();
    return found;
}

#define CF_SPOCK_DDL_GUC "spock.enable_ddl_replication"

/* Run one void-returning coldfront helper via SPI, as the extension's owner
 * (as_coldfront_owner): the view and registry changes that follow a user's DDL
 * need no privilege of the user's beyond what PostgreSQL checks for the
 * statement itself. The DDL hook issues a tiered view's DDL through here, and
 * each peer's own hook issues the same DDL when it applies the user's
 * replicated statement, so unless `replicate` is set the helper runs with
 * spock.enable_ddl_replication off and only the user's statement replicates.
 * Spock reads the setting just after each statement it runs, which is inside
 * this call whatever order the hooks load in. The nest level restores the
 * setting on return, and an error restores it with the transaction. Without
 * Spock the setting does not exist and nothing is set.
 *
 * `replicate` leaves the setting as it is, so the helper's own DDL replicates.
 * A decoupled view is rebuilt that way: PostgreSQL never runs the user's ALTER
 * on the view, so no peer receives it, and each peer takes the rebuilt view as
 * DDL, as it took the view's creation. Spock records the extension's owner as
 * the role that ran that DDL, and each peer runs it as that role. */
static void
spi_exec_ddl(const char *sql, bool replicate)
{
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        Oid save_uid;
        int save_sec;
        int nest = as_coldfront_owner(&save_uid, &save_sec);

        if (!replicate && GetConfigOption(CF_SPOCK_DDL_GUC, true, false) != NULL)
            (void) set_config_option(CF_SPOCK_DDL_GUC, "off",
                                     PGC_USERSET, PGC_S_SESSION,
                                     GUC_ACTION_SAVE, true, 0, false);
        SPI_execute(sql, false, 0);
        as_caller(save_uid, save_sec, nest);
        SPI_finish();
    }
}

static void
spi_exec_void(const char *sql)
{
    spi_exec_ddl(sql, false);
}

#define CF_SPOCK_REPAIR_GUC "spock.replication_repair_mode"

/* Run one registry update via spi_exec_void with Spock's repair mode on, so the
 * rows it changes do not replicate. The registry tables replicate for the
 * archiver's writes, but each peer's own hook makes the same update when it
 * applies the user's replicated statement, and a replicated copy keyed on the
 * old name would find no row there. spock.repair_mode logs its on and off
 * markers in the transaction's change stream, so the rest of the transaction
 * replicates as usual. A session already in repair mode is left in it, and
 * without the spock extension in this database nothing is set. */
static void
spi_exec_local_rows(const char *sql)
{
    const char *repair = GetConfigOption(CF_SPOCK_REPAIR_GUC, true, false);
    bool        toggle = repair != NULL && strcmp(repair, "off") == 0 &&
                         OidIsValid(get_extension_oid("spock", true));

    if (toggle)
        spi_exec_void("SELECT spock.repair_mode(true)");
    spi_exec_void(sql);
    if (toggle)
        spi_exec_void("SELECT spock.repair_mode(false)");
}

/* Rebuild the transparent view + INSERT trigger from current catalog state.
 * Used after a column-shape change (ADD/DROP/ALTER-TYPE/RENAME COLUMN, mirrored
 * onto Iceberg by mirror_and_rebuild) and after a hot-table or view RENAME. The
 * view's columns/types are derived from the hot heap, so it always reflects the
 * post-DDL shape. acl is the view's owner and grants (view_acl_sql) when the
 * caller dropped the view before the rebuild; otherwise the rebuild reads them
 * from the view it replaces. */
static void
rebuild_tiered_view(const char *schema, const char *relname, const char *acl)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql, "SELECT coldfront._rebuild_tiered_view(%s, %s, %s)",
        quote_literal_cstr(schema), quote_literal_cstr(relname),
        acl ? quote_literal_cstr(acl) : "NULL");
    spi_exec_void(sql.data);
    pfree(sql.data);
}

/* The statements that give the view back its owner and grants once it is
 * dropped and created again (coldfront._view_acl_sql), read while it exists,
 * as the extension's owner, which runs them (spi_exec_ddl). */
static char *
view_acl_sql(const TieredDDLInfo *info)
{
    StringInfoData sql;
    char          *acl = NULL;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT coldfront._view_acl_sql(format('%%I.%%I', %s, %s)::regclass)",
        quote_literal_cstr(info->view_schema), quote_literal_cstr(info->view_relname));
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        Oid save_uid;
        int save_sec;
        int nest = as_coldfront_owner(&save_uid, &save_sec);

        if (SPI_execute(sql.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
        {
            char *v = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);

            if (v != NULL)
                acl = MemoryContextStrdup(CurTransactionContext, v);
        }
        as_caller(save_uid, save_sec, nest);
        SPI_finish();
    }
    pfree(sql.data);
    return acl;
}

/* Rebuild a decoupled table's wrapper view from its own columns plus actions
 * (coldfront._rebuild_iceberg_view). Its DDL replicates; see spi_exec_ddl. */
static void
rebuild_iceberg_view(const TieredDDLInfo *info, const char *actions)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT coldfront._rebuild_iceberg_view(%s, %s, jsonb_build_array(%s))",
        quote_literal_cstr(info->view_schema), quote_literal_cstr(info->view_relname),
        actions);
    spi_exec_ddl(sql.data, true);
    pfree(sql.data);
}

/* Drop the transparent view (mirror_and_rebuild recreates it). Issued BEFORE a
 * hot-side column DROP / ALTER TYPE: PG refuses to drop or retype a column that a
 * view projects ("used by a view or rule"). Runs under the re-entrancy guard so
 * the DROP VIEW is not itself caught by the DROP-of-tiered-relation block, and is
 * part of the user statement's transaction, so any later failure rolls it back. */
static void
drop_tiered_view(const char *schema, const char *relname)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql, "DROP VIEW IF EXISTS %s.%s CASCADE",
        quote_identifier(schema), quote_identifier(relname));
    coldfront_in_utility = true;
    PG_TRY();
    {
        spi_exec_void(sql.data);
    }
    PG_FINALLY();
    {
        coldfront_in_utility = false;
    }
    PG_END_TRY();
    pfree(sql.data);
}

/* Update registry hot_table after a hot-heap rename. */
static void
update_hot_table(const char *schema, const char *relname, const char *new_hot_quoted)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT coldfront._update_tiered_hot_table(%s, %s, %s)",
        quote_literal_cstr(schema), quote_literal_cstr(relname),
        quote_literal_cstr(new_hot_quoted));
    spi_exec_local_rows(sql.data);
    pfree(sql.data);
}

/* Migrate the name-keyed registry + watermark rows when the transparent view is
 * renamed. The registry is keyed on (schema, relname) and the watermark on the
 * bare view name; without this the rebuilt view loses its cold UNION branch.
 * Idempotent (no-op for whichever row doesn't exist yet). */
static void
rename_tiered_view(const char *schema, const char *old_view_name, const char *new_view_name)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT coldfront._rename_tiered_view(%s, %s, %s)",
        quote_literal_cstr(schema), quote_literal_cstr(old_view_name),
        quote_literal_cstr(new_view_name));
    spi_exec_local_rows(sql.data);
    pfree(sql.data);
}

/*
 * Build the quoted-qualified name ("schema"."rel") for relid, as stored in
 * coldfront.tiered_views.hot_table. Schema resolved at runtime — never assumes
 * public. Returns palloc'd.
 */
static char *
quoted_qualified_name(Oid relid)
{
    char *ns   = get_namespace_name(get_rel_namespace(relid));
    char *name = get_rel_name(relid);
    return psprintf("%s.%s", quote_identifier(ns), quote_identifier(name));
}

/*
 * Mirror collected column DDL onto the Iceberg cold tier — one bakery-serialized,
 * claim-first catalog change via coldfront._mirror_iceberg_alter (a no-op on a
 * Spock apply worker, where the originator already evolved the SHARED catalog) —
 * then rebuild the per-node transparent view to the new column set. `actions` is
 * the body of a jsonb_build_array(...) call: comma-separated jsonb_build_object()
 * terms, each {op, col[, newcol][, type]}. Runs under the re-entrancy guard so
 * the SPI-issued DDL does not re-enter this hook. Any unsupported type raises
 * inside the mirror, rolling the whole statement (hot tier included) back
 * atomically. A decoupled table (no hot table) has its wrapper view rebuilt from
 * the view's own columns plus the actions; acl is a tiered view's owner and
 * grants when the caller dropped the view first. The Iceberg change runs as the
 * caller, as all cold I/O does, and the rebuild as the extension's owner.
 */
static void
mirror_and_rebuild(const TieredDDLInfo *info, const char *actions, const char *acl)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT coldfront._mirror_iceberg_alter(%s, %s, jsonb_build_array(%s))",
        quote_literal_cstr(info->iceberg_table),
        info->hot_table ? quote_literal_cstr(info->hot_table) : "NULL",
        actions);

    coldfront_in_utility = true;
    PG_TRY();
    {
        if (SPI_connect() == SPI_OK_CONNECT)
        {
            SPI_execute(sql.data, false, 0);
            SPI_finish();
        }
        if (info->hot_table != NULL)
            rebuild_tiered_view(info->view_schema, info->view_relname, acl);
        else
            rebuild_iceberg_view(info, actions);
    }
    PG_FINALLY();
    {
        coldfront_in_utility = false;
    }
    PG_END_TRY();
    pfree(sql.data);
}

/*
 * The eight ProcessUtility_hook arguments, bundled so the arm helpers below can
 * both inspect the statement and pass the full argument set straight to the
 * previous/standard utility processor without each carrying nine parameters.
 */
typedef struct {
    PlannedStmt           *pstmt;
    const char            *queryString;
    bool                   readOnlyTree;
    ProcessUtilityContext  context;
    ParamListInfo          params;
    QueryEnvironment      *queryEnv;
    DestReceiver          *dest;
    QueryCompletion       *qc;
} CfUtilityCtx;

/* Run the previous/standard ProcessUtility — the call-through every arm ends
 * in. Centralizes the prev-hook-or-standard dispatch. */
static void
cf_call_through(const CfUtilityCtx *u)
{
    if (prev_process_utility_hook)
        prev_process_utility_hook(u->pstmt, u->queryString, u->readOnlyTree,
                                  u->context, u->params, u->queryEnv, u->dest, u->qc);
    else
        standard_ProcessUtility(u->pstmt, u->queryString, u->readOnlyTree,
                                u->context, u->params, u->queryEnv, u->dest, u->qc);
}

/* ---- DROP TABLE / DROP VIEW: block if any object is tiered. ---- */
static void
cf_handle_drop(const CfUtilityCtx *u, DropStmt *ds)
{
    if (ds->removeType == OBJECT_TABLE || ds->removeType == OBJECT_VIEW)
    {
        ListCell *lc;
        foreach(lc, ds->objects)
        {
            List     *names = (List *) lfirst(lc);
            RangeVar *rv    = makeRangeVarFromNameList(names);
            Oid       relid = RangeVarGetRelid(rv, NoLock, true);
            if (relid_is_tiered(relid, NULL))
            {
                char *ns   = get_namespace_name(get_rel_namespace(relid));
                char *name = get_rel_name(relid);
                ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("coldfront: cannot DROP \"%s.%s\": it has a cold tier in Iceberg",
                            ns, name),
                     errhint("Blocked by design: the Iceberg cold tier would be orphaned. "
                             "Use coldfront.drop_iceberg_table() to remove the table and its "
                             "cold tier, or coldfront.release_iceberg_table() to hand an "
                             "adopted table back with its Iceberg table intact.")));
            }
        }
    }
    cf_call_through(u);
}

/* ---- TRUNCATE: block if any relation is tiered. ---- */
static void
cf_handle_truncate(const CfUtilityCtx *u, TruncateStmt *ts)
{
    ListCell *lc;
    foreach(lc, ts->relations)
    {
        RangeVar *rv    = (RangeVar *) lfirst(lc);
        Oid       relid = RangeVarGetRelid(rv, NoLock, true);
        bool      has_hot;
        if (relid_is_tiered(relid, &has_hot))
        {
            char *ns   = get_namespace_name(get_rel_namespace(relid));
            char *name = get_rel_name(relid);
            ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("coldfront: cannot TRUNCATE tiered table \"%s.%s\": cold-tier rows would remain visible",
                        ns, name),
                 has_hot
                     ? errhint("Truncate the hot partitions individually and delete the cold rows through the view.")
                     : errhint("Delete the rows through the view.")));
        }
    }
    cf_call_through(u);
}

/* PostgreSQL's owner check for an ALTER TABLE, made before the DDL hook changes
 * anything on the user's behalf: a decoupled table's ALTER never reaches
 * PostgreSQL's own, and a tiered table's view is dropped before it. */
static void
require_owner(Oid relid)
{
    if (!object_ownercheck(RelationRelationId, relid, GetUserId()))
        aclcheck_error(ACLCHECK_NOT_OWNER, get_relkind_objtype(get_rel_relkind(relid)),
                       get_rel_name(relid));
}

/* Collect the column-shape subcommands to mirror into *actions (the body of a
 * jsonb_build_array(...) call); ignore the rest. Returns the count collected.
 *
 * For a decoupled table (decoupled non-NULL) PostgreSQL runs none of the
 * statement, so each add and type action carries the declared type, which no
 * hot table holds, and what an Iceberg column and a view cannot take is
 * refused: a default, constraint, collation or storage option on an added
 * column, a USING clause or collation on a type change, and any other
 * subcommand beside a column change. */
static int
cf_collect_alter_actions(AlterTableStmt *at, StringInfoData *actions,
                         const TieredDDLInfo *decoupled)
{
    ListCell *lc;
    int       nacts = 0;

    initStringInfo(actions);
    foreach(lc, at->cmds)
    {
        AlterTableCmd *cmd = (AlterTableCmd *) lfirst(lc);
        ColumnDef     *def = NULL;
        const char    *op  = NULL;
        const char    *col = NULL;
        char          *type = NULL;

        if (cmd->subtype == AT_AddColumn)
        {
            op  = "add";
            def = castNode(ColumnDef, cmd->def);
            col = def->colname;
        }
        else if (cmd->subtype == AT_DropColumn)
        {
            op  = "drop";
            col = cmd->name;
        }
        else if (cmd->subtype == AT_AlterColumnType)
        {
            op  = "type";
            def = castNode(ColumnDef, cmd->def);
            col = cmd->name;
        }
        if (op == NULL)
            continue;

        if (decoupled != NULL && def != NULL)
        {
            Oid   typid;
            int32 typmod;

            if (cmd->subtype == AT_AddColumn &&
                (def->raw_default != NULL || def->cooked_default != NULL ||
                 def->is_not_null || def->identity || def->generated ||
                 def->collClause != NULL || def->constraints != NIL ||
                 def->compression != NULL || def->storage_name != NULL))
                ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("coldfront: an ADD COLUMN on decoupled table \"%s.%s\" takes a name and a type, with no default, constraint, collation, storage or compression option (column \"%s\")",
                            decoupled->view_schema, decoupled->view_relname, col)));
            if (cmd->subtype == AT_AlterColumnType &&
                (def->raw_default != NULL || def->collClause != NULL))
                ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("coldfront: an ALTER COLUMN ... TYPE on decoupled table \"%s.%s\" takes a type alone, with no USING or COLLATE (column \"%s\")",
                            decoupled->view_schema, decoupled->view_relname, col),
                     errhint("Iceberg converts the stored values itself, for the widening it accepts.")));
            typenameTypeIdAndMod(NULL, def->typeName, &typid, &typmod);
            type = format_type_with_typemod(typid, typmod);
        }

        appendStringInfo(actions, "%sjsonb_build_object('op', %s, 'col', %s%s%s)",
                         nacts > 0 ? ", " : "",
                         quote_literal_cstr(op), quote_literal_cstr(col),
                         type ? ", 'type', " : "",
                         type ? quote_literal_cstr(type) : "");
        nacts++;
    }
    if (decoupled != NULL && nacts > 0 && nacts < list_length(at->cmds))
        ereport(ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("coldfront: on decoupled table \"%s.%s\", run a column change as an ALTER TABLE of its own",
                    decoupled->view_schema, decoupled->view_relname)));
    return nacts;
}

/* ---- ALTER TABLE: MIRROR column-shape changes onto the cold tier. ----
 *
 * duckdb-iceberg (v1.5) implements Iceberg ALTER TABLE, so ADD/DROP COLUMN
 * and ALTER COLUMN TYPE evolve both tiers in one statement: PG runs the
 * hot-side ALTER, then coldfront._mirror_iceberg_alter issues the matching
 * Iceberg DDL (one bakery-serialized, claim-first catalog CAS) and the view
 * is rebuilt to the new column set. Every OTHER ALTER subtype — DETACH/ATTACH
 * PARTITION (the archiver's own cutover machinery), storage params, SET
 * STATISTICS, constraint / NOT NULL toggles — is PG-side only and passes
 * straight through untouched. A decoupled table's column change targets its
 * wrapper view, which PostgreSQL cannot alter, so the change goes to the
 * Iceberg table and the view is rebuilt, and PostgreSQL runs none of it. */
static void
cf_handle_alter_table(const CfUtilityCtx *u, AlterTableStmt *at)
{
    Oid             relid = RangeVarGetRelid(at->relation, NoLock, true);
    TieredDDLInfo   info;
    StringInfoData  actions;
    int             nacts;
    char           *acl;

    if (!lookup_tiered_by_hot_oid(relid, &info) &&
        !lookup_iceberg_only_by_view_oid(relid, &info))
    {
        cf_call_through(u);
        return;
    }

    require_owner(relid);
    nacts = cf_collect_alter_actions(at, &actions, info.hot_table ? NULL : &info);

    if (nacts == 0)
    {
        /* No column-shape change → partition management / storage params /
         * the archiver's DETACH / a view's owner. Not coldfront's business. */
        pfree(actions.data);
        cf_call_through(u);
        return;
    }

    if (info.hot_table == NULL)
    {
        mirror_and_rebuild(&info, actions.data, NULL);
        pfree(actions.data);
        return;
    }

    /* The transparent view projects the hot columns, so PG blocks a hot-side
     * DROP COLUMN / ALTER COLUMN TYPE of a projected column ("used by a
     * view"). Drop the view first, run the hot ALTER, then mirror the change
     * onto Iceberg and rebuild the view. One transaction: an unsupported
     * column type (or any failure) raises inside the mirror and rolls the
     * whole statement — view drop and hot change included — back atomically.
     * The view's owner and grants are read before the drop takes them. */
    acl = view_acl_sql(&info);
    drop_tiered_view(info.view_schema, info.view_relname);
    cf_call_through(u);
    mirror_and_rebuild(&info, actions.data, acl);
    pfree(actions.data);
}

/*
 * Resolve a RENAME against the registry. Sets *info (fully via the hot table,
 * or just view_schema/view_relname via the view), *via_hot, *hot_relid and
 * *view_relid. Returns true when the rename targets a tiered relation.
 */
static bool
cf_match_rename_target(RenameStmt *rs, TieredDDLInfo *info, bool *via_hot,
                       Oid *hot_relid, Oid *view_relid)
{
    bool matched = false;

    *via_hot    = false;
    *hot_relid  = InvalidOid;
    *view_relid = InvalidOid;

    if (rs->renameType == OBJECT_TABLE || rs->renameType == OBJECT_COLUMN)
    {
        *hot_relid = RangeVarGetRelid(rs->relation, NoLock, true);
        if (lookup_tiered_by_hot_oid(*hot_relid, info))
            matched = *via_hot = true;
    }
    if (!matched && (rs->renameType == OBJECT_VIEW ||
                     rs->renameType == OBJECT_COLUMN))
    {
        /* Rename targeting the view itself (column rename on a view, or
         * view rename). The registry is keyed by the view's (schema,
         * relname), resolved from the view relid directly — no SPI. */
        *view_relid = RangeVarGetRelid(rs->relation, NoLock, true);
        if (relid_is_tiered(*view_relid, NULL))
        {
            MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);
            info->view_schema  = get_namespace_name(get_rel_namespace(*view_relid));
            info->view_relname = get_rel_name(*view_relid);
            MemoryContextSwitchTo(oldcxt);
            matched = true;
        }
    }
    return matched;
}

/* RENAME COLUMN on the HOT table is mirrored onto the Iceberg column so cold
 * reads keep resolving it by name. On a decoupled table's wrapper view, the
 * one place its columns are named, the Iceberg column is renamed and the view
 * rebuilt, and PostgreSQL runs nothing. A column rename targeting a tiered
 * table's generated VIEW is meaningless (the rebuild owns the view's column
 * names) and is rejected. */
static void
cf_handle_rename_column(const CfUtilityCtx *u, RenameStmt *rs,
                        TieredDDLInfo *info, bool via_hot, Oid view_relid)
{
    StringInfoData acts;

    if (!via_hot && !lookup_iceberg_only_by_view_oid(view_relid, info))
    {
        char *ns   = get_namespace_name(get_rel_namespace(view_relid));
        char *name = get_rel_name(view_relid);
        ereport(ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("coldfront: cannot rename a column of the generated view \"%s.%s\"",
                    ns, name),
             errhint("Rename the column on the hot table instead; coldfront mirrors "
                     "that onto the Iceberg cold tier and rebuilds the view.")));
    }

    if (via_hot)
        cf_call_through(u);   /* PG renames the hot column */
    else
        require_owner(view_relid);
    initStringInfo(&acts);
    appendStringInfo(&acts,
        "jsonb_build_object('op', 'rename', 'col', %s, 'newcol', %s)",
        quote_literal_cstr(rs->subname), quote_literal_cstr(rs->newname));
    mirror_and_rebuild(info, acts.data, NULL);
    pfree(acts.data);
}

/*
 * RENAME of the hot heap or the transparent view. Touches only the PG side
 * (registry + view), never the Iceberg schema. Captures old_view_name BEFORE
 * the call-through so the name-keyed watermark row can be migrated.
 */
static void
cf_handle_rename_relation(const CfUtilityCtx *u, RenameStmt *rs,
                          TieredDDLInfo *info, Oid hot_relid, Oid view_relid)
{
    char *old_view_name = NULL;   /* captured pre-rename for OBJECT_VIEW */

    /* For a VIEW rename, capture the OLD view name NOW (before the rename
     * executes) so we can migrate the name-keyed archive_watermark row. */
    if (rs->renameType == OBJECT_VIEW && OidIsValid(view_relid))
        old_view_name = pstrdup(get_rel_name(view_relid));

    cf_call_through(u);

    coldfront_in_utility = true;
    PG_TRY();
    {
        if (rs->renameType == OBJECT_TABLE && OidIsValid(hot_relid))
        {
            /* Hot heap renamed: the view's name is unchanged, so the
             * registry key is stable — update hot_table, then rebuild. */
            char *new_hot = quoted_qualified_name(hot_relid);
            update_hot_table(info->view_schema, info->view_relname, new_hot);
            rebuild_tiered_view(info->view_schema, info->view_relname, NULL);
        }
        else
        {
            /* View renamed: migrate the name-keyed registry + watermark rows
             * (old→new) FIRST so the rebuild — and the regenerated INSERT
             * trigger — resolve the row by the new name; without this the
             * rebuilt view would silently lose its cold UNION branch. Then
             * rebuild under the new name. */
            if (old_view_name != NULL &&
                strcmp(old_view_name, rs->newname) != 0)
                rename_tiered_view(info->view_schema, old_view_name, rs->newname);
            rebuild_tiered_view(info->view_schema, rs->newname, NULL);
        }
    }
    PG_FINALLY();
    {
        coldfront_in_utility = false;
    }
    PG_END_TRY();
}

/* ---- RENAME: hot table, view, or column on a tiered relation. ---- */
static void
cf_handle_rename(const CfUtilityCtx *u, RenameStmt *rs)
{
    TieredDDLInfo info;
    bool          via_hot;
    Oid           hot_relid;
    Oid           view_relid;

    if (!cf_match_rename_target(rs, &info, &via_hot, &hot_relid, &view_relid))
    {
        cf_call_through(u);
        return;
    }

    if (rs->renameType == OBJECT_COLUMN)
        cf_handle_rename_column(u, rs, &info, via_hot, view_relid);
    else
        cf_handle_rename_relation(u, rs, &info, hot_relid, view_relid);
}

/* ---- COPY FROM on a registered view. ---- */

static bool
cf_copy_has_option(List *options, const char *name)
{
    ListCell *lc;

    foreach(lc, options)
        if (strcmp(((DefElem *) lfirst(lc))->defname, name) == 0)
            return true;
    return false;
}

/*
 * COPY <view> FROM reads the rows with PostgreSQL's COPY reader and writes
 * them in batches of coldfront.cold_write_batch_size rows, each batch one
 * INSERT ... VALUES into the view with every value as a literal in its type's
 * text form. That INSERT goes through the parse-analysis hook like any other,
 * so the routing, the claim, the identity values and the defaults are the
 * INSERT's, for a tiered and for a decoupled view alike. OVERRIDING SYSTEM
 * VALUE because COPY into a table keeps a supplied value for a GENERATED
 * ALWAYS identity column. The reader applies the format options; WHERE and
 * the options that act after a row is read (FREEZE, ON_ERROR, REJECT_LIMIT,
 * DEFAULT) have no row to act on here and are refused.
 */
static void
cf_handle_copy(CfUtilityCtx *u, CopyStmt *stmt)
{
    static const char *refused[] = { "freeze", "on_error", "reject_limit", "default", NULL };
    TieredViewInfo info;
    Oid            relid;
    Relation       rel;
    TupleDesc      desc;
    ParseState    *pstate;
    CopyFromState  cstate;
    ExprContext   *econtext;
    MemoryContext  rowctx, oldctx;
    StringInfoData sql;
    FmgrInfo      *outfn;
    Datum         *values;
    bool          *nulls;
    int           *attnum;          /* the COPY's columns, in its order, 1-based */
    int            ncols = 0, prefix_len, c, i;
    int            n = 0, batch = coldfront_cold_write_batch_size;
    uint64         processed = 0;
    ListCell      *lc;

    relid = stmt->is_from && stmt->relation
        ? RangeVarGetRelid(stmt->relation, NoLock, true) : InvalidOid;
    if (!OidIsValid(relid) || get_rel_relkind(relid) != RELKIND_VIEW ||
        !lookup_tiered_view(relid, get_rel_name(relid), &info))
    {
        cf_call_through(u);
        return;
    }

    if (stmt->whereClause)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("COPY ... WHERE is not supported on a tiered view"),
                 errhint("Filter the rows before loading them.")));
    for (i = 0; refused[i]; i++)
        if (cf_copy_has_option(stmt->options, refused[i]))
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("COPY option %s is not supported on a tiered view",
                            refused[i])));

    /* The checks DoCopy makes before it reads a server-side source. */
    if (stmt->filename && stmt->is_program &&
        !has_privs_of_role(GetUserId(), ROLE_PG_EXECUTE_SERVER_PROGRAM))
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("permission denied to COPY to or from an external program"),
                 errdetail("Only roles with privileges of the \"%s\" role may COPY to or from an external program.",
                           "pg_execute_server_program")));
    if (stmt->filename && !stmt->is_program &&
        !has_privs_of_role(GetUserId(), ROLE_PG_READ_SERVER_FILES))
        ereport(ERROR,
                (errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
                 errmsg("permission denied to COPY from a file"),
                 errdetail("Only roles with privileges of the \"%s\" role may COPY from a file.",
                           "pg_read_server_files")));
    if (XactReadOnly)
        PreventCommandIfReadOnly("COPY FROM");

    rel  = relation_open(relid, AccessShareLock);
    desc = RelationGetDescr(rel);

    /* The INSERT's column list is the COPY's; BeginCopyFrom rejects a name
     * that is not a column. */
    attnum = palloc(sizeof(int) * desc->natts);
    if (stmt->attlist)
    {
        foreach(lc, stmt->attlist)
            for (i = 0; i < desc->natts; i++)
                if (strcmp(NameStr(TupleDescAttr(desc, i)->attname), strVal(lfirst(lc))) == 0)
                    attnum[ncols++] = i + 1;
    }
    else
    {
        for (i = 0; i < desc->natts; i++)
            attnum[ncols++] = i + 1;
    }
    outfn = palloc(sizeof(FmgrInfo) * ncols);
    initStringInfo(&sql);
    appendStringInfo(&sql, "INSERT INTO %s.%s (",
                     quote_identifier(get_namespace_name(get_rel_namespace(relid))),
                     quote_identifier(get_rel_name(relid)));
    for (c = 0; c < ncols; c++)
    {
        Form_pg_attribute att = TupleDescAttr(desc, attnum[c] - 1);
        Oid               outoid;
        bool              isvarlena;

        getTypeOutputInfo(att->atttypid, &outoid, &isvarlena);
        fmgr_info(outoid, &outfn[c]);
        appendStringInfo(&sql, "%s%s", c ? ", " : "", quote_identifier(NameStr(att->attname)));
    }
    appendStringInfoString(&sql, ") OVERRIDING SYSTEM VALUE VALUES ");
    prefix_len = sql.len;

    pstate = make_parsestate(NULL);
    pstate->p_sourcetext = u->queryString;
    cstate = BeginCopyFrom(pstate, rel, NULL, stmt->filename, stmt->is_program,
                           NULL, stmt->attlist, stmt->options);
    econtext = CreateStandaloneExprContext();
    rowctx = AllocSetContextCreate(CurrentMemoryContext, "coldfront copy row",
                                   ALLOCSET_DEFAULT_SIZES);
    values = palloc(sizeof(Datum) * desc->natts);
    nulls  = palloc(sizeof(bool) * desc->natts);

    for (;;)
    {
        bool more;

        /* The reader allocates each row's values in the current context, and
         * the rendered literals go there too; the statement text is copied. */
        MemoryContextReset(rowctx);
        oldctx = MemoryContextSwitchTo(rowctx);
        more = NextCopyFrom(cstate, econtext, values, nulls);
        if (more)
        {
            appendStringInfoString(&sql, n ? ", (" : "(");
            for (c = 0; c < ncols; c++)
            {
                if (c)
                    appendStringInfoString(&sql, ", ");
                if (nulls[attnum[c] - 1])
                    appendStringInfoString(&sql, "NULL");
                else
                    appendStringInfoString(&sql, quote_literal_cstr(
                        OutputFunctionCall(&outfn[c], values[attnum[c] - 1])));
            }
            appendStringInfoChar(&sql, ')');
            n++;
            processed++;
        }
        MemoryContextSwitchTo(oldctx);

        if (n > 0 && (n == batch || !more))
        {
            if (SPI_connect() != SPI_OK_CONNECT)
                elog(ERROR, "coldfront: SPI_connect failed in COPY");
            if (SPI_execute(sql.data, false, 0) < 0)
                elog(ERROR, "coldfront: the INSERT of a COPY batch failed");
            SPI_finish();
            sql.len = prefix_len;
            sql.data[prefix_len] = '\0';
            n = 0;
        }
        if (!more)
            break;
    }

    EndCopyFrom(cstate);
    FreeExprContext(econtext, true);
    MemoryContextDelete(rowctx);
    relation_close(rel, NoLock);
    if (u->qc)
        SetQueryCompletion(u->qc, CMDTAG_COPY, processed);
}

/*
 * The coldfront ProcessUtility_hook. Intercepts DDL on registered tiered
 * relations: blocks DROP/TRUNCATE, mirrors schema/rename DDL to Iceberg, and
 * rebuilds the transparent view. Everything else passes straight through.
 *
 * Spock apply worker: the DDL the hook ACTS on for a tiered table is
 * DROP/TRUNCATE (blocked — never replicated, they error on the originator),
 * column DDL (ADD/DROP/ALTER-TYPE/RENAME COLUMN — mirrored to Iceberg), and
 * RENAME TABLE/VIEW. A replicated statement re-runs in the peer's apply
 * worker, and the hook then makes the peer's own registry update and view
 * rebuild. The hook's SPI DDL runs with spock.enable_ddl_replication off
 * (spi_exec_void) and its registry updates in Spock's repair mode
 * (spi_exec_local_rows), so only the user's statement replicates. The
 * Iceberg cold tier, by contrast, is SHARED (one Lakekeeper), so its column
 * DDL must run exactly once: the mirror (coldfront._mirror_iceberg_alter)
 * self-skips when session_replication_role = replica, leaving the apply
 * worker to rebuild its local view only.
 */
static void
coldfront_process_utility(PlannedStmt *pstmt, const char *queryString,
                          bool readOnlyTree, ProcessUtilityContext context,
                          ParamListInfo params, QueryEnvironment *queryEnv,
                          DestReceiver *dest, QueryCompletion *qc)
{
    Node         *stmt = pstmt->utilityStmt;
    CfUtilityCtx  u    = { pstmt, queryString, readOnlyTree, context,
                           params, queryEnv, dest, qc };

    /* Re-entrant SPI-issued DDL (our own CREATE VIEW/TRIGGER): no coldfront
     * work, just run it. */
    if (coldfront_in_utility)
    {
        cf_call_through(&u);
        return;
    }

    /* No coldfront registry in this database → nothing tiered here. The hook
     * is cluster-wide (shared_preload_libraries) but the extension may not be
     * installed in this DB (e.g. a co-located Lakekeeper catalog, or a DB
     * mid-bootstrap before CREATE EXTENSION). Skip all coldfront work so we
     * never SPI-query a non-existent coldfront.tiered_views and abort
     * unrelated DDL. */
    if (!coldfront_registry_present())
    {
        cf_call_through(&u);
        return;
    }

    if (IsA(stmt, DropStmt))
        cf_handle_drop(&u, (DropStmt *) stmt);
    else if (IsA(stmt, TruncateStmt))
        cf_handle_truncate(&u, (TruncateStmt *) stmt);
    else if (IsA(stmt, AlterTableStmt))
        cf_handle_alter_table(&u, (AlterTableStmt *) stmt);
    else if (IsA(stmt, RenameStmt))
        cf_handle_rename(&u, (RenameStmt *) stmt);
    else if (IsA(stmt, CopyStmt))
        cf_handle_copy(&u, (CopyStmt *) stmt);
    else
        cf_call_through(&u);
}

/* ---------- _PG_init -------------------------------------------------- */

void _PG_init(void);

/* register_gucs defines coldfront's custom GUCs. Split out of _PG_init so the
 * init function stays a short, readable list of GUC + hook installs. */
static void
register_gucs(void)
{
    DefineCustomBoolVariable(
        "coldfront.allow_mixed_writes",
        "Permit ambiguous UPDATE/DELETE on tiered views to rewrite to both tiers.",
        "When on (default), a WHERE clause that cannot be proven to target "
        "a single tier triggers a dual-tier CTE that writes to both hot "
        "(_events) and cold (Iceberg) sides in the same statement. The "
        "extension enables duckdb.unsafe_allow_mixed_transactions LOCAL so "
        "pg_duckdb accepts the mixed write; DuckDB's XactCallback keeps the "
        "DuckDB transaction tied to PG's, so ROLLBACK undoes both tiers. "
        "When off, such predicates raise an ERROR with a hint.",
        &coldfront_allow_mixed_writes,
        true,           /* boot_val: permissive by default */
        PGC_USERSET,
        0,              /* flags */
        NULL, NULL, NULL);

    DefineCustomIntVariable(
        "coldfront.cold_write_batch_size",
        "Rows per Iceberg write in a tiered INSERT's cold sink (coldfront._cold_sink).",
        "Every batch_size cold rows the sink flushes one duckdb.raw_query INSERT. "
        "Larger means fewer, bigger files; the trailing remainder always flushes, "
        "so a small write stays a single file.",
        &coldfront_cold_write_batch_size,
        10000,              /* boot_val */
        1,                  /* min */
        PG_INT32_MAX,       /* max */
        PGC_USERSET,
        0,
        NULL, NULL, NULL);

    DefineCustomBoolVariable(
        "coldfront.vector_probe",
        "Restrict a recognised similarity search to its nearest clusters.",
        "When on (default), a top-k search on a clustered vector column reads only "
        "the clusters nearest the query vector, which is approximate in the way "
        "every vector index is. Off gives an exact scan of the whole corpus: "
        "slower, and the reference a recall measurement compares against.",
        &coldfront_vector_probe,
        true,           /* boot_val */
        PGC_USERSET,
        0,              /* flags */
        NULL, NULL, NULL);

    DefineCustomIntVariable(
        "coldfront.vector_nprobe",
        "Clusters a similarity search reads, overriding the table's own setting.",
        "0 (default) uses the nprobe recorded for the column in "
        "coldfront.vector_config. A value at or above that column's nlist reads "
        "every cluster, which is exact and is how an approximate result is "
        "compared against ground truth without turning the rewrite off.",
        &coldfront_vector_nprobe,
        0,                  /* boot_val: defer to vector_config */
        0,                  /* min */
        PG_INT32_MAX,       /* max */
        PGC_USERSET,
        0,
        NULL, NULL, NULL);

    /*
     * Deployment-config endpoint/DSN GUCs. PGC_SUSET so a non-superuser cannot
     * redirect the SECURITY DEFINER ensure_attached()/ensure_pg_attached()
     * ATTACH at an attacker endpoint. boot_val "" preserves the prior
     * placeholder behaviour (unset => the attach helpers are a no-op).
     */
    DefineCustomStringVariable(
        "coldfront.warehouse",
        "Lakekeeper warehouse name the Iceberg catalog 'ice' attaches to.",
        NULL,
        &coldfront_warehouse,
        "",
        PGC_SUSET,
        0,
        NULL, NULL, NULL);

    DefineCustomStringVariable(
        "coldfront.lakekeeper_endpoint",
        "Iceberg REST catalog (Lakekeeper) endpoint URL.",
        NULL,
        &coldfront_lakekeeper_endpoint,
        "",
        PGC_SUSET,
        0,
        NULL, NULL, NULL);

    DefineCustomStringVariable(
        "coldfront.local_pg_dsn",
        "libpq DSN DuckDB's postgres extension attaches as 'pglocal' to stream "
        "PG-source rows into Iceberg. May carry credentials.",
        NULL,
        &coldfront_local_pg_dsn,
        "",
        PGC_SUSET,
        GUC_SUPERUSER_ONLY,
        NULL, NULL, NULL);

    DefineCustomStringVariable(
        "coldfront.loopback_dsn",
        "libpq DSN of the loopback that runs the mesh bakery's claims, acks "
        "and releases, each committed on its own; a unix socket.",
        NULL,
        &coldfront_loopback_dsn,
        "",
        PGC_SUSET,
        0,
        NULL, NULL, NULL);

    /*
     * The bakery's dead-peer window: a peer whose walsender has not replied
     * within it counts as already acked (_claim_iceberg_lock), so an ordinary
     * role must not be able to shrink it.
     */
    DefineCustomIntVariable(
        "coldfront.peer_alive_window_ms",
        "Milliseconds without a walsender reply after which the bakery treats a peer as dead.",
        NULL,
        &coldfront_peer_alive_window_ms,
        10000,
        1,
        PG_INT32_MAX,
        PGC_SUSET,
        0,
        NULL, NULL, NULL);

    /*
     * The async parquet ordering runs only with both on (_iceberg_async_active).
     * The request flag is PGC_USERSET because _cross_tier_move and the Iceberg
     * ALTER path SET LOCAL it off; the build marker states that the loaded
     * duckdb-iceberg includes the bakery-aware patch, which only the deployment
     * knows, so it is PGC_SUSET.
     */
    DefineCustomBoolVariable(
        "coldfront.iceberg_async_parquet",
        "Stage a cold write's Parquet before taking the bakery claim.",
        NULL,
        &coldfront_iceberg_async_parquet,
        false,
        PGC_USERSET,
        0,
        NULL, NULL, NULL);

    DefineCustomBoolVariable(
        "coldfront.iceberg_bakery_patch",
        "The loaded duckdb-iceberg includes the bakery-aware commit refresh.",
        NULL,
        &coldfront_iceberg_bakery_patch,
        false,
        PGC_SUSET,
        0,
        NULL, NULL, NULL);

    /* Per-session state the SQL keeps with set_config. */
    DefineCustomStringVariable(
        "coldfront._claimed",
        "Iceberg tables this transaction holds a bakery claim on, one per line.",
        NULL,
        &coldfront_claimed,
        "",
        PGC_USERSET,
        0,
        NULL, NULL, NULL);

    DefineCustomBoolVariable(
        "coldfront._async_downgrade_warned",
        "This session has logged its fall-back from the async ordering.",
        NULL,
        &coldfront_async_downgrade_warned,
        false,
        PGC_USERSET,
        0,
        NULL, NULL, NULL);

    /* Every coldfront.* name is registered above, so a mistyped one is refused. */
    MarkGUCPrefixReserved("coldfront");
}

/* ---------- planner hook: bound parameters on a tiered read ------------- */

/*
 * pg_duckdb deparses a PARAM_EXTERN as a bare $N placeholder. DuckDB types most
 * placeholders from their context (ts > $1), but not one that is a direct argument
 * of a DuckDB function with several overloads (time_bucket's origin) or any argument
 * of a table function (generate_series), so such a prepared tiered read fails to
 * plan. The values are known here: the plan cache hands the planner bound_params for
 * every custom plan, and a custom plan serves exactly that execution, so when a
 * parameter sits in one of those two places every parameter is folded to a Const
 * before pg_duckdb plans (what eval_const_expressions would do later for a
 * PostgreSQL plan). The generic-plan build carries no values; it is answered with a
 * PostgreSQL plan priced above any custom plan, so the cache keeps choosing the
 * value-bearing custom plans and never runs the generic one (plan_cache_mode =
 * force_generic_plan does run it, and pg_duckdb's read functions then refuse
 * PostgreSQL execution). A read whose parameters DuckDB types on its own is left
 * alone and keeps its generic plan. A DuckDB function is recognised as one the
 * pg_duckdb extension owns: every function it declares stands for a DuckDB one.
 */
#define CF_GENERIC_PLAN_COST 1.0e10

typedef struct { ParamListInfo params; } FoldParamsCtx;
typedef struct { Oid duckdb_ext; bool in_table_func; } NeedsValueCtx;

static bool
is_extern_param(Node *node)
{
    return node != NULL && IsA(node, Param) &&
           ((Param *) node)->paramkind == PARAM_EXTERN;
}

static bool
has_extern_param_walker(Node *node, void *ctx)
{
    if (node == NULL)
        return false;
    if (IsA(node, Param))
        return is_extern_param(node);
    if (IsA(node, Query))
        return query_tree_walker((Query *) node, has_extern_param_walker, ctx, 0);
    return expression_tree_walker(node, has_extern_param_walker, ctx);
}

/* True if a PARAM_EXTERN sits where DuckDB cannot type a placeholder. */
static bool
param_needs_value_walker(Node *node, void *ctx)
{
    NeedsValueCtx *nv = (NeedsValueCtx *) ctx;

    if (node == NULL)
        return false;
    if (IsA(node, Param))
        return nv->in_table_func && is_extern_param(node);
    if (IsA(node, RangeTblEntry))
    {
        RangeTblEntry *rte = (RangeTblEntry *) node;
        bool           found;

        if (rte->rtekind != RTE_FUNCTION)
            return false;
        nv->in_table_func = true;
        found = expression_tree_walker((Node *) rte->functions, param_needs_value_walker, ctx);
        nv->in_table_func = false;
        return found;
    }
    if (IsA(node, FuncExpr) &&
        getExtensionOfObject(ProcedureRelationId, ((FuncExpr *) node)->funcid) == nv->duckdb_ext)
    {
        ListCell *lc;

        foreach(lc, ((FuncExpr *) node)->args)
            if (is_extern_param((Node *) lfirst(lc)))
                return true;
    }
    if (IsA(node, Query))
        return query_tree_walker((Query *) node, param_needs_value_walker, ctx,
                                 QTW_EXAMINE_RTES_BEFORE);
    return expression_tree_walker(node, param_needs_value_walker, ctx);
}

static Node *
fold_params_mutator(Node *node, void *ctx)
{
    ParamListInfo params = ((FoldParamsCtx *) ctx)->params;

    if (node == NULL)
        return NULL;
    if (IsA(node, Param))
    {
        Param           *p = (Param *) node;
        ParamExternData  prmdata;
        ParamExternData *prm;
        int16            typlen;
        bool             typbyval;

        if (p->paramkind != PARAM_EXTERN || p->paramid < 1 ||
            p->paramid > params->numParams)
            return expression_tree_mutator(node, fold_params_mutator, ctx);
        if (params->paramFetch != NULL)
            prm = params->paramFetch(params, p->paramid, true, &prmdata);
        else
            prm = &params->params[p->paramid - 1];
        if (!OidIsValid(prm->ptype) || prm->ptype != p->paramtype)
            return expression_tree_mutator(node, fold_params_mutator, ctx);
        get_typlenbyval(p->paramtype, &typlen, &typbyval);
        return (Node *) makeConst(p->paramtype, p->paramtypmod, p->paramcollid, typlen,
                                  prm->isnull ? (Datum) 0
                                              : datumCopy(prm->value, typbyval, typlen),
                                  prm->isnull, typbyval);
    }
    if (IsA(node, Query))
        return (Node *) query_tree_mutator((Query *) node, fold_params_mutator, ctx, 0);
    return expression_tree_mutator(node, fold_params_mutator, ctx);
}

static PlannedStmt *
coldfront_planner(Query *parse, const char *query_string, int cursor_options,
                  ParamListInfo bound_params)
{
    if (parse->commandType == CMD_SELECT && coldfront_registry_present() &&
        query_tree_walker(parse, has_extern_param_walker, NULL, 0) &&
        query_reads_tiered_view(parse))
    {
        NeedsValueCtx nv = { get_extension_oid("pg_duckdb", true), false };

        if (OidIsValid(nv.duckdb_ext) &&
            query_tree_walker(parse, param_needs_value_walker, &nv, QTW_EXAMINE_RTES_BEFORE))
        {
            FoldParamsCtx fc = { bound_params };

            if (bound_params == NULL)
            {
                PlannedStmt *generic = standard_planner(parse, query_string, cursor_options, NULL);

                generic->planTree->total_cost = CF_GENERIC_PLAN_COST;
                return generic;
            }
            parse = query_tree_mutator(parse, fold_params_mutator, &fc, 0);
        }
    }
    if (prev_planner_hook)
        return prev_planner_hook(parse, query_string, cursor_options, bound_params);
    return standard_planner(parse, query_string, cursor_options, bound_params);
}

void
_PG_init(void)
{
    /* The hooks exist only in a preloaded library; a session that loaded it
     * later would run the SQL without them. */
    if (!process_shared_preload_libraries_in_progress)
        ereport(ERROR,
                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
                 errmsg("coldfront must be loaded via shared_preload_libraries"),
                 errhint("Add coldfront to shared_preload_libraries after pg_duckdb and restart the server.")));

    register_gucs();

    prev_post_parse_analyze_hook = post_parse_analyze_hook;
    post_parse_analyze_hook      = coldfront_post_parse_analyze;

    /* Bound parameters on a tiered read (coldfront_planner). Chains pg_duckdb's
     * planner_hook (coldfront loads later, so prev == pg_duckdb's): the fold runs
     * before DuckDB plans. */
    prev_planner_hook = planner_hook;
    planner_hook      = coldfront_planner;

    /* DDL synchronization for tiered tables. Chains pg_duckdb's
     * ProcessUtility_hook (coldfront loads later, so prev == pg_duckdb's). */
    prev_process_utility_hook = ProcessUtility_hook;
    ProcessUtility_hook       = coldfront_process_utility;

    /* Register the bakery release callback. The order the bakery needs is by
     * event, not by registration: pg_duckdb commits the Iceberg transaction at
     * XACT_EVENT_PRE_COMMIT and this callback releases the claim at
     * XACT_EVENT_COMMIT. Within one event PostgreSQL runs the most recently
     * registered callback first, so there coldfront's runs before pg_duckdb's. */
    RegisterXactCallback(coldfront_xact_callback, NULL);
}
