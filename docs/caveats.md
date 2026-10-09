# Understanding ColdFront Caveats

Keep the following caveats in mind when running either mode:

- `jsonb` reads come back as `json`. The `->`/`->>` operators work, and
  ColdFront translates the `::jsonb` cast, `jsonb_array_length`,
  `jsonb_build_object` / `jsonb_agg` and `date_bin`; other jsonb operators and
  functions are unsupported on cold or cross-tier reads. A hot-only read of the
  view runs in PostgreSQL with full jsonb (see
  [Supported Column Types](supported_types.md)).
- Cross-tier isolation differs from PG-native isolation. The cold tier keeps
  one Iceberg snapshot for the whole transaction, even at READ COMMITTED, so a
  commit by another session after the transaction's first cold read stays
  invisible until the transaction ends. The hot tier follows PostgreSQL's own
  isolation level, so at READ COMMITTED a later statement can see new hot rows
  but not new cold ones. Within one transaction, a read of a tiered or
  decoupled table sees the transaction's own writes on both tiers. The held
  snapshot is also why the compactor's `--expire-older-than` must stay longer
  than the longest transaction that reads the table (see
  [compaction.md](compaction.md)).
- One transaction block cannot hold both a PostgreSQL write and a cold-tier
  write unless `duckdb.unsafe_allow_mixed_transactions` is on. pg_duckdb
  refuses the pair ("Writing to DuckDB and Postgres tables in the same
  transaction block is not supported"), at the PostgreSQL write when it comes
  second and at `COMMIT` when it came first. A cold-tier write here is a
  tiered `UPDATE` or `DELETE` whose `WHERE` bounds the cold tier, or any write
  to a decoupled table. The statements that write both tiers themselves (a
  dual-tier `UPDATE` or `DELETE`, a tiered `INSERT` with cold rows, a
  cross-tier move) set the parameter `LOCAL` for the rest of their
  transaction, so the block they ran in accepts later writes of either kind.
  You can set it yourself, `SET LOCAL duckdb.unsafe_allow_mixed_transactions =
  on`, at your own risk: pg_duckdb commits the Iceberg snapshot at
  `PRE_COMMIT`, so a backend crash between that and the PostgreSQL commit
  record keeps the cold write and loses the PostgreSQL writes.
- In decoupled mode, pg_duckdb commits the Iceberg snapshot at PRE_COMMIT, so a
  backend crash after that but before the PG commit record leaves the Iceberg
  write committed and the PG side lost. A crash after the Parquet upload but
  before the commit POST leaves unreferenced objects, which the compactor's
  orphan pass reclaims.
- In decoupled mode, concurrent writes from multiple PG nodes are serialized
  PG-side by the bakery protocol: every iceberg-only `INSERT` goes through
  `coldfront._exec_iceberg_with_claim`, which holds a globally-ordered
  Snowflake ticket and waits for its turn before committing to Lakekeeper.
  There are no 409 conflicts and no app-level retries. The protocol is
  Lamport-1978 mutex with the Ricart-Agrawala (1981) deferred-reply
  optimization; claims and acks replicate as Spock rows and it stays safe under
  Spock's asymmetric apply (modeled in
  [docs/formal/Bakery.tla](https://github.com/pgEdge/ColdFront/blob/main/docs/formal/Bakery.tla)).
  The bakery requires the `snowflake` extension, the `coldfront.loopback_dsn`
  GUC (the node's loopback, a unix-socket DSN), and a one-time
  `SELECT coldfront.ensure_replicated()` call on every node after Spock mesh
  setup; see
  [architecture_decoupled.md](architecture_decoupled.md#concurrency-horizontal-scaling-the-bakery-protocol).
  Sync-rep is **not** required. The throughput ceiling is Lakekeeper's commit
  rate, not the writer count.
- For direct table access, `_events` is the hot heap (tiered mode only).
  `ice.public.<name>` is the Iceberg table - only addressable via
  `iceberg_scan(...)` or `duckdb.raw_query('… ice.… …')`, never via
  PG-native 3-part names.
- A tiered `INSERT` writes its cold rows through `coldfront._cold_sink`, which
  renders each row in plpgsql and writes Iceberg in batches of
  `coldfront.cold_write_batch_size` rows. An omitted IDENTITY column takes
  `nextval()` on the hot table's sequence, so cold ids share it with the hot
  side, and an omitted column with a DEFAULT takes it. The hot rows are one
  set-based `INSERT`. For very large historical seeds (mostly-cold), prefer
  iceberg-only mode where ids come from your source data.
- `COPY <view> FROM` reads the rows with PostgreSQL's `COPY` reader and writes
  them through that same `INSERT` path, `coldfront.cold_write_batch_size` rows
  per `INSERT`. The format options are the reader's, and a supplied value for a
  `GENERATED ALWAYS` identity column is kept, as `COPY` into a table keeps it.
  `COPY ... WHERE` and the `FREEZE`, `ON_ERROR`, `REJECT_LIMIT` and `DEFAULT`
  options are refused.
- An `INSERT`, `UPDATE` or `DELETE` nested in a `WITH` entry goes through the
  same rewrite as a top-level one. With a watermark an `INSERT`'s row may go
  cold, so `RETURNING` on it is refused, as on a top-level `INSERT`; a hot
  `UPDATE` or `DELETE` keeps `RETURNING`, a cold or dual-tier one cannot
  return rows or read another `WITH` entry (its DuckDB half does not see
  them), and a cross-tier move cannot be a `WITH` entry. A statement may write
  a tiered view once, and the nested write may not have a `WITH` clause of
  its own. On a decoupled view the source runs in DuckDB, so a `WITH` entry
  that modifies data is refused (DuckDB 1.5 has no data-modifying `WITH`), and
  a nested `INSERT` may not read another `WITH` entry. A statement that holds
  a nested write and also reads a tiered view runs in DuckDB as a whole, and
  pg_duckdb refuses it ("DuckDB does not support modifying CTEs"); read the
  hot table, or split the statement.
- `MERGE INTO <view>`, on PostgreSQL 17 and later (16 allows `MERGE` on tables
  alone), runs on the tier its `ON` condition bounds the partition column to
  (`AND t.ts >= '<cutoff>'` for the hot tier, `AND t.ts < '<cutoff>'` for the
  cold tier): a hot `MERGE` runs in PostgreSQL against the hot table
  and keeps `RETURNING`, a cold one in DuckDB against the Iceberg table. Each
  tier sees its own rows alone, so a `MERGE` that bounds neither tier is
  refused, and an `INSERT` action's row must belong to the statement's tier: a
  hot `MERGE` refuses a row below the cutoff, a cold one a row at or after it;
  insert such rows with `INSERT`, which splits them. A cold `INSERT` action
  must give the identity column a value (`OVERRIDING SYSTEM VALUE` for a
  `GENERATED ALWAYS` one), a cold `MERGE` cannot return rows and runs one
  `UPDATE` or `DELETE` action per statement (duckdb-iceberg's limit), and a
  `WHEN NOT MATCHED BY SOURCE` action must bound the same tier in its own
  condition. A `MERGE` that sets the partition column is refused (run the
  change as an `UPDATE`), as is one on a table with a clustered vector column
  and one whose source reads the view. A `MERGE` nested in a `WITH` entry
  takes the same path as a nested `UPDATE` or `DELETE`. On a decoupled view
  every `MERGE` runs in DuckDB.
- `TRUNCATE` on a registered relation, or on the hot table behind a tiered one,
  fails with an error, because the cold rows in Iceberg would stay visible
  through the view.
- A column with a cold tier cannot have a name that PostgreSQL leaves unquoted
  but DuckDB parses as a keyword. With DuckDB 1.5.4 those names are `anti`,
  `asof`, `at`, `by`, `describe`, `glob`, `lambda`, `pivot`, `pivot_longer`,
  `pivot_wider`, `positional`, `qualify`, `semi`, `show`, `summarize`,
  `unpack` and `unpivot`. pg_duckdb passes a column name to DuckDB quoted the
  way PostgreSQL quotes it, so such a name reaches DuckDB bare even when the
  query quotes it, and every query pg_duckdb runs against the column fails
  with a DuckDB `Parser Error`
  ([duckdb/pg_duckdb#1019](https://github.com/duckdb/pg_duckdb/issues/1019)).
  ColdFront refuses such a name wherever a column gets a cold tier: tiered
  registration, an archive pass that tiers or expires data,
  `coldfront.create_iceberg_table()`, `coldfront.adopt_iceberg_table()`, and
  an `ADD COLUMN` or `RENAME COLUMN` on a table that already has a cold tier.
  A DuckDB keyword that its parser accepts as a column name, such as `columns`,
  is not refused. A table with such a column can still be registered
  partition-only, without a hot period.
