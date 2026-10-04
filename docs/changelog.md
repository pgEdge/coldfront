# Changelog

All notable changes to pgEdge ColdFront will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/), and
this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-rc1] - 2026-09-28

### Added

- pgvector columns tier like any other column. The archiver writes them to
  Iceberg as `list<float>`, the tiered view keeps the pgvector query interface,
  and writes through the view work unchanged on both tiers. A table may have
  several vector columns, with the Iceberg file layout sorted for one of them.
- `coldfront.vector_train` clusters a vector column with k-means and assigns
  the cold rows to the clusters; a retrain without a new `nlist` keeps each
  centroid's identity and rewrites only the rows whose nearest centroid
  changed. Every cold write assigns each row to its nearest cluster, the
  compactor keeps that layout, and a nearest-neighbour search through the view
  reads the nearest clusters, `nlist` and `nprobe` being per-column settings,
  plus the rows that have no assignment. Grouped, aggregated, windowed and
  `DISTINCT` shapes are recognised; an unrecognised shape scans exactly.
  `coldfront.vector_status` reports cluster health.
- `coldfront.adopt_iceberg_table()` gives a table that already exists in the
  Iceberg catalog a PostgreSQL wrapper view and a registry row, so it reads
  like one ColdFront created. The schema comes from the catalog, and `p_types`
  restores a type Iceberg cannot record. Adoption is read-only unless
  `p_writable => true` arms the write path.
- `coldfront.release_iceberg_table()` hands an adopted table back: the wrapper
  view and the registry row go, and the Iceberg table keeps every row.
- Cold tables are partitioned. The archiver creates a tiered table's Iceberg
  table partitioned the way the hot table is, `month(ts)` or `day(ts)` on the
  time column, led by the LIST column of a two-level table, so each export is
  one partition and a query with a time filter skips the months outside it
  before reading anything.
- `coldfront.create_iceberg_table()` takes `p_partition_cols`, the partitioning
  as DuckDB's own `PARTITIONED BY` terms: `'{month(ts)}'`,
  `'{month(ts), region}'`, `'{"bucket(16, id)"}'`.
- Reads that DuckDB executes accept `date_bin` (rewritten to `time_bucket`),
  `jsonb_build_object` and `jsonb_agg` with their `json_` twins (`ORDER BY`,
  `FILTER` and `DISTINCT` kept), and bound parameters where DuckDB cannot type
  a placeholder. Such reads are planned from their values each execution, so
  `plan_cache_mode = force_generic_plan` cannot run them. A view named in a
  CTE, sub-select or set-operation branch is detected wherever it sits in the
  statement.
- The base image includes a fourth duckdb-iceberg patch, a port of upstream
  d3c3348271, so the month of a `timestamptz` partition column is its UTC month
  whatever the session's time zone.
- `--version` on the archiver, the partitioner and the compactor.
- `COPY <view> FROM` loads a tiered or decoupled table through its view. The
  rows take the same path as an `INSERT`, in batches of
  `coldfront.cold_write_batch_size` rows, with the identity values and defaults
  an `INSERT` would give them. `COPY ... WHERE` and the `FREEZE`, `ON_ERROR`,
  `REJECT_LIMIT` and `DEFAULT` options are refused.
- An `INSERT`, `UPDATE` or `DELETE` nested in a `WITH` entry, on a tiered or
  a decoupled view, goes through the same rewrite as a top-level one: the hot
  statement becomes the entry's body, and the rewrite's own entries (a tiered
  `INSERT`'s source and cold sink, a dual-tier write's cold half) join the
  statement's `WITH` list. With a watermark, `RETURNING` on a nested `INSERT`
  is refused, as on a top-level one; a hot `UPDATE` or `DELETE` keeps it.
- `MERGE INTO` a tiered or decoupled view, on PostgreSQL 17 and later. A
  tiered `MERGE` runs on the tier its `ON` condition bounds the partition
  column to, in PostgreSQL against the hot table or in DuckDB against the
  Iceberg table, and each `INSERT` action's row is checked to belong to that
  tier; a `MERGE` that bounds neither tier is refused. A decoupled `MERGE` runs
  in DuckDB. A `MERGE` nested in a `WITH` entry takes the same path as a
  nested `UPDATE` or `DELETE`.

### Changed

- The mesh bakery no longer needs the `dblink` extension. Claims, acks,
  releases and orphan reaping run over a libpq loopback connection that the
  extension opens from `coldfront.loopback_dsn`, which must name a unix socket.
  A node that runs Spock refuses cold writes until that setting and
  `snowflake.node` are set, instead of serializing them on the node-local
  lock.
- `coldfront.tiered_views` has an `is_writable` column and a unique constraint
  on `iceberg_table`. Every existing registration is writable, and one relation
  is registered per Iceberg table.
