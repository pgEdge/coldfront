/*
 * coldfront.c
 *
 * post_parse_analyze_hook that intercepts UPDATE/DELETE on registered tiered
 * views and rewrites the Query into a single-tier form based on the WHERE
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
 * function call.  In both cases the rewritten query contains no iceberg_scan
 * references, so pg_duckdb's planner hook leaves it alone.
 *
 * INSERT is handled by the existing INSTEAD OF INSERT trigger on the view —
 * no rewrite needed here.
 *
 * ATTACH requirement: the DuckDB 'ice' catalog alias must be attached in the
 * current session before cold DML fires.  The hook calls
 * coldfront.ensure_attached() via SPI on the cold path; it reads the
 * coldfront.warehouse / coldfront.lakekeeper_endpoint GUCs and issues
 * ATTACH IF NOT EXISTS.  The helper is installed by coldfront--1.0.sql.
 */

#include "postgres.h"

#include "access/attnum.h"
#include "access/xact.h"
#include "catalog/namespace.h"
#include "catalog/pg_class.h"
#include "catalog/pg_type_d.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "nodes/parsenodes.h"
#include "nodes/nodeFuncs.h"
#include "nodes/pg_list.h"
#include "parser/analyze.h"
#include "tcop/tcopprot.h"
#include "tcop/utility.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/regproc.h"
#include "utils/ruleutils.h"
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
 * Cold DML works fine as a top-level statement but used to fail when issued
 * from inside a plpgsql function / DO block / trigger, for TWO independent
 * reasons:
 *
 *   (1) Bound parameters. plpgsql (and any client using bind params / PREPARE
 *       / the extended protocol) compiles variable references into $N
 *       PARAM_EXTERN nodes whose VALUES are unknown at parse-analyze time —
 *       which is exactly when this hook runs (there is no executor hook). The
 *       deparser emits those $N as literal text, so the cold SQL handed to
 *       duckdb.raw_query carried "$N" with nothing to bind -> DuckDB error
 *       "Expected N parameters, but none were supplied". FIX: keep the params
 *       LIVE — emit the cold SQL as a runtime format(<template>, $1, $2, ...)
 *       call (cold_sql_arg) and declare the param types on the re-parse, so PG
 *       binds the values at execution and DuckDB only ever sees finished
 *       literals. This applies EVERYWHERE (top level and plpgsql) and needs no
 *       table.
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
 *       FIX (only where needed): when — and only when — this statement is being
 *       parsed inside plpgsql, wrap the cold call as a DML over the dummy
 *       carrier coldfront._dummy_dml_target (see cold_anchor_update + that
 *       table's comment in coldfront--1.0.sql). At top level we keep today's
 *       SELECT shape byte-for-byte, so nothing there changes.
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
 * means there are none (the path is then byte-identical to the old literal).
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
 * GUCs: the deployment-config endpoint/DSN strings that ensure_attached() /
 * ensure_pg_attached() feed to DuckDB's ATTACH. Those helpers are SECURITY
 * DEFINER (they must run elevated so the side-loaded iceberg/postgres
 * extensions load past pg_duckdb's non-superuser LocalFileSystem block), so a
 * non-superuser must NOT be able to redirect the elevated ATTACH at an
 * attacker endpoint. Defining these formally as PGC_SUSET (vs. the bare
 * placeholders they used to be) makes them settable only by superusers / roles
 * granted SET on them — operators still set them in postgresql.conf, where they
 * ride physical replication unchanged. local_pg_dsn is GUC_SUPERUSER_ONLY too:
 * it can carry libpq credentials, so non-superusers must not read it back.
 * The values are read SQL-side via current_setting(); these backing vars exist
 * only to anchor the GUC definitions.
 */
static char *coldfront_warehouse          = NULL;
static char *coldfront_lakekeeper_endpoint = NULL;
static char *coldfront_local_pg_dsn       = NULL;

static post_parse_analyze_hook_type prev_post_parse_analyze_hook = NULL;

/* Previous ProcessUtility_hook (pg_duckdb's, since coldfront loads after it). */
static ProcessUtility_hook_type prev_process_utility_hook = NULL;

/*
 * Forward decl (defined with the DDL hook below): "is CREATE EXTENSION coldfront
 * present in THIS database?". The parse-analyze hook needs the same guard the
 * DDL hook uses — both are registered cluster-wide.
 */
static bool coldfront_registry_present(void);

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
    char        *iceberg_table;   /* e.g. "ice.default.events"   */
    char        *partition_col;   /* e.g. "ts"; NULL when is_iceberg_only */
    bool         has_cutoff;      /* false → nothing archived yet */
    bool         is_iceberg_only; /* true → table lives entirely in Iceberg, no hot tier */
    TimestampTz  cutoff;          /* archive watermark            */
} TieredViewInfo;

/*
 * Which tier a DML statement targets, based on its WHERE clause predicate on
 * the partition column.  TIER_AMBIGUOUS means we cannot prove the predicate
 * restricts to a single tier — the hook rejects such statements rather than
 * attempting a non-atomic cross-tier write.
 */
typedef enum { TIER_HOT, TIER_COLD, TIER_AMBIGUOUS } TierClass;

/* ---------- catalog lookup -------------------------------------------- */

/*
 * Look up the tiered_views catalog row for relid via SPI, also fetching the
 * current archive watermark (if any).  vname must be get_rel_name(relid) —
 * the caller already has it, so we avoid a redundant syscache hit.
 * Returns true and populates *info (palloc'd into CurTransactionContext)
 * if found; false otherwise.
 */
static bool
lookup_tiered_view(Oid relid, const char *vname, TieredViewInfo *info)
{
    int            ret;
    bool           found = false;
    StringInfoData sql;

    if (SPI_connect() != SPI_OK_CONNECT)
        return false;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT tv.hot_table, tv.iceberg_table, tv.partition_col, "
        "       tv.is_iceberg_only, aw.cutoff_time "
        "FROM coldfront.tiered_views tv "
        "LEFT JOIN coldfront.archive_watermark aw ON aw.table_name = %s "
        "WHERE tv.schema_name = %s AND tv.relname = %s",
        quote_literal_cstr(vname),
        quote_literal_cstr(get_namespace_name(get_rel_namespace(relid))),
        quote_literal_cstr(vname));
    ret = SPI_execute(sql.data, true, 1);

    if (ret == SPI_OK_SELECT && SPI_processed == 1)
    {
        bool            isnull;
        Datum           d;
        char           *s;
        MemoryContext   oldcxt = MemoryContextSwitchTo(CurTransactionContext);

        /* hot_table and partition_col are NULLable for iceberg-only rows. */
        s = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1);
        info->hot_table = s ? pstrdup(s) : NULL;

        info->iceberg_table = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                    SPI_tuptable->tupdesc, 2));

        s = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 3);
        info->partition_col = s ? pstrdup(s) : NULL;

        d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 4, &isnull);
        info->is_iceberg_only = !isnull && DatumGetBool(d);

        d = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 5, &isnull);
        info->has_cutoff = !isnull;
        if (!isnull)
            info->cutoff = DatumGetTimestampTz(d);

        MemoryContextSwitchTo(oldcxt);
        found = true;
    }

    SPI_finish();
    return found;
}

/*
 * True if the query reads from a registered tiered/iceberg-only view — any
 * RangeTblEntry that is a VIEW resolving in coldfront.tiered_views.  Used to
 * lazily attach 'ice' before a plain SELECT against a tiered view executes:
 * the view body's iceberg_scan('ice...') only resolves once the catalog is
 * attached.  The cheap relkind syscache check gates the SPI lookup so plain
 * table queries (the OLTP hot path) never pay for it.
 */
static bool
query_reads_tiered_view(Query *query)
{
    ListCell *lc;

    foreach(lc, query->rtable)
    {
        RangeTblEntry *rte = (RangeTblEntry *) lfirst(lc);
        TieredViewInfo info;

        if (rte->rtekind != RTE_RELATION)
            continue;
        if (get_rel_relkind(rte->relid) != RELKIND_VIEW)
            continue;
        if (lookup_tiered_view(rte->relid, get_rel_name(rte->relid), &info))
            return true;
    }
    return false;
}

