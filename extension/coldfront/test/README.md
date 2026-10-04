# coldfront extension — regression tests (`pg_regress`)

These are the **coldfront extension's** regression tests, run by PostgreSQL's
`pg_regress` driver via the standard PGXS path (`make installcheck`, with the
`REGRESS = …` list in [`../Makefile`](../Makefile)).

They are **not** PostgreSQL's own ~200-test core suite (`src/test/regress`,
which tests Postgres itself), and they are **not** the end-to-end suite — that
is [`ci/journey.sh`](../../../ci/journey.sh), driven across the deployment
matrix by `ci/matrix.sh`.

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
| `update_unregistered_view`, `update_heap_table` | unregistered / non-tiered relations pass through untouched; a role with no access to schema coldfront reads and writes through a view of its own |
| `read_date_bin` | a read that DuckDB will run has `date_bin` rewritten to `time_bucket` (DuckDB executes it against the heap and agrees with `date_bin`); a hot-rerouted read and a look-alike function name are left alone |
| `read_json_builders` | `jsonb_build_object` / `jsonb_agg` (and the `json_` twins) on a read that DuckDB will run become the `concat` / `to_json` / `array_agg` form; the result is JSON-equal to jsonb's rendering, keeps `ORDER BY` / `FILTER`, still takes `->>`, is rewritten below the top level too, and DuckDB executes it |
| `registry_snapshot` | the per-statement registry snapshot stays fresh within a transaction: a registration or a moved watermark from an earlier statement of the same transaction is seen by the next one, and a statement naming several views finds the registered one and leaves the others alone |
| `duckdb_temp_dir` | a backend's DuckDB spill path is its own subdirectory of the configured one, named after its PID and appended once; a session that sets the path itself keeps it, `RESET` returns to the backend's own, and the value survives a rollback |
| `adopt_read_only` | a registration with `is_writable = false` refuses INSERT, UPDATE and DELETE alike with the documented hint, while its reads and an armed registration's writes are untouched |

### `planner_hook`: bound parameters on a tiered read (executed)