- `coldfront.drop_iceberg_table()` refuses a relation adopted read-only, and
  builds its catalog DDL from the stored Iceberg reference rather than from the
  PostgreSQL schema and table names.
- Registering a tiered table rejects a column whose type has no Iceberg
  mapping, instead of failing at the first archive cycle.
- A refusal of a column type with no Iceberg mapping names the column, whether
  it comes from registration, an archive pass, `create_iceberg_table()` or an
  `ALTER TABLE` on a tiered table.
- The walkthrough's distributed demo shows the bakery at work on one held
  write: the ticket on the writing node, the same claim on its peer, the peer's
  ack, and the ledger cleared once the write commits. After the concurrent
  writes it lists the table's snapshot history.
- Every `coldfront.*` setting is registered: typed, bounded, with its default
  visible in `pg_settings`, and the prefix is reserved, so a mistyped name is
  refused. `coldfront.peer_alive_window_ms` and the build marker
  `coldfront.iceberg_bakery_patch` are superuser-only;
  `coldfront.iceberg_async_parquet` stays session-settable.
- One call, `coldfront.ensure_replicated()`, is the per-node mesh setup step.
  It puts every ColdFront table that replicates by value in the node's default
  replication set: the bakery's claims and acks, the registry and watermark,
  the storage secret, the lifecycle config and the vector routing state. It
  replaces `_ensure_claims_replicated()`, `_ensure_vector_state_replicated()`
  and the `spock.repset_add_table` calls the setup asked for by hand, and
  nothing calls it at run time.
- The archiver, the partitioner and the compactor connect from the libpq
  environment or `--dsn`, as psql does, and read everything else from the
  server: the tables from `coldfront.partition_config`, the cold-store
  credential from `coldfront.storage_secret` and the catalog from the
  `coldfront.warehouse` and `coldfront.lakekeeper_endpoint` settings. A
  deployment YAML is written into the server once with `import`, which also
  takes its `s3:` or `azure:` stanza through `set_storage_secret`; a YAML
  passed to any other run is checked against the server, value by value, and
  refused if it disagrees. The compactor takes no YAML.

- The bakery's dead-peer window `coldfront.peer_alive_window_ms` defaults to
  10 s and is set together with `wal_sender_timeout`: the walsender asks a
  peer for a reply every half of that timeout, so a claim refuses to run
  unless the timeout is positive and below twice the window, naming both. The
  image sets `wal_sender_timeout = 15s`. A peer counts as alive while its
  walsender has a reply inside the window, whatever the walsender's state, so
  a peer that has just reconnected is waited for rather than ruled dead.

### Fixed

- A deployment YAML could name a warehouse other than the server's: the
  archiver ignored the file's `iceberg.*` keys, the compactor acted on them,
  and a file with both an `s3:` and an `azure:` stanza was refused by the
  archiver and silently taken as Azure by the compactor. Both binaries now read
  the catalog and the store from the server, and a file that disagrees with it
  is refused.
- The archiver registered a tiered table as two statements, the view and then
  the registry row, so a mesh peer briefly had the view without the row its
  hook needs, and a write there failed. The registration is one transaction.
- A prepared `INSERT` into a tiered view whose source held a bound parameter
  inside a sub-select or a function in `FROM` failed with "there is no
  parameter $1". The parameter now carries through the rewrite wherever it
  sits.
- On a server that did not preload coldfront, `CREATE EXTENSION coldfront`
  succeeded and every session then ran without the extension's hooks: no write
  routing, no DDL mirroring, and no refusal of `DROP` or `TRUNCATE` on a tiered
  table. The extension now refuses to load outside `shared_preload_libraries`,
  so `CREATE EXTENSION` fails with an error that names the setting.
- A write that reached a tiered view through its `INSTEAD OF INSERT` trigger
  rather than the hook (a `COPY`, an `INSERT` nested in `WITH`, a session or a
  node without the hook) wrote cold rows with NULL identity and default values
  and without the table's claim. The trigger is gone: the hook is the only
  write path.
- A tiered `INSERT` whose `WITH` clause held an entry that modifies data
  (`WITH moved AS (DELETE … RETURNING …) INSERT INTO <view> SELECT … FROM
  moved`) failed with "`WITH` clause containing a data-modifying statement must
  be at the top level", because the rewrite folded the clause into its source
  sub-query. The clause's entries now open the rewritten statement. On a
  decoupled view, where the source runs in DuckDB, such an entry is refused
  with an error that says so instead of DuckDB's parser error.
- A tiered `INSERT` with a second `INSERT` into the same view nested in its
  `WITH` was rewritten into a statement with a syntax error. A statement that
  writes a tiered view more than once is now refused.
- A dual-tier `UPDATE` or `DELETE` with a leading `WITH` inside a plpgsql
  function or `DO` block failed with a syntax error, because the rewrite put
  its own `WITH` ahead of the statement's. The statement's entries now open
  the rewritten statement.