/*
 * Count references to one relation OID anywhere in the query tree — the result
 * relation plus any self-join FROM/USING entry, sub-select, or CTE that resolves
 * to the same view.  QTW_EXAMINE_RTES_BEFORE makes the walker fire on each
 * RangeTblEntry; recursion into sub-Querys (RTE_SUBQUERY and SubLink subselects)
 * goes through the Query arm.  Used to reject DML that names a tiered view more
 * than once: the deparse rewrite only swaps the leading result-relation token,
 * so a second reference would be copied through verbatim and fail confusingly.
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

        /* v0.1 handles only ArrayExpr element lists; Const-array folding
         * happens later in the planner so we should see ArrayExpr here. */
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
 * Entry point: classify the query's WHERE clause.  If nothing has been
 * archived yet, all rows are hot by definition.
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

    return classify_qual((Node *) query->jointree->quals,
                         (Index) query->resultRelation,
                         partcol_attno,
                         info->cutoff);
}

/* ---------- string helpers -------------------------------------------- */

typedef struct { const char *pg; const char *duck; } CfSubst;

/*
 * Cold-WRITE substitutions. The deparsed cold DML is handed to DuckDB inside a
 * duckdb.raw_query() string, so DuckDB-only spellings are fine. Multi-word PG
 * casts map to DuckDB's single-word names, and the boundary-aware jsonb→json
 * catch-all (cf_apply_subst's jsonb_catchall arm) maps every other jsonb token —
 * ::jsonb, jsonb_set, jsonb_extract_path, … — to its json_<rest> form. The few
 * whose DuckDB name is not json_<rest> are listed here, matched with the opening
 * paren so a column prefix can't false-match. A result DuckDB lacks (e.g.
 * json_set) errors in DuckDB — its boundary, not a rewrite coldfront withholds.
 */
