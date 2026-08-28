# coldfront extension — regression tests (`pg_regress`)

These are the **coldfront extension's** regression tests, run by PostgreSQL's
`pg_regress` driver via the standard PGXS path (`make installcheck`, with the
`REGRESS = …` list in [`../Makefile`](../Makefile)).

They are **not** PostgreSQL's own ~200-test core suite (`src/test/regress`, which
tests Postgres itself), and they are **not** the end-to-end suite — that is
[`ci/journey.sh`](../../../ci/journey.sh), driven across the deployment matrix by
`ci/matrix.sh`.

## What this layer is: white-box checks of the two C hooks (plus SQL unit tests)

Most tests register a tiered / iceberg-only view (by inserting a
`coldfront.tiered_views` row directly - see *Scaffolding* below) and then
exercise **one** hook behavior; the rest are plain SQL unit tests of the
extension's non-hook surface (third table below) and register no view.

### `post_parse_analyze_hook` — the DML rewrite (verified with `EXPLAIN`)

| test | checks |
|---|---|
| `update_hot_via_view` | hot-tier UPDATE → plain PG DML on `_events` (also executed) |
| `update_cold_via_view` | cold-tier UPDATE → `SELECT _exec_iceberg_with_claim('…UPDATE ice…')` |
| `allow_mixed_writes` | ambiguous predicate → dual-tier CTE (permissive mode) |
| `update_ambiguous_rejected` | ambiguous predicate + strict mode → error with hint |
| `update_partition_key_blocked` | strict mode: UPDATE assigning the partition column → error, whichever tier the WHERE selects |
| `update_partition_key_move` | permissive mode: partition-key UPDATE → a single `_cross_tier_move(...)` call relocating rows across the cutoff |
| `classify_between_in_or` | `BETWEEN` / `IN` / `OR` predicate → correct tier classification |
| `classify_now` | STABLE `now()`-relative bound folded to a single tier; VOLATILE (`clock_timestamp()`) stays ambiguous |
| `returning_literal_in_where` | `RETURNING` / literal-in-WHERE handling in the rewrite |
| `returning_cold_rejected` | `RETURNING` on any write touching the cold tier → clear error; hot-only DML keeps it |
| `cast_literal_in_value`, `cast_in_dquoted_identifier` | `::type` casts inside string literals survive the rewrite |
| `cast_normalize` | rewritten cold SQL carries the DuckDB spellings (`::timestamp`/`::varchar`/`::double`, `json_object`/`json_set`, `::json`) |
| `dollar_quote_in_value` | dollar-quoted values survive the rewrite |
| `mixed_case_identifier` | quoted mixed-case relation/column names survive the rewrite |
| `bad_tablename` | cold INSERT … SELECT prefixing rewrites only the real FROM reference, never the same name inside a string literal |
| `cte_on_dml` | leading `WITH` on UPDATE/DELETE: result relation found past the preamble, CTE carried through verbatim |
| `cte_on_insert` | leading `WITH` on INSERT folded into the row source so the CTE reaches both tiers |
| `param_cold_via_plpgsql` | bound params (`$N`) in a cold write stay live: the cold SQL is emitted as a runtime `format(...)` |
| `self_join_rejected` | a second reference to the tiered view (self-join / `USING` / sub-select) rejected at parse-analyze |
| `bakery_wraps_cold_writes` | every cold write funnels through `_exec_iceberg_with_claim` |
| `update_unregistered_view`, `update_heap_table` | unregistered / non-tiered relations pass through untouched |
| `read_date_bin` | a read that DuckDB will run has `date_bin` rewritten to `time_bucket` (DuckDB executes it against the heap and agrees with `date_bin`); a hot-rerouted read and a look-alike function name are left alone |
| `read_json_builders` | `jsonb_build_object` / `jsonb_agg` (and the `json_` twins) on a read that DuckDB will run become the `concat` / `to_json` / `array_agg` form; the result is JSON-equal to jsonb's rendering, keeps `ORDER BY` / `FILTER`, still takes `->>`, is rewritten below the top level too, and DuckDB executes it |
| `registry_snapshot` | the per-statement registry snapshot stays fresh within a transaction: a registration or a moved watermark from an earlier statement of the same transaction is seen by the next one, and a statement naming several views finds the registered one and leaves the others alone |