- A hot `UPDATE … FROM`, `DELETE … USING` or correlated sub-select on a
  tiered view failed with "missing FROM-clause entry" when the statement gave
  the view no alias, because the deparser qualifies the view's columns by its
  name and the rewrite swapped the relation alone. The retargeted relation now
  takes the view's name as its alias. A cold `UPDATE … FROM` or `DELETE …
  USING` a PostgreSQL table failed in DuckDB, which did not know the table; it
  is now read through `pglocal`, as an `INSERT`'s source is.
- A tiered `INSERT … SELECT` ran its source once per tier. A source whose
  rows differed between the two runs landed some rows in both tiers and others
  in neither, and when the hot table had no identity column, or the statement
  supplied one, a source table written earlier in the same transaction lost
  its cold rows, with no error either way. The source now runs once and both
  tiers read that result; an untyped literal in the source keeps the target
  column's type, and `OVERRIDING SYSTEM VALUE` works.
- On PostgreSQL 17 and 18, a transaction block in which a statement had failed
  could not be ended in a database with the extension: `ROLLBACK`, `COMMIT`
  and `ROLLBACK TO SAVEPOINT` failed with "ResourceOwnerEnlarge called after
  release started", and the session stayed in the failed transaction until it
  disconnected. They now end the block.
- On a mesh, a column change, a hot-table rename or a view rename on a tiered
  table failed to apply on the peers. Spock replicated the statement together
  with the view and registry changes the originating node's DDL hook made, and
  each peer's hook made them again, so the peers kept the old columns or name
  and stopped receiving the originating node's later writes. Only the
  statement replicates now, and each peer makes its own view and registry
  changes.
- The archiver gave two LIST values that map to the same child name, such as
  `eu-west` and `eu_west`, a single child, archived that child's oldest
  partition twice and failed the second cutover. It now refuses them before
  creating anything, as the partitioner did. `partitioner set --period` did not
  re-check the table name's length, so a name too long for daily partitions
  could be switched to daily. `set` now checks it when the period changes.
- After one cold write on a mesh, an app role could run any SQL as the loopback
  connection's user through the `coldfront_self` dblink connection the claim
  left open in its session, and by setting `coldfront.dblink_self` it could
  make the loopback run functions of its own as that user. An app role can no
  longer reach the loopback or set its connection string, and the loopback
  resolves names in `pg_catalog` only.
- The compactor read a table before taking its bakery claim. A run that had to
  wait for a cold write then had its commit refused and exited with an error,
  and an orphan-file pass with `--orphan-age 0s` could delete the files that
  write had just committed. Each step now reads the table under its claim.
- The compactor claimed a table made by `coldfront.create_iceberg_table()`
  under a different spelling of its Iceberg reference than the one cold writes
  to it claimed, so compaction and snapshot expiry did not wait for those
  writes. Every registration now stores the reference with each part quoted,
  which is how the archiver and the compactor spell it.
- On a server that has `output_plugin_libraries` (PostgreSQL 16.15, 17.11 and
  18.6), no Spock subscription could create its replication slot, because the
  setting's default leaves out `spock_output`. The Docker image adds
  `spock_output` to it on mesh nodes, and the per-node configuration in the
  usage guide lists it.
- Backends that shared one `duckdb.temporary_directory` overwrote each other's
  spill files, since DuckDB numbers them from zero per instance, and a backend
  whose DuckDB instance ended deleted its peers' spills. Each backend now
  spills into its own subdirectory of the configured path, and the files of a
  departed backend are removed.
- A transaction that made two cold writes to the same table on a mesh hung on
  its own first claim. A transaction now holds one claim per table.
- A writer terminated in the middle of its claim could leave a claim that the
  node's next writer on that table waited behind indefinitely.
- A cold write on a mesh that failed or was cancelled during its claim left an
  advisory lock held for the rest of the session, and the node's other writers
  on that table waited on it. Every lock the claim takes now ends with a
  transaction.
- A mesh session whose loopback connection had died failed every later cold
  write. The loopback now reconnects.
- `CREATE EXTENSION coldfront` failed on a database the standalone partitioner
  had already set up ("table partition_config is not a member of extension"):
  the extension now adopts that table, registrations included.
- The pg_duckdb packages for different PostgreSQL majors could not be installed
  side by side: each claimed the same build-id link for the bundled
  `libduckdb.so`. The RPMs contain no build-id links and the DEBs no longer
  produce dbgsym packages.
- `partitioner import` refused a file without a `postgres` section, which is
  what `export` writes, even with `--dsn` given. A tables-only file now
  imports, each table validated as tiered when it has a `hot_period` and as
  partition-only otherwise.
- The walkthrough's guide ran whatever archiver image an earlier run had built,
  because the `archiver` service sits behind a Compose profile that
  `up --build` skips. The guide now builds that image at bring-up.
- A read through a tiered view inside a transaction sees the transaction's own
  cold writes (`UPDATE`, `INSERT` and `DELETE`), and a cross-tier move finds a
  cold row the same transaction inserted. The view's cold branch and the
  move read the Iceberg table through the catalog's table entry
  (`duckdb.query`), as a decoupled view does; the plan is the same
  `ICEBERG_SCAN` with the same pushdown.
- The walkthrough's Lakekeeper database had no named volume, so `docker compose
  down` without `-v` kept the PostgreSQL and object-store data and lost the
  catalog: the next `up` had no warehouse and no table metadata. It has the
  `lkdata` volume, and the teardown text names it.
- The hint on a refused `TRUNCATE` of a tiered relation said to truncate each
  tier, a statement the same check refuses. It names what the check allows:
  the hot partitions one at a time and a `DELETE` through the view for the
  cold rows, or the `DELETE` alone for an iceberg-only view.
- The compactor's snapshot expiry reported its flags, not its result: the dry
  run ignored `--expire-older-than` and the real run printed the
  `--expire-retain-last` value as the kept count. Both now count the snapshots
  the expiry keeps, the dry run from the staged metadata.
- A nearest-neighbour search by negative inner product (`<#>`) on a tiered or
  decoupled view failed with "syntax error at or near >" whenever DuckDB ran
  it, since DuckDB has `<=>` and `<->` as operators of its own and no `<#>`.
  The read now spells it as the function DuckDB has under the same name,
  `list_negative_inner_product`; `<=>` and `<->` are unchanged.