static const CfSubst cf_write_subst[] = {
    { "::timestamp with time zone",    "::timestamptz" },
    { "::timestamp without time zone", "::timestamp"   },
    { "::character varying",           "::varchar"     },
    { "::double precision",            "::double"      },
    { "jsonb_build_object(",           "json_object("  },
    { "jsonb_build_array(",            "json_array("   },
    { "to_jsonb(",                     "to_json("      },
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
 * verified identical ([10,20,30]→3, []→0) and exists in both.
 */
static const CfSubst cf_read_subst[] = {
    { "::jsonb",             "::json"             },
    { "jsonb_array_length(", "json_array_length(" },
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
                if (strncmp(p, map[i].pg, plen) == 0)
                {
                    appendStringInfoString(&buf, map[i].duck);
                    p += plen;
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
                bool prev_boundary =
                    !((prev >= 'A' && prev <= 'Z') || (prev >= 'a' && prev <= 'z') ||
                      (prev >= '0' && prev <= '9') || prev == '_');
                bool next_ok =
                    !((next >= 'A' && next <= 'Z') || (next >= 'a' && next <= 'z') ||
                      (next >= '0' && next <= '9'));
                if (prev_boundary && next_ok)
                {
                    appendStringInfoString(&buf, "json");
                    p += 5;
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
normalize_jsonb_for_read(const char *sql)
{
    return cf_apply_subst(sql, cf_read_subst, lengthof(cf_read_subst), false);
}

/* ---------- SQL builder ----------------------------------------------- */

/*
 * Result of deparsing + finding the leading target-relation prefix.
 * rest points into orig_sql, just past the matched prefix; verb is either
 * "UPDATE " or "DELETE FROM " (always ends with a space).
 *
 * pg_get_querydef() qualifies relation names only when the schema is not in
 * the search_path.  For the typical case of public.events with default
 * search_path, the deparsed string starts with "UPDATE events" or
 * "DELETE FROM events" (no schema prefix).  We try the unqualified form
 * first, then fall back to the schema-qualified form.
 */
typedef struct {
    char       *orig_sql;   /* normalised, leading-whitespace-stripped */
    size_t      head_len;   /* bytes before the verb: a leading WITH clause, else 0 */
    const char *rest;       /* points into orig_sql, past the prefix   */
    const char *verb;       /* "UPDATE " / "DELETE FROM " / "INSERT INTO " */
} DeparseResult;

/*
 * Locate the "VERB <relation> " prefix in the deparsed DML: the first occurrence
 * outside any single-quoted string literal. A leading WITH clause puts the verb
 * past offset 0, so this scans rather than anchoring at the start; the bytes
 * before the match are that WITH preamble, which the builders carry through
 * verbatim. cf_reject_multi_reference guarantees the result relation is named
 * once, so the first out-of-literal hit is the statement's own target. Only one
 * of the unqualified / schema-qualified spellings can match (the deparser emits
 * one form). Returns the match start and sets *matched to the spelling found;
 * elogs if neither is present.
 */
static const char *
find_dml_prefix(const char *orig_sql, const char *search_unqual,
                const char *search_qual, const char *vname,
                const char **matched)
{
    size_t      lu = strlen(search_unqual); /* nosemgrep */
    size_t      lq = strlen(search_qual);   /* nosemgrep */
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
        if (strncmp(p, search_unqual, lu) == 0) { *matched = search_unqual; return p; } /* nosemgrep */
        if (strncmp(p, search_qual,   lq) == 0) { *matched = search_qual;   return p; } /* nosemgrep */
    }

    elog(ERROR,
         "coldfront: cannot locate result relation \"%s\" in deparsed DML: %s",
         vname, orig_sql);
    *matched = NULL;
    return NULL; /* unreachable */
}

static void
deparse_and_find_prefix(Query *query, DeparseResult *dr)
{
    RangeTblEntry *rte;
    char          *vname, *ns;
    char           search_unqual[256], search_qual[256];
    const char    *matched, *at;

    dr->orig_sql = pg_get_querydef(query, false);
    {
        char *p;
        for (p = dr->orig_sql; *p; p++)
            if (*p == '\n' || *p == '\t') *p = ' ';
    }
    while (*dr->orig_sql == ' ')
        dr->orig_sql++;

    rte   = (RangeTblEntry *) list_nth(query->rtable, query->resultRelation - 1);
    vname = get_rel_name(rte->relid);
    ns    = get_namespace_name(get_rel_namespace(rte->relid));

    /*
     * pg_get_querydef quotes mixed-case / reserved identifiers; the search
     * prefix must match. quote_identifier returns the input unchanged when
     * no quoting is needed.
     */
    {
        const char *q_vname = quote_identifier(vname);
        const char *q_ns    = quote_identifier(ns);

        if (query->commandType == CMD_UPDATE)
        {
            snprintf(search_unqual, sizeof(search_unqual), "UPDATE %s ",    q_vname);
            snprintf(search_qual,   sizeof(search_qual),   "UPDATE %s.%s ", q_ns, q_vname);
            dr->verb = "UPDATE ";
        }
        else if (query->commandType == CMD_DELETE)
        {
            snprintf(search_unqual, sizeof(search_unqual), "DELETE FROM %s ",    q_vname);
            snprintf(search_qual,   sizeof(search_qual),   "DELETE FROM %s.%s ", q_ns, q_vname);
            dr->verb = "DELETE FROM ";
        }
        else /* CMD_INSERT */
        {
            snprintf(search_unqual, sizeof(search_unqual), "INSERT INTO %s ",    q_vname);
            snprintf(search_qual,   sizeof(search_qual),   "INSERT INTO %s.%s ", q_ns, q_vname);
            dr->verb = "INSERT INTO ";
        }
    }

    at = find_dml_prefix(dr->orig_sql, search_unqual, search_qual, vname, &matched);

    dr->head_len = (size_t) (at - dr->orig_sql);
    dr->rest     = at + strlen(matched); /* nosemgrep */
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
    appendStringInfo(&buf, "%s%s %s", dr->verb, info->hot_table, dr->rest);
    return buf.data;
}

/*
 * Build a DML string targeting info->iceberg_table, with PG-specific casts
 * normalised to DuckDB equivalents.  The caller is expected to have already
 * cleared query->returningList on a cloned Query before calling
 * deparse_and_find_prefix(), so no RETURNING clause appears in dr->rest.
 */
static char *
build_cold_dml(DeparseResult *dr, TieredViewInfo *info)
{
    StringInfoData buf;
    initStringInfo(&buf);
    appendBinaryStringInfo(&buf, dr->orig_sql, dr->head_len);  /* leading WITH, if any */
    appendStringInfo(&buf, "%s%s %s", dr->verb, info->iceberg_table, dr->rest);
    return normalize_casts_for_duckdb(buf.data);
}

/*
 * Render a deparsed cold DML string as the SQL-text argument that
 * coldfront._exec_iceberg_with_claim(table, sql) — or _tiered_insert_cold's
 * source — receives.
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
 * duckdb_target selects value rendering. true: the string reaches
 * duckdb.raw_query (emit_cold / emit_dual / the fast tiered-INSERT path), so it
 * mirrors the INSTEAD-OF trigger's DuckDB literals — bytea -> from_hex(%P$L) /
 * encode($K,'hex'); json/jsonb/interval -> %P$L / $K::text; else %P$L / $K.
 * false: the string is embedded in a PostgreSQL cursor by
 * coldfront._tiered_insert_cold (the slow IDENTITY-omit path), executed by PG
 * not DuckDB. Most params render as plain %P$L / $K (PG coerces by the column
 * type); bytea renders as decode(%P$L,'hex') / encode($K,'hex') so the projected
 * cursor column is a real bytea independent of the caller's bytea_output GUC (a
 * plain %L would quote it under the session bytea_output and corrupt under
 * 'escape'). from_hex (DuckDB-only) would be wrong here — PG has no from_hex().
 */
static char *
cold_sql_arg(const char *cold_dml, ColdParamSet *ps, bool duckdb_target)
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
                    if (t == BYTEAOID)
                        /* hex string — GUC-independent (the caller's bytea_output
                         * is irrelevant); both targets reconstruct the exact
                         * bytes: DuckDB via from_hex, PG via decode. */
                        appendStringInfo(&args, ", encode($%d,'hex')", id);
                    else if (duckdb_target &&
                             (t == JSONOID || t == JSONBOID || t == INTERVALOID))
                        appendStringInfo(&args, ", $%d::text", id);
                    else
                        appendStringInfo(&args, ", $%d", id);
                }
                if (t == BYTEAOID && duckdb_target)
                    appendStringInfo(&tmpl, "from_hex(%%%d$L)", pos_of_id[id - 1]);
                else if (t == BYTEAOID)
                    /* native PG (the _tiered_insert_cold cursor): rebuild a real
                     * bytea from the hex arg so the projected column is bytea
                     * regardless of the caller's bytea_output. */
                    appendStringInfo(&tmpl, "decode(%%%d$L,'hex')", pos_of_id[id - 1]);
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
 * duckdb.raw_query, and releases the claim after pg_duckdb's iceberg COMMIT via
 * the C XactCallback. Callers wrap it in a SELECT (top level) or in
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
cold_anchor_update(const char *cold_call_expr)
{
    StringInfoData buf;
    initStringInfo(&buf);
    appendStringInfo(&buf,
        "UPDATE coldfront._dummy_dml_target SET anchor = anchor WHERE %s IS NULL",
        cold_call_expr);
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
 * string for each non-result RTE_RELATION, and substitute every literal
 * occurrence in sql with `pglocal.<schema>.<table>`. The substitution is
 * textual; quote_identifier matches what pg_get_querydef emits, so the
 * search patterns line up exactly. False positives are theoretically
 * possible if a column or alias happens to match the qualified-name
 * literal — vanishingly rare in practice and we accept the risk.
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
    deparse_and_find_prefix(query, &dr);
    return build_hot_dml(&dr, info);
}

static char *
emit_cold(Query *query, TieredViewInfo *info, ColdParamSet *ps, bool in_plpgsql)
{
    DeparseResult  dr;
    List          *saved_returning;
    char          *cold_dml, *call;

    /*
     * Save / NIL / restore the returningList around deparse instead of
     * copyObject(query) — the deep-copy is hundreds of palloc'd nodes per
     * cold UPDATE/DELETE, all to flip one field. This is on the parser-stage
     * hot path, so it adds up under load.
     *
     * Provably safe: pg_get_querydef's only use of returningList is inside
     * get_update_query_def / get_delete_query_def / get_insert_query_def,
     * which read the list and call get_returning_clause to emit text. None
     * stash a pointer past the call — the deparse_context is stack-local
     * and dies when the function returns. Cold writes don't currently
     * return rows (v0.1 cosmetic limit), so we strip RETURNING at the
     * tree level.
     */
    saved_returning = query->returningList;
    query->returningList = NIL;
    deparse_and_find_prefix(query, &dr);
    query->returningList = saved_returning;

    cold_dml = build_cold_dml(&dr, info);

    /* INSERT … SELECT FROM pg_table needs each non-result PG-table
     * reference prefixed with pglocal. so DuckDB can resolve via the
     * postgres extension. UPDATE/DELETE never reference other PG tables
     * (the rtable has only the result view), so this loop is a no-op
     * for those verbs. INSERT … VALUES has no source rtable beyond the
     * VALUES_LIST RTE, so also a no-op. */
    if (query->commandType == CMD_INSERT)
        cold_dml = prefix_pg_tables_with_pglocal(query, cold_dml);

    /* ALL cold-tier writes — tiered and iceberg-only alike — go through the
     * bakery wrapper. Every iceberg snapshot commit posts to the same
     * Lakekeeper CAS, so two concurrent committers to the same table (a cold
     * UPDATE on a peer, the archiver, another backend) would collide on a 409
     * regardless of which rows they touch. _exec_iceberg_with_claim serializes
     * them; it self-selects the R-A bakery (multi-node mesh) or a local
     * advisory lock (vanilla single-node), so this is correct in every
     * deployment. (Tiered INSERT uses a separate path, emit_tiered_insert.) */
    call = cold_exec_call(info->iceberg_table, cold_sql_arg(cold_dml, ps, true));

    /* Cause 2: inside plpgsql the statement must be a DML (cold_anchor_update);
     * at top level keep the byte-identical SELECT shape. */
    if (in_plpgsql)
        return cold_anchor_update(call);
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
 * PG's, so ROLLBACK undoes both tiers (not crash-safe — orphaned S3 objects
 * on crash are Iceberg housekeeping's concern).
 *
 * The cold CTE is a SELECT (not DML), so PG would prune it as unreferenced
 * unless the outer query forces its execution.  We use a CROSS JOIN with
 * `cold` in the outer SELECT — see the body comment near the appendStringInfo
 * call for why MATERIALIZED alone would not be enough.
 *
 * The hot CTE must have RETURNING so the outer SELECT can consume its
 * output.  If the user's UPDATE/DELETE already has a RETURNING list we keep
 * theirs; otherwise we append RETURNING *.  Cold RETURNING is not supported
 * in v0.1, so the outer SELECT only ever shows hot rows.
 */
static char *
emit_dual(Query *query, TieredViewInfo *info, ColdParamSet *ps, bool in_plpgsql)
{
    DeparseResult  dr_hot, dr_cold;
    char          *hot_dml, *cold_dml, *call;
    bool           has_returning = (query->returningList != NIL);
    StringInfoData buf;
    List          *saved_returning;

    /* Hot side: deparse with RETURNING intact. */
    deparse_and_find_prefix(query, &dr_hot);
    hot_dml = build_hot_dml(&dr_hot, info);

    /*
     * Cold side: NIL the returningList just for this deparse, then restore.
     * Same safety argument as emit_cold — pg_get_querydef doesn't keep any
     * post-call references into the list, so the Query is bit-identical
     * after restoration. Saves a copyObject(query) per ambiguous UPDATE/
     * DELETE on a tiered view.
     */
    saved_returning = query->returningList;
    query->returningList = NIL;
    deparse_and_find_prefix(query, &dr_cold);
    query->returningList = saved_returning;
    cold_dml = build_cold_dml(&dr_cold, info);
    call = cold_exec_call(info->iceberg_table, cold_sql_arg(cold_dml, ps, true));

    initStringInfo(&buf);
    if (in_plpgsql)
    {
        /* Cause 2: the hot UPDATE/DELETE is the OUTER statement (DML tag ->
         * plpgsql accepts it); the cold call rides in a data-modifying WITH-CTE
         * (cold_anchor_update), which PG always runs to completion regardless of
         * references, so the cold write still happens when the hot side matches
         * no rows. We keep the user's RETURNING if any; cold RETURNING is not
         * supported in v0.1. */
        appendStringInfo(&buf, "WITH cold AS (%s) %s",
                         cold_anchor_update(call), hot_dml);
    }
    else
    {
        /* Top level (unchanged): the cold CTE is a SELECT, which PG would prune
         * as unreferenced — MATERIALIZED only prevents inlining — so a CROSS
         * JOIN with cold in the outer SELECT forces its execution while keeping
         * the row set equal to hot. The hot CTE is DML and always runs. */
        appendStringInfo(&buf,
            "WITH hot AS (%s%s)"
            ", cold AS (SELECT %s)"
            " SELECT h.* FROM hot h CROSS JOIN cold c",
            hot_dml,
            has_returning ? "" : " RETURNING *",
            call);
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
 * Build the cold-side SELECT list for the fast pglocal-streaming path,
 * projecting every underlying-table column in attnum order. DuckDB-
 * iceberg's INSERT is positional and rejects column lists, so we must
 * emit the full tuple.  For each underlying column:
 *
 *   - If it appears in the user's INSERT targetList → emit the bare
 *     identifier (gets value from `coldfront_src` alias).
 *   - Else if it has a DEFAULT expression → inline the DEFAULT text so
 *     DuckDB evaluates it (per-row for volatile defaults like now()).
 *   - Else → NULL::<type>.
 *
 * IDENTITY-omitted is handled upstream by tiered_insert_needs_loop()
 * routing to the slow loop; this fast path never sees that case.
 *
 * `hot_qualified` is the registry's hot_table value (e.g.
 * '"public"."_events"'). `targeted` is the user's targetList resnames.
 * Returns palloc'd CSV.
 */
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
 * Append one cold-SELECT projection element to `sel`: the bare identifier when
 * the column is in the user's targetList, else the inlined DEFAULT expression,
 * else NULL::<type>.
 */
static void
append_cold_projection(StringInfo sel, bool in_target, const char *attname,
                       const char *atttype, const char *default_expr)
{
    if (in_target)
        appendStringInfoString(sel, quote_identifier(attname));
    else if (default_expr != NULL)
        appendStringInfo(sel, "(%s)", default_expr);
    else
        appendStringInfo(sel, "NULL::%s", atttype);
}

static char *
build_cold_select_list(const char *hot_qualified, List *targeted)
{
    StringInfoData sql, sel;
    bool           first = true;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT a.attname, format_type(a.atttypid, a.atttypmod), "
        "       pg_get_expr(d.adbin, d.adrelid) AS default_expr "
        "FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum "
        "WHERE n.nspname = (parse_ident(%s))[1] "
        "AND c.relname = (parse_ident(%s))[2] "
        "AND a.attnum > 0 AND NOT a.attisdropped "
        "ORDER BY a.attnum",
        quote_literal_cstr(hot_qualified),
        quote_literal_cstr(hot_qualified));

    initStringInfo(&sel);
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        if (SPI_execute(sql.data, true, 0) == SPI_OK_SELECT && SPI_processed > 0)
        {
            MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);
            uint64        i;
            for (i = 0; i < SPI_processed; i++)
            {
                char *attname = SPI_getvalue(SPI_tuptable->vals[i],
                                             SPI_tuptable->tupdesc, 1);
                char *atttype = SPI_getvalue(SPI_tuptable->vals[i],
                                             SPI_tuptable->tupdesc, 2);
                char *default_expr = SPI_getvalue(SPI_tuptable->vals[i],
                                                  SPI_tuptable->tupdesc, 3);
                bool  in_target = name_in_list(targeted, attname);
                if (!first) appendStringInfoString(&sel, ", ");
                append_cold_projection(&sel, in_target, attname, atttype,
                                       default_expr);
                first = false;
            }
            MemoryContextSwitchTo(oldcxt);
        }
        SPI_finish();
    }
    return sel.data;
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
 * Returns true iff `info->hot_table` has an IDENTITY column whose name
 * is NOT in the user's targetList. That's the one subcase that needs
 * PG-side nextval injection per row (the sequence has to advance in PG
 * context to stay coherent with the hot side's auto-allocations).
 *
 * Other omissions — columns with DEFAULT clauses, or plain columns —
 * don't need the loop: the fast path's cold SELECT inlines DEFAULT
 * expressions for those, and falls back to NULL::<type> for plain
 * columns (matching PG's semantics for omitted columns with no DEFAULT).
 */
static bool
tiered_insert_needs_loop(Query *query, TieredViewInfo *info)
{
    StringInfoData sql;
    bool           result = false;

    if (info->hot_table == NULL) return false;
    if (SPI_connect() != SPI_OK_CONNECT) return false;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT a.attname "
        "FROM pg_attribute a "
        "JOIN pg_class c ON c.oid = a.attrelid "
        "JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname = (parse_ident(%s))[1] "
        "AND c.relname = (parse_ident(%s))[2] "
        "AND a.attidentity IN ('a','d') "
        "AND a.attnum > 0 AND NOT a.attisdropped "
        "LIMIT 1",
        quote_literal_cstr(info->hot_table),
        quote_literal_cstr(info->hot_table));

    if (SPI_execute(sql.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
    {
        char     *idcol = SPI_getvalue(SPI_tuptable->vals[0],
                                       SPI_tuptable->tupdesc, 1);
        ListCell *lc;
        bool      in_target = false;
        foreach(lc, query->targetList)
        {
            TargetEntry *tle = (TargetEntry *) lfirst(lc);
            if (!tle->resjunk && tle->resname != NULL
                && strcmp(tle->resname, idcol) == 0)
            {
                in_target = true;
                break;
            }
        }
        result = !in_target;
    }
    SPI_finish();
    return result;
}

/*
 * Build the hot-half DML: a full set-based PG INSERT into the hot table with
 * the hot filter (partition_col >= cutoff). Returns palloc'd.
 */
static char *
build_tiered_hot_dml(const char *hot_table, const char *col_list,
                     const char *source, const char *partition_col,
                     const char *cutoff_lit)
{
    StringInfoData hot;
    initStringInfo(&hot);
    appendStringInfo(&hot,
        "INSERT INTO %s (%s) "
        "SELECT %s FROM (%s) AS coldfront_src(%s) "
        "WHERE %s >= %s",
        hot_table, col_list,
        col_list, source, col_list,
        quote_identifier(partition_col), cutoff_lit);
    return hot.data;
}

/*
 * Build the slow-path cold call (IDENTITY-omitted case): the target-name
 * ARRAY[...] plus the coldfront._tiered_insert_cold(...) call. Its source SQL
 * runs in a PG cursor (executed by PG, not DuckDB), so params render as NATIVE
 * PG (duckdb_target=false): no from_hex/::text — PG coerces the literals by the
 * projected column types. Returns palloc'd.
 */
static char *
build_cold_loop_call(Query *query, const char *vschema, const char *vname,
                     const char *source, ColdParamSet *ps)
{
    StringInfoData target_arr;
    ListCell      *lc;
    bool           first = true;

    initStringInfo(&target_arr);
    appendStringInfoString(&target_arr, "ARRAY[");
    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);
        if (tle->resjunk || tle->resname == NULL) continue;
        if (!first) appendStringInfoString(&target_arr, ", ");
        appendStringInfoString(&target_arr, quote_literal_cstr(tle->resname));
        first = false;
    }
    appendStringInfoString(&target_arr, "]::text[]");

    /* _tiered_insert_cold embeds its source SQL in a PG cursor (executed by
     * PG, not DuckDB), so render params as NATIVE PG (duckdb_target=false):
     * no from_hex/::text — PG coerces the literals by the projected column
     * types. Its bigint result is never NULL, so the anchor matches 0 rows. */
    {
        StringInfoData callbuf;
        initStringInfo(&callbuf);
        appendStringInfo(&callbuf,
            "coldfront._tiered_insert_cold(%s, %s, %s, %s)",
            quote_literal_cstr(vschema),
            quote_literal_cstr(vname),
            target_arr.data,
            cold_sql_arg(source, ps, false));
        return callbuf.data;
    }
}

/*
 * Build the fast-path cold call (bulk pglocal stream). DuckDB-iceberg INSERT is
 * positional with no column list, so the cold SELECT projects every underlying
 * column in attnum order — NULL::<type> for any column the user omitted.
 * tiered_insert_needs_loop() routed all IDENTITY/DEFAULT-omission cases to the
 * slow path already, so this NULL-padding is honest. Returns palloc'd.
 */
static char *
build_cold_bulk_call(Query *query, TieredViewInfo *info, const char *source,
                     const char *col_list, const char *cutoff_lit,
                     ColdParamSet *ps)
{
    StringInfoData cold;
    char          *cold_select, *cold_pfx, *cold_norm;
    List          *targeted_names = NIL;
    ListCell      *lc;

    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);
        if (!tle->resjunk && tle->resname != NULL)
            targeted_names = lappend(targeted_names, tle->resname);
    }
    cold_select = build_cold_select_list(info->hot_table, targeted_names);

    initStringInfo(&cold);
    appendStringInfo(&cold,
        "INSERT INTO %s "
        "SELECT %s FROM (%s) AS coldfront_src(%s) "
        "WHERE %s < %s",
        info->iceberg_table,
        cold_select, source, col_list,
        quote_identifier(info->partition_col), cutoff_lit);
    cold_pfx  = prefix_pg_tables_with_pglocal(query, cold.data);
    cold_norm = normalize_casts_for_duckdb(cold_pfx);

    return cold_exec_call(info->iceberg_table, cold_sql_arg(cold_norm, ps, true));
}

/*
 * Wrap the hot DML and cold call into the final rewritten statement.
 *
 * Cause 2: in plpgsql the hot INSERT is the OUTER DML (plpgsql accepts it)
 * and the cold call rides in a data-modifying CTE that always runs to
 * completion; the old (hot_rows, cold_rows) report isn't available in that
 * shape. At top level keep the existing count-reporting shape unchanged
 * (fast/slow read the cold count differently). Returns palloc'd.
 */
static char *
wrap_tiered_result(bool in_plpgsql, bool need_loop, const char *hot_dml,
                   const char *call)
{
    StringInfoData buf;
    initStringInfo(&buf);
    if (in_plpgsql)
        appendStringInfo(&buf, "WITH cold_call AS (%s) %s",
                         cold_anchor_update(call), hot_dml);
    else if (need_loop)
        appendStringInfo(&buf,
            "WITH hot_ins AS MATERIALIZED (%s RETURNING 1), "
            "cold_call AS MATERIALIZED (SELECT %s AS n) "
            "SELECT (SELECT count(*) FROM hot_ins) AS hot_rows, "
            "       (SELECT n FROM cold_call) AS cold_rows",
            hot_dml, call);
    else
        appendStringInfo(&buf,
            "WITH hot_ins AS MATERIALIZED (%s RETURNING 1), "
            "cold_call AS MATERIALIZED (SELECT %s) "
            "SELECT (SELECT count(*) FROM hot_ins) AS hot_rows, "
            "       (SELECT count(*) FROM cold_call) AS cold_rows",
            hot_dml, call);
    return buf.data;
}

/*
 * emit_tiered_insert rewrites a tiered-view INSERT into a single SQL
 * statement that splits hot/cold by the partition-column watermark.
 *
 * Hot half is always plain PG: `INSERT INTO _events (cols) SELECT cols
 * FROM (source) AS s(cols) WHERE partition_col >= cutoff`. Set-based,
 * IDENTITY auto-fills, full PG speed.
 *
 * Cold half has two flavours, chosen at parse time:
 *
 *   (a) Bulk: `SELECT duckdb.raw_query('INSERT INTO ice... SELECT ...
 *       FROM (source-pglocal-prefixed) WHERE partition_col < cutoff')`.
 *       One raw_query per statement; DuckDB's postgres extension streams
 *       source rows over libpq. Used when no IDENTITY column exists or
 *       the user supplied an explicit value for it.
 *
 *   (b) plpgsql cold-loop: `SELECT coldfront._tiered_insert_cold(...)`.
 *       The helper opens a PG cursor, calls nextval() per cold row, and
 *       flushes batched raw_query INSERTs. Used only when the table has
 *       an IDENTITY column AND the user's INSERT omits it (so we have
 *       to mint ids server-side).
 *
 * Source is read twice — once PG-side for hot, once via either pglocal
 * (a) or the cold cursor (b) — sharing the same PG snapshot so the two
 * halves see consistent rows. RETURNING is not preserved; the rewritten
 * statement reports (hot_count, cold_count).
 */
static char *
emit_tiered_insert(Query *query, TieredViewInfo *info, ColdParamSet *ps, bool in_plpgsql)
{
    DeparseResult  dr;
    char          *col_list, *cutoff_lit, *hot_dml, *call;
    const char    *source, *vname, *vschema;
    List          *saved_returning;
    bool           need_loop;

    saved_returning = query->returningList;
    query->returningList = NIL;
    deparse_and_find_prefix(query, &dr);
    query->returningList = saved_returning;

    col_list   = insert_targetlist_collist(query);
    source     = skip_leading_collist(dr.rest);
    cutoff_lit = format_timestamptz_literal(info->cutoff);

    /* A leading WITH clause (dr.head_len bytes, before "INSERT INTO <view> ") must
     * reach both halves, which each read `source` inside a parenthesised derived
     * table. Fold it into source so its CTEs scope to that subquery on each engine
     * (PG hot, DuckDB cold) — no top-level WITH to merge. */
    if (dr.head_len > 0)
    {
        StringInfoData sb;
        initStringInfo(&sb);
        appendBinaryStringInfo(&sb, dr.orig_sql, dr.head_len);
        appendStringInfoString(&sb, source);
        source = sb.data;
    }

    {
        RangeTblEntry *rte = (RangeTblEntry *) list_nth(query->rtable,
                                                        query->resultRelation - 1);
        vname   = get_rel_name(rte->relid);
        vschema = get_namespace_name(get_rel_namespace(rte->relid));
    }

    need_loop = tiered_insert_needs_loop(query, info);

    hot_dml = build_tiered_hot_dml(info->hot_table, col_list, source,
                                   info->partition_col, cutoff_lit);

    if (need_loop)
        call = build_cold_loop_call(query, vschema, vname, source, ps);
    else
        call = build_cold_bulk_call(query, info, source, col_list,
                                    cutoff_lit, ps);

    return wrap_tiered_result(in_plpgsql, need_loop, hot_dml, call);
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
 * Refuse a RETURNING clause on any write that touches the cold tier.  The cold
 * tier cannot return affected rows: duckdb-iceberg's binder rejects RETURNING on
 * Iceberg writes ("not yet supported for updates of a Iceberg table"), and
 * pg_duckdb's only row-returning entry point (duckdb.query) is SELECT-only.
 * Erroring here is honest — the alternative is silently returning hot rows only
 * (dual), a void internal row (cold), or nothing (tiered INSERT).  Hot-only DML
 * keeps RETURNING (it is plain PG DML); this is called only on the cold/dual
 * paths.  Revisit when duckdb-iceberg adds RETURNING on writes (see BACKLOG §4).
 */
static void
reject_cold_returning(Query *query, const char *vname)
{
    if (query->returningList != NIL)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("RETURNING is not supported for writes to the cold tier of \"%s\"", vname),
                 errhint("The cold tier (Iceberg) cannot return affected rows — duckdb-iceberg "
                         "does not support RETURNING on writes. Re-run without RETURNING.")));
}