### `planner_hook`: bound parameters on a tiered read (executed)

| test | checks |
|---|---|
| `read_param_fold` | `$N` values are folded into the read before pg_duckdb plans it when a parameter sits where DuckDB cannot type a placeholder (`time_bucket`'s origin, every `generate_series` argument), through seven executions of a prepared statement and of a plpgsql query, so the plan cache's generic-plan attempt after the fifth never reaches DuckDB; a literal-only read and a parameter DuckDB types from context (`ts > $1`, which keeps its generic plan) are untouched |

### `ProcessUtility_hook` — DDL gating (executed)

| test | checks |
|---|---|
| `ddl_alter_column` | `ADD`/`DROP COLUMN`, `ALTER COLUMN … TYPE`, `RENAME COLUMN` mirrored onto the Iceberg tier (through the bakery) and the view rebuilt; unsupported column types rejected up front |
| `ddl_block_drop`, `ddl_block_truncate` | `DROP` / `TRUNCATE` of a tiered relation blocked |
| `ddl_rename_table` | `RENAME TABLE` updates `tiered_views.hot_table`, rebuilds the view |
| `ddl_rename_view` | `RENAME VIEW` migrates the name-keyed registry + watermark rows, rebuilds |
| `ddl_partition_passthrough` | `DETACH PARTITION` (the archiver's own machinery) passes through |
| `ddl_noop_unregistered` | DDL on unregistered relations passes through |

### SQL unit tests (no hook, no view)

| test | checks |
|---|---|
| `load_order` | extension loads after pg_duckdb; catalog table exists; the `PGC_SUSET` GUCs are settable and readable |
| `cold_write_batch_size_guc` | `coldfront.cold_write_batch_size` GUC: default 10000, settable, lower bound 1 |
| `async_requires_patch` | `_iceberg_async_active()` is true only when BOTH the async flag and the patch marker are on; otherwise fails safe to the stock ordering |
| `storage_secret_azure` | `_build_storage_secret_opts` secret bodies (s3 + azure branches) and the azure connection-string setter |
| `privilege_model` | the privilege invariants that let a non-superuser app role run cold I/O (catalog introspection only) |
| `partition_config_interval` | `partition_config.hot_period` / `retention_period` are native `interval` columns: valid intervals stored canonically, non-intervals rejected at INSERT |

## Why `coldfront.warehouse = ''` here (and only here)

Fixtures that register a view blank `coldfront.warehouse` / `coldfront.lakekeeper_endpoint`.
**This is deliberate isolation, not a coverage shortcut.** These tests verify the
SQL the hooks *generate* and the DDL they *gate* — they do not touch Iceberg.
With the warehouse blanked, the hook never attaches a live catalog during
statement analysis, so the rewrite is checked **fast and deterministically** —
no live Lakekeeper / S3 dependency, no non-deterministic attach NOTICE in the
expected output.

**Real cold-tier reads and writes — against a live Lakekeeper + SeaweedFS,
writing real Parquet to real Iceberg and reading it back — are exercised
end-to-end by [`ci/journey.sh`](../../../ci/journey.sh)** (the matrix's
vanilla/mesh × tiered/decoupled cells). The split is intentional:

- **this layer** — white-box unit tests of hook *logic* (no Iceberg I/O);
- **the journey** — black-box E2E of real *behavior* (real Iceberg I/O).

So `warehouse=off` appears *only* in this white-box layer, and never as a stand-in
for real cold-tier coverage.

## Scaffolding note

Fixtures register a view by inserting a `coldfront.tiered_views` row (and, where a
cutoff matters, an `archive_watermark` row) directly, rather than running the
archiver — again because they test the hooks in isolation. The real provisioning
paths (the archiver's table-swap, `coldfront.create_iceberg_table()`) are
exercised by the journey.