- Once a `DROP COLUMN` returned a tiered table to an earlier schema, the next
  column change failed in the Iceberg mirror with "Attempted to add schema
  with id N, but this already exists in the table!" and rolled back the
  hot-side change with it, because duckdb-iceberg numbered each new schema one
  above the current one. The base image's fifth duckdb-iceberg patch, a port
  of upstream c1cfe2ef, numbers it above the highest schema id in the
  metadata.
- A compaction removed the delete files of data files it left alone, so the
  rows deleted from those files came back. iceberg-go removes every delete file
  attached to a file it rewrites, and duckdb-iceberg on DuckDB 1.5 writes no
  `referenced_data_file` for a delete file, so iceberg-go attaches each one to
  every data file of its partition. The compactor keeps a delete file while any
  data file it can apply to is left out of the rewrite.

## [1.0.0-beta2] - 2026-08-08

### Added

- `coldfront.drop_iceberg_table()` drops a decoupled or tiered table, with
  purge or keep-files for the stored objects.
- Vended object-store credentials, so cold access can use short-lived
  credentials issued by Lakekeeper instead of static keys.
- Cross-tier row relocation: an `UPDATE` that moves a row's partition key
  across the cutoff now moves the row between tiers.
- Multi-arch base images: linux/amd64 and linux/arm64.
- An interactive walkthrough with four demos, runnable in Codespaces.

### Changed

- DuckDB 1.5.4 via the merged pg_duckdb PR #1025.
- Registration refuses unlogged relations, names that the partition naming
  scheme cannot represent, and names differing only by case.

### Fixed

- Cold-tier writes are refused on a standby in every path that reaches them.
- Exotic partition bounds parse correctly, DEFAULT partitions are refused, and
  timestamp-without-time-zone bounds are handled.
- `oid` columns are rejected as unsupported rather than failing later.
- Same-node cold writers serialise through a node-local advisory lock, and
  bakery acknowledgements match on the spock node name.
- Permanent cutover errors stop immediately instead of being retried.

## [1.0.0-beta1] - 2026-06-18

First public beta of pgEdge ColdFront. Pre-release software; not for production
use.

### Added

- Tiered mode keeps recent data in native PostgreSQL partitions and archives
  older data to Apache Iceberg on a watermark, presented to the application as
  a single unified view.
- Decoupled mode stores a table entirely in Iceberg from the first row, with
  PostgreSQL holding a thin wrapper view and the coldfront extension handling
  every data-modifying statement on that view.
- Horizontal scale-out for decoupled mode across multiple PostgreSQL nodes
  sharing one Lakekeeper catalog and one object store, serialised by the bakery
  protocol; the protocol implements Lamport mutual exclusion with the
  Ricart-Agrawala optimisation and its safety is verified in TLA+.
- The coldfront PostgreSQL extension at version 1.0.
- Archiver and partitioner binaries for the tiered workflow, plus a separate
  compactor for Iceberg table maintenance.
- Support for PostgreSQL 16, 17, and 18 on stock upstream builds, with Iceberg
  reads and writes through pg_duckdb.
- Support for any S3-compatible object store, Azure Blob Storage, and Google
  Cloud Storage.