/*
 * Build the rewritten SQL for a tiered-view INSERT (bulk split-by-watermark).
 * Tiered without a watermark yet (no archive run): everything is hot; emit a
 * plain hot INSERT. With a watermark, some rows go cold (cannot RETURN them).
 */
static char *
cf_emit_tiered_insert_path(Query *query, TieredViewInfo *info, ColdParamSet *ps,
                           bool in_plpgsql, const char *vname)
{
    if (!info->has_cutoff)
        return emit_hot(query, info);

    /* A watermark-split INSERT sends some rows to the cold tier,
     * which cannot return them — refuse RETURNING rather than drop it. */
    reject_cold_returning(query, vname);
    ensure_ice_attached_once();
    /* The fast cold path streams source rows via pglocal —
     * needs the postgres ATTACH. The plpgsql cold-loop fast
     * path doesn't, but the call is cheap when not needed
     * (and a no-op if coldfront.local_pg_dsn is unset). */
    if (query_has_pg_source_table(query))
        ensure_pg_attached_via_spi();
    /* Mixed-tier writes inside one PG tx (PG INSERT into _events
     * plus DuckDB raw_query for ice) need pg_duckdb's mixed-
     * write guard relaxed. */
    (void) set_config_option("duckdb.unsafe_allow_mixed_transactions",
                             "on",
                             PGC_USERSET, PGC_S_SESSION,
                             GUC_ACTION_LOCAL, true, 0, false);
    return emit_tiered_insert(query, info, ps, in_plpgsql);
}