| test | checks |
|---|---|
| `read_param_fold` | `$N` values are folded into the read before pg_duckdb plans it when a parameter sits where DuckDB cannot type a placeholder (`time_bucket`'s origin, every `generate_series` argument), through seven executions of a prepared statement and of a plpgsql query, so the plan cache's generic-plan attempt after the fifth never reaches DuckDB; a literal-only read and a parameter DuckDB types from context (`ts > $1`, which keeps its generic plan) are untouched |

### `ProcessUtility_hook` — DDL gating (executed)

| test | checks |
|---|---|
| `ddl_alter_column` | `ADD`/`DROP COLUMN`, `ALTER COLUMN … TYPE`, `RENAME COLUMN` mirrored onto the Iceberg tier (through the bakery) and the view rebuilt with the owner and table-level grants it had; unsupported column types rejected up front; a role holding the owner's privileges without `SET ROLE`, and a role owning the hot table but not the view, make the change without owning the view or holding `CREATE` on its schema, while a role owning neither is refused before anything changes; the caller's temporary domain named `text` takes no part in the rebuild, even when a fresh session compiles the rebuild beside it |
| `ddl_alter_decoupled` | the same four column changes on a decoupled table's view rebuild it from its own columns plus the change, with the owner, table-level grants and registration it had; a statement may carry several column changes, and only the owner may make one, a role with no access to schema coldfront being refused as a non-owner, while a role holding the owner's privileges without `SET ROLE` makes the change; a default, constraint, collation, storage option, `USING`, another subcommand beside a column change, an unmapped type, a vector column (added, dropped, renamed or retyped) and a read-only table are refused, and leave the view as it was |
| `ddl_block_drop`, `ddl_block_truncate` | `DROP` / `TRUNCATE` of a tiered relation blocked |
| `ddl_rename_table` | `RENAME TABLE` updates `tiered_views.hot_table`, rebuilds the view, also when the hot table's owner has no access to the view or to schema coldfront, and the view keeps its owner |
| `ddl_rename_view` | `RENAME VIEW` migrates the name-keyed registry + watermark rows, rebuilds, also when the view's owner has no access to schema coldfront, and the view keeps that owner |
| `ddl_partition_passthrough` | `DETACH PARTITION` (the archiver's own machinery) passes through |
| `ddl_noop_unregistered` | DDL on unregistered relations passes through, also for a role with no access to schema coldfront, whose own functions and temporary types take no part in the registry lookup |

### SQL unit tests (no hook, no view)

| test | checks |
|---|---|
| `load_order` | extension loads after pg_duckdb; catalog table exists; the `PGC_SUSET` GUCs are settable and readable |
| `cold_write_batch_size_guc` | `coldfront.cold_write_batch_size` GUC: default 10000, settable, lower bound 1 |
| `async_requires_patch` | `_iceberg_async_active()` is true only when BOTH the async flag and the patch marker are on; otherwise fails safe to the stock ordering |
| `storage_secret_azure` | `_build_storage_secret_opts` secret bodies (s3 + azure branches) and the azure connection-string setter |
| `privilege_model` | the privilege invariants that let a non-superuser app role run cold I/O (catalog introspection only) |
| `definer_search_path` | the `SECURITY DEFINER` helpers (`ensure_attached`, `ensure_pg_attached`, `_claim_iceberg_lock`) search the caller's temporary schema after `pg_catalog`, so a temporary domain named `text` that a role allowed to call them creates takes no part in them, and its `CHECK` never runs as the extension's owner |
| `partition_config_interval` | `partition_config.hot_period` / `retention_period` are native `interval` columns: valid intervals stored canonically, non-intervals rejected at INSERT |
| `type_map` | `_iceberg_storage_type` and `_iceberg_view_cast_type`, the map the archiver and `create_iceberg_table` both read, give every supported column's `format_type` its storage type and view cast, one-dimensional arrays included, and refuse the types, the arrays and the array spellings with no Iceberg mapping, naming the column when the caller passes it; pg_duckdb cannot read a `timestamptz[]` column (that refusal's reason) |
| `hot_guard` | pg_duckdb's scan reads a numeric `NaN` as 0, drops an array's lower bound, and refuses a value with fewer dimensions than its column declares (the guards' reasons); `_guard_hot_table` adds one `NOT VALID` check per `numeric`, `date`, `timestamp`, `timestamptz` and array column, idempotently, and the partitions inherit it; a long column name names its guard by a hash; `_validate_hot_guards` validates them under a `SHARE UPDATE EXCLUSIVE` lock and names the guard a stored row breaks; `NaN`, `infinity`, `-infinity`, an array that is not a one-dimensional list from 1, and such elements are refused on `INSERT` and `UPDATE`; a column declared with two dimensions is refused; a column added through the DDL hook gets its guard, validated by that `ALTER`, so a default the guard refuses fails it, while a guard the archiver has not validated yet is left waiting; a renamed column's guard takes the new name, so a column added under the old name gets its own; unregistering drops the guards |
| `adopt_type_map` | `_pg_type_from_iceberg` maps every DuckDB column type an adopted table can carry, lists included, refuses the rest by name (a list by its element's name, as DESCRIBE spells it), and agrees with `_iceberg_storage_type` on both spellings of a type |
| `array_cold_render` | `_render_cold_value` renders an array as a DuckDB list of its elements' own literals, exact for text a list cast would misread and for `bytea` under either `bytea_output`; `_cold_list` refuses an array that is not a one-dimensional list from 1, naming the column, or saying a bound parameter holds it; `_render_cold_param` renders a bound array parameter the same way; a tiered `INSERT`'s cold half checks each array column and a cold write renders an array parameter (`EXPLAIN VERBOSE`); pg_duckdb loses a numeric array's precision in `CREATE TABLE ... USING duckdb` (the archiver's `text[]` export's reason); `_move_pg_row_literal` turns a jsonb list back into PostgreSQL array text |
| `adopt_iceberg_table` | what adoption refuses before it reads a catalog (arguments, a PG schema that does not exist, a name already taken, a reference already registered, no catalog configured), the wrapper view and registry row it ends in, and its inverse `release_iceberg_table` |

## Why `coldfront.warehouse = ''` here (and only here)

Fixtures that register a view blank `coldfront.warehouse` /
`coldfront.lakekeeper_endpoint`. **This is deliberate isolation, not a coverage
shortcut.** These tests verify the SQL the hooks *generate* and the DDL they
*gate* — they do not touch Iceberg. With the warehouse blanked, the hook never
attaches a live catalog during statement analysis, so the rewrite is checked
**fast and deterministically** — no live Lakekeeper / S3 dependency, no
non-deterministic attach NOTICE in the expected output.

**Real cold-tier reads and writes — against a live Lakekeeper + SeaweedFS,
writing real Parquet to real Iceberg and reading it back — are exercised
end-to-end by [`ci/journey.sh`](../../../ci/journey.sh)** (the matrix's
vanilla/mesh × tiered/decoupled cells). The split is intentional:

- **this layer** — white-box unit tests of hook *logic* (no Iceberg I/O);
- **the journey** — black-box E2E of real *behavior* (real Iceberg I/O).

So `warehouse=off` appears *only* in this white-box layer, and never as a
stand-in for real cold-tier coverage.

## Scaffolding note

Fixtures register a view by inserting a `coldfront.tiered_views` row (and,
where a cutoff matters, an `archive_watermark` row) directly, rather than
running the archiver — again because they test the hooks in isolation. The real
provisioning paths (the archiver's table-swap,
`coldfront.create_iceberg_table()`) are exercised by the journey.