/* Build the rewritten SQL for a cold-tier UPDATE/DELETE/INSERT (TIER_COLD). */
static char *
cf_emit_cold_path(Query *query, TieredViewInfo *info, ColdParamSet *ps,
                  bool in_plpgsql, const char *vname)
{
    reject_cold_returning(query, vname);
    ensure_ice_attached_once();
    /* INSERT … SELECT FROM pg_source needs pglocal. Walk the
     * rtable; if any non-result RTE_RELATION is present, the
     * deparsed SELECT will reference it and DuckDB will need
     * pglocal to resolve it. We skip the ATTACH call entirely
     * for VALUES inserts and for INSERT … SELECT from
     * generate_series / read_parquet / etc., because those
     * work in pure DuckDB context and the ATTACH itself
     * triggers a libpq-linkage error on some pg_duckdb builds
     * (the pglocal-loopback / postgres-extension recursion noted
     * on coldfront.ensure_pg_attached). */
    if (query->commandType == CMD_INSERT &&
        query_has_pg_source_table(query))
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
 * planning the whole iceberg_scan UNION in DuckDB. The reparse re-resolves column
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
 * jsonb → json on the read path. A query against a tiered / iceberg-only view runs
 * entirely in DuckDB (the view body is an iceberg_scan UNION), and DuckDB has no
 * jsonb type. Deparse, apply the read whitelist (normalize_jsonb_for_read: the
 * ::jsonb cast and the functions verified equivalent in both engines), reparse in
 * place. No whitelisted token ⇒ strcmp matches and the query is left untouched (the
 * common case — ->>/-> operators and plain reads never reparse). jsonb spellings
 * outside the whitelist pass through and DuckDB rejects them clearly (documented).
 */
static void
cf_normalize_read_jsonb(Query *query)
{
    char         *sql  = pg_get_querydef(query, false);
    char         *norm = normalize_jsonb_for_read(sql);
    ColdParamSet  ps;

    if (strcmp(sql, norm) == 0)  /* nosemgrep */
        return;
    collect_cold_params(query, &ps);
    cf_reparse_and_replace(query, norm, &ps);
}

/*
 * Read path for a SELECT that touches a registered tiered view. First try to
 * reroute a provably-hot read to the heap (runs in plain PG). Otherwise the read
 * spans the cold tier: lazily attach 'ice' (once per session) so the view body's
 * iceberg_scan('ice...') resolves — the version-agnostic cold-read attach (PG
 * 16/17/18) — and normalize the whitelisted jsonb spellings so DuckDB (which runs
 * the whole view query) accepts them. The relkind check inside
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
    cf_normalize_read_jsonb(query);
}

/*
 * Resolve the DML target: decide whether `query` is an INSERT/UPDATE/DELETE on
 * a registered tiered view that this hook should rewrite. On the read path
 * (SELECT touching a tiered view) it lazily attaches 'ice' and returns false.
 * Returns true with *rte and *info populated when a rewrite is warranted.
 */
static bool
cf_resolve_tiered_dml_target(Query *query, RangeTblEntry **rte,
                             TieredViewInfo *info)
{
    /* Intercept INSERT, UPDATE and DELETE on registered tiered views.
     * INSERT only goes through the bulk-rewrite path for iceberg-only
     * views — tiered views still use their per-row INSTEAD OF trigger
     * because INSERT has no WHERE clause to classify by tier. */
    if (query->commandType != CMD_UPDATE &&
        query->commandType != CMD_DELETE &&
        query->commandType != CMD_INSERT)
    {
        cf_maybe_attach_for_read(query);
        return false;
    }

    if (query->resultRelation == 0)
        return false;

    *rte = (RangeTblEntry *) list_nth(query->rtable, query->resultRelation - 1);
    if ((*rte)->rtekind != RTE_RELATION)
        return false;
    if (get_rel_relkind((*rte)->relid) != RELKIND_VIEW)
        return false;

    /* Check the catalog — only rewrite registered tiered views */
    if (!lookup_tiered_view((*rte)->relid, get_rel_name((*rte)->relid), info))
        return false;

    return true;
}

/*
 * Reject a multi-reference UPDATE/DELETE on a tiered view. The deparse-and-swap
 * rewrite substitutes only the leading result-relation reference. A second
 * reference to the SAME tiered view — a self-join (UPDATE … FROM v), DELETE …
 * USING v, or a sub-select (… WHERE id IN (SELECT … FROM v)) — would be copied
 * through verbatim and then fail confusingly (PG cannot scan the iceberg_scan
 * view; DuckDB does not know it). Reject it cleanly here; a structural
 * multi-reference rewrite is out of scope. (INSERT … SELECT routing is handled
 * separately by emit_tiered_insert.)
 */
static void
cf_reject_multi_reference(Query *query, RangeTblEntry *rte)
{
    if ((query->commandType == CMD_UPDATE || query->commandType == CMD_DELETE) &&
        count_tiered_view_refs(query, rte->relid) > 1)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("UPDATE/DELETE on tiered view \"%s\" cannot reference it more than once",
                        get_rel_name(rte->relid)),
                 errhint("Self-joins, USING, and sub-selects over the same tiered view "
                         "are not supported; reference it once.")));
}

/*
 * Reject an UPDATE that assigns the partition column of a tiered view. Changing
 * the partition column can move the row across the hot/cold cutoff; the in-place
 * rewrite (hot, cold, or dual) updates the row where it already lives, so a moved
 * row stays physically in its old tier while the view's tier predicate
 * (ts >= cutoff / r[ts] < cutoff) filters it out — a silent disappearance
 * (GitHub #20). Relocating the row across tiers is a separate, unimplemented
 * feature; until then the partition column is read-only through the view. The
 * targetList here is post-parse-analyze, so it holds exactly the SET-assigned
 * columns (plus resjunk entries we skip) — not the full row. Blocks any assignment
 * regardless of the new value's tier or coldfront.allow_mixed_writes: with no move
 * to permit, allowing it would just reinstate the loss.
 */
static void
cf_reject_partition_col_update(Query *query, RangeTblEntry *rte,
                               TieredViewInfo *info)
{
    AttrNumber  partcol_attno;
    ListCell   *lc;

    if (query->commandType != CMD_UPDATE || info->partition_col == NULL)
        return;

    partcol_attno = get_attnum(rte->relid, info->partition_col);
    if (partcol_attno == InvalidAttrNumber)
        return;

    foreach(lc, query->targetList)
    {
        TargetEntry *tle = (TargetEntry *) lfirst(lc);

        if (tle->resjunk)
            continue;
        if (tle->resno == partcol_attno)
            ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("UPDATE of partition column \"%s\" on tiered view \"%s\" is not supported",
                            info->partition_col, get_rel_name(rte->relid)),
                     errhint("Changing \"%s\" can move the row across the hot/cold "
                             "boundary; that relocation is not yet supported. To "
                             "change \"%s\", delete the row and re-insert it with "
                             "the new value.",
                             info->partition_col, info->partition_col)));
    }
}

/*
 * Reject a multi-reference UPDATE/DELETE on a tiered view, then pick the emit
 * path (tiered-INSERT split, hot, cold, or dual) and return the rewritten SQL.
 * Returns NULL on the unreachable default tier (caller treats as a no-op).
 */
static char *
cf_dispatch_emit(Query *query, RangeTblEntry *rte, TieredViewInfo *info,
                 ColdParamSet *ps, bool in_plpgsql, const char *vname)
{
    TierClass tier;

    cf_reject_multi_reference(query, rte);
    cf_reject_partition_col_update(query, rte, info);

    /* Tiered-view INSERT: bulk split-by-watermark via emit_tiered_insert.
     * Iceberg-only INSERT falls through to the unconditional cold path
     * (classify_tier short-circuits to TIER_COLD for iceberg-only). */
    if (query->commandType == CMD_INSERT && !info->is_iceberg_only)
        return cf_emit_tiered_insert_path(query, info, ps, in_plpgsql, vname);

    tier = classify_tier(query, info);

    if (tier == TIER_HOT)
        return emit_hot(query, info);
    if (tier == TIER_COLD)
        return cf_emit_cold_path(query, info, ps, in_plpgsql, vname);
    if (tier == TIER_AMBIGUOUS)
        return cf_emit_dual_path(query, info, ps, in_plpgsql, vname);
    return NULL;        /* unreachable */
}

/* ---------- hook -------------------------------------------------------- */

/*
 * The coldfront post-parse-analyze hook: rewrite INSERT/UPDATE/DELETE on a
 * registered tiered view to the hot/cold/dual emit path.
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
    TieredViewInfo  info;
    char           *new_sql;
    RangeTblEntry  *rte;
    ColdParamSet    ps;
    bool            in_plpgsql;
    const char     *vname;

    /* Chain to any previous hook first */
    if (prev_post_parse_analyze_hook)
        prev_post_parse_analyze_hook(pstate, query, jstate);

    /* Re-entrancy guard */
    if (coldfront_in_rewrite)
        return;

    if (!coldfront_registry_present())
        return;

    if (!cf_resolve_tiered_dml_target(query, &rte, &info))
        return;

    vname = get_rel_name(rte->relid);

    /* Bound params ($N) from a plpgsql / DO / PREPARE / extended-protocol
     * caller, collected once (Cause 1). in_plpgsql gates the Cause-2
     * statement shape — plpgsql installs p_post_columnref_hook on the
     * ParseState; top-level (even parameterized) does not. See the
     * architecture block at the top of this file and the
     * coldfront._dummy_dml_target comment in coldfront--1.0.sql. */
    collect_cold_params(query, &ps);
    in_plpgsql = (pstate->p_post_columnref_hook != NULL);

    new_sql = cf_dispatch_emit(query, rte, &info, &ps, in_plpgsql, vname);
    if (new_sql == NULL)
        return;     /* unreachable default tier */

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
 * races into Lakekeeper alongside us — 409 / silent loss. Conversely,
 * releasing inside the same outer tx (so it's atomic with iceberg) makes
 * the release invisible to peers until commit, which is correct on COMMIT
 * but leaves a stale claim on ROLLBACK.
 *
 * The XactCallback runs after pg_duckdb's XactCallback (coldfront loads
 * after pg_duckdb in shared_preload_libraries; PG calls callbacks in
 * registration order), so on COMMIT the iceberg snapshot is durably
 * committed before we DELETE the claim. On ABORT, pg_duckdb has already
 * rolled back iceberg, and we still need to clean up our (committed-via-
 * dblink-autonomous-tx) claim row so the next writer doesn't block.
 *
 * Allocated in TopMemoryContext so it survives across PG xacts within one
 * backend session.
 */
static List *coldfront_pending_releases = NIL;

/* Persistent loopback libpq connection for the XactCallback drain. Opened
 * lazily on first need from the GUC coldfront.dblink_self, kept alive
 * across calls within one backend session. */
static PGconn *coldfront_release_conn = NULL;

static PGconn *
coldfront_release_get_conn(void)
{
    const char *connstr;

    if (coldfront_release_conn != NULL &&
        PQstatus(coldfront_release_conn) == CONNECTION_OK)
        return coldfront_release_conn;

    if (coldfront_release_conn != NULL)
    {
        PQfinish(coldfront_release_conn);
        coldfront_release_conn = NULL;
    }

    connstr = GetConfigOption("coldfront.dblink_self", true, false);
    if (connstr == NULL || connstr[0] == '\0')
    {
        elog(WARNING, "coldfront: dblink_self GUC unset; cannot release bakery claim");
        return NULL;
    }

    coldfront_release_conn = PQconnectdb(connstr);
    if (PQstatus(coldfront_release_conn) != CONNECTION_OK)
    {
        elog(WARNING, "coldfront: libpq connect for release failed: %s",
             PQerrorMessage(coldfront_release_conn));
        PQfinish(coldfront_release_conn);
        coldfront_release_conn = NULL;
        return NULL;
    }
    return coldfront_release_conn;
}

/*
 * Drain the per-session pending-release queue at outer-tx end. Runs after
 * pg_duckdb's XactCallback (registration-order chain), so on COMMIT the
 * iceberg snapshot has landed before we DELETE the claim, and on ABORT
 * pg_duckdb has already rolled back iceberg.
 *
 * We use libpq directly rather than SPI because SPI inside an
 * XACT_EVENT_COMMIT / XACT_EVENT_ABORT callback would try to start a
 * fresh PG transaction while the previous one is still finalizing — that
 * triggers PANIC ("cannot abort transaction N, it was already
 * committed"). libpq runs over its own TCP/loopback session and doesn't
 * touch the calling backend's xact state.
 */
/* cf_release_one_ticket runs one queued claim release over the libpq loopback:
 * an idempotent DELETE-by-ticket; a failure is a WARNING (not ERROR — we are
 * mid-finalize). Split out of coldfront_xact_callback to keep it readable. */
static void
cf_release_one_ticket(PGconn *conn, int64 ticket)
{
    char        query[160];
    PGresult   *res;

    snprintf(query, sizeof(query),
             "DELETE FROM coldfront.claims WHERE ticket = %lld",
             (long long) ticket);

    res = PQexec(conn, query);
    if (res == NULL ||
        (PQresultStatus(res) != PGRES_COMMAND_OK &&
         PQresultStatus(res) != PGRES_TUPLES_OK))
        elog(WARNING,
             "coldfront: release of ticket %lld via libpq failed: %s",
             (long long) ticket,
             res ? PQresultErrorMessage(res) : PQerrorMessage(conn));
    if (res != NULL)
        PQclear(res);
}

static void
coldfront_xact_callback(XactEvent event, void *arg)
{
    ListCell *lc;
    PGconn   *conn;

    if (event != XACT_EVENT_COMMIT && event != XACT_EVENT_ABORT)
        return;

    /* A lazy 'ice' ATTACH runs inside the user's transaction, so an abort rolls
     * the DuckDB ATTACH back.  Clear the once-per-session guard so the next
     * tiered-view query re-attaches.  Before the pending-release early-return
     * below (a read-only session has no releases queued). */
    if (event == XACT_EVENT_ABORT)
        coldfront_ice_attached = false;

    if (coldfront_pending_releases == NIL)
        return;

    conn = coldfront_release_get_conn();
    if (conn == NULL)
    {
        /* No connection — claims will be released on next bakery entry
         * by the idempotent DELETE-by-ticket. Drop the queue silently. */
        list_free_deep(coldfront_pending_releases);
        coldfront_pending_releases = NIL;
        return;
    }

    foreach(lc, coldfront_pending_releases)
        cf_release_one_ticket(conn, *((int64 *) lfirst(lc)));

    list_free_deep(coldfront_pending_releases);
    coldfront_pending_releases = NIL;
}

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
    char *iceberg_table;   /* DuckDB ref, e.g. ice.default.events */
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
    Oid nsoid = get_namespace_oid("coldfront", true);
    if (!OidIsValid(nsoid))
        return false;
    return OidIsValid(get_relname_relid("tiered_views", nsoid));
}

/*
 * Find the tiered registry row whose HOT table resolves to relid. Populates
 * *out (palloc'd in CurTransactionContext) and returns true on a match.
 *
 * Matching is done in SQL: to_regclass(hot_table)::oid = relid. to_regclass
 * resolves the stored quoted-qualified name schema-aware (never assumes a
 * schema), so this is correct regardless of search_path or the incoming
 * RangeVar's qualification. One query, no SPI_tuptable clobbering.
 */
static bool
lookup_tiered_by_hot_oid(Oid relid, TieredDDLInfo *out)
{
    bool           found = false;
    StringInfoData sql;

    if (!OidIsValid(relid))
        return false;
    if (SPI_connect() != SPI_OK_CONNECT)
        return false;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT schema_name, relname, hot_table, iceberg_table, partition_col "
        "FROM coldfront.tiered_views "
        "WHERE hot_table IS NOT NULL "
        "  AND to_regclass(hot_table)::oid = %u "
        "LIMIT 1",
        relid);

    if (SPI_execute(sql.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
    {
        MemoryContext oldcxt = MemoryContextSwitchTo(CurTransactionContext);
        char   *pc;
        out->view_schema   = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 1));
        out->view_relname  = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 2));
        out->hot_table     = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 3));
        out->iceberg_table = pstrdup(SPI_getvalue(SPI_tuptable->vals[0],
                                                  SPI_tuptable->tupdesc, 4));
        pc = SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 5);
        out->partition_col = pc ? pstrdup(pc) : NULL;
        MemoryContextSwitchTo(oldcxt);
        found = true;
    }

    pfree(sql.data);
    SPI_finish();
    return found;
}

/*
 * Returns true if relid is a registered tiered relation — either the hot table
 * or the transparent view. Used to block DROP/TRUNCATE on either side. Single
 * query, schema-safe via to_regclass (see lookup_tiered_by_hot_oid).
 */
static bool
relid_is_tiered(Oid relid)
{
    bool           found = false;
    StringInfoData sql;

    if (!OidIsValid(relid))
        return false;
    if (SPI_connect() != SPI_OK_CONNECT)
        return false;

    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT 1 FROM coldfront.tiered_views "
        "WHERE (schema_name = %s AND relname = %s) "
        "   OR (hot_table IS NOT NULL AND to_regclass(hot_table)::oid = %u) "
        "LIMIT 1",
        quote_literal_cstr(get_namespace_name(get_rel_namespace(relid))),
        quote_literal_cstr(get_rel_name(relid)),
        relid);
    if (SPI_execute(sql.data, true, 1) == SPI_OK_SELECT && SPI_processed == 1)
        found = true;
    pfree(sql.data);

    SPI_finish();
    return found;
}

/* Run one void-returning coldfront helper via SPI with up to two text args. */
static void
spi_exec_void(const char *sql)
{
    if (SPI_connect() == SPI_OK_CONNECT)
    {
        SPI_execute(sql, false, 0);
        SPI_finish();
    }
}

/* Rebuild the transparent view + INSERT trigger from current catalog state.
 * Used after a column-shape change (ADD/DROP/ALTER-TYPE/RENAME COLUMN, mirrored
 * onto Iceberg by mirror_and_rebuild) and after a hot-table or view RENAME. The
 * view's columns/types are derived from the hot heap, so it always reflects the
 * post-DDL shape. */
static void
rebuild_tiered_view(const char *schema, const char *relname)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql, "SELECT coldfront._rebuild_tiered_view(%s, %s)",
        quote_literal_cstr(schema), quote_literal_cstr(relname));
    spi_exec_void(sql.data);
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
    spi_exec_void(sql.data);
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
    spi_exec_void(sql.data);
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
 * terms, each {op, col[, newcol]}. Runs under the re-entrancy guard so the
 * SPI-issued DDL does not re-enter this hook. Any unsupported type raises inside
 * the mirror, rolling the whole statement (hot tier included) back atomically.
 */
static void
mirror_and_rebuild(const TieredDDLInfo *info, const char *actions)
{
    StringInfoData sql;
    initStringInfo(&sql);
    appendStringInfo(&sql,
        "SELECT coldfront._mirror_iceberg_alter(%s, %s, jsonb_build_array(%s))",
        quote_literal_cstr(info->iceberg_table),
        quote_literal_cstr(info->hot_table),
        actions);

    coldfront_in_utility = true;
    PG_TRY();
    {
        spi_exec_void(sql.data);
        rebuild_tiered_view(info->view_schema, info->view_relname);
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
            if (relid_is_tiered(relid))
            {
                char *ns   = get_namespace_name(get_rel_namespace(relid));
                char *name = get_rel_name(relid);
                ereport(ERROR,
                    (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                     errmsg("coldfront: cannot DROP \"%s.%s\" — it has a cold tier in Iceberg",
                            ns, name),
                     errhint("Blocked by design: the Iceberg cold tier would be orphaned. "
                             "Removing a tiered table is a deliberate operation — unregister "
                             "it from coldfront.tiered_views and drop each tier explicitly.")));
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
        if (relid_is_tiered(relid))
        {
            char *ns   = get_namespace_name(get_rel_namespace(relid));
            char *name = get_rel_name(relid);
            ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("coldfront: cannot TRUNCATE tiered table \"%s.%s\" — cold-tier rows would remain visible",
                        ns, name),
                 errhint("Blocked by design: cold-tier rows live in Iceberg and would remain "
                         "visible through the view. Truncate each tier explicitly.")));
        }
    }
    cf_call_through(u);
}

/* Collect the column-shape subcommands to mirror into *actions (the body of a
 * jsonb_build_array(...) call); ignore the rest. Returns the count collected. */
static int
cf_collect_alter_actions(AlterTableStmt *at, StringInfoData *actions)
{
    ListCell *lc;
    int       nacts = 0;

    initStringInfo(actions);
    foreach(lc, at->cmds)
    {
        AlterTableCmd *cmd = (AlterTableCmd *) lfirst(lc);
        const char    *op  = NULL;
        const char    *col = NULL;

        if (cmd->subtype == AT_AddColumn)
        {
            op  = "add";
            col = castNode(ColumnDef, cmd->def)->colname;
        }
        else if (cmd->subtype == AT_DropColumn)
        {
            op  = "drop";
            col = cmd->name;
        }
        else if (cmd->subtype == AT_AlterColumnType)
        {
            op  = "type";
            col = cmd->name;
        }
        if (op == NULL)
            continue;

        appendStringInfo(actions, "%sjsonb_build_object('op', %s, 'col', %s)",
                         nacts > 0 ? ", " : "",
                         quote_literal_cstr(op), quote_literal_cstr(col));
        nacts++;
    }
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
 * straight through untouched. */
static void
cf_handle_alter_table(const CfUtilityCtx *u, AlterTableStmt *at)
{
    Oid             relid = RangeVarGetRelid(at->relation, NoLock, true);
    TieredDDLInfo   info;
    StringInfoData  actions;
    int             nacts;

    if (!lookup_tiered_by_hot_oid(relid, &info))
    {
        cf_call_through(u);
        return;
    }

    nacts = cf_collect_alter_actions(at, &actions);

    if (nacts == 0)
    {
        /* No column-shape change → partition management / storage params /
         * the archiver's DETACH. Not coldfront's business. */
        pfree(actions.data);
        cf_call_through(u);
        return;
    }

    /* The transparent view projects the hot columns, so PG blocks a hot-side
     * DROP COLUMN / ALTER COLUMN TYPE of a projected column ("used by a
     * view"). Drop the view first, run the hot ALTER, then mirror the change
     * onto Iceberg and rebuild the view. One transaction: an unsupported
     * column type (or any failure) raises inside the mirror and rolls the
     * whole statement — view drop and hot change included — back atomically. */
    drop_tiered_view(info.view_schema, info.view_relname);
    cf_call_through(u);
    mirror_and_rebuild(&info, actions.data);
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
        if (relid_is_tiered(*view_relid))
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
 * reads keep resolving it by name. A column rename targeting the generated VIEW
 * is meaningless (the rebuild owns the view's column names) and is rejected. */
static void
cf_handle_rename_column(const CfUtilityCtx *u, RenameStmt *rs,
                        TieredDDLInfo *info, bool via_hot, Oid view_relid)
{
    StringInfoData acts;

    if (!via_hot)
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

    cf_call_through(u);   /* PG renames the hot column */
    initStringInfo(&acts);
    appendStringInfo(&acts,
        "jsonb_build_object('op', 'rename', 'col', %s, 'newcol', %s)",
        quote_literal_cstr(rs->subname), quote_literal_cstr(rs->newname));
    mirror_and_rebuild(info, acts.data);
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
            rebuild_tiered_view(info->view_schema, info->view_relname);
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
            rebuild_tiered_view(info->view_schema, rs->newname);
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

/*
 * The coldfront ProcessUtility_hook. Intercepts DDL on registered tiered
 * relations: blocks DROP/TRUNCATE, mirrors schema/rename DDL to Iceberg, and
 * rebuilds the transparent view. Everything else passes straight through.
 *
 * Spock apply worker: the DDL the hook ACTS on for a tiered table is
 * DROP/TRUNCATE (blocked — never replicated, they error on the originator),
 * column DDL (ADD/DROP/ALTER-TYPE/RENAME COLUMN — mirrored to Iceberg), and
 * RENAME TABLE/VIEW. A replicated statement re-runs in the peer's apply
 * worker; the hook then does the peer's LOCAL registry update + view
 * rebuild, which is exactly right because the registry/view are per-node
 * (not Spock-replicated). The Iceberg cold tier, by contrast, is SHARED
 * (one Lakekeeper), so its column DDL must run exactly once: the mirror
 * (coldfront._mirror_iceberg_alter) self-skips when
 * session_replication_role = replica, leaving the apply worker to rebuild
 * its local view only. The SPI-issued mirror/rebuild DDL runs at
 * non-top-level context, which Spock filters out, so it never re-replicates.
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
        "Rows per cold-tier Iceberg flush batch in coldfront._tiered_insert_cold.",
        "Each batch_size rows the tiered INSERT flushes one duckdb.raw_query — one "
        "Iceberg append / Parquet file. Larger means fewer, bigger files; the "
        "trailing remainder always flushes, so a small write stays a single file.",
        &coldfront_cold_write_batch_size,
        10000,              /* boot_val */
        1,                  /* min */
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
}

void
_PG_init(void)
{
    register_gucs();

    prev_post_parse_analyze_hook = post_parse_analyze_hook;
    post_parse_analyze_hook      = coldfront_post_parse_analyze;

    /* DDL synchronization for tiered tables. Chains pg_duckdb's
     * ProcessUtility_hook (coldfront loads later, so prev == pg_duckdb's). */
    prev_process_utility_hook = ProcessUtility_hook;
    ProcessUtility_hook       = coldfront_process_utility;

    /* Register the bakery release-deferral callback. Runs after pg_duckdb's
     * XactCallback (coldfront appears later in shared_preload_libraries, so
     * its _PG_init runs after pg_duckdb's, so its XactCallback is invoked
     * later in PG's registration-ordered chain). */
    RegisterXactCallback(coldfront_xact_callback, NULL);
}
