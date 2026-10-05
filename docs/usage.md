# Using ColdFront

ColdFront offers two operating modes. Pick one per table; both can coexist in
the same database. The following table compares the two modes:

| | Tiered (hot + cold) | Decoupled (iceberg-only) |
|---|---|---|
| Where rows live | Recent rows are hot in the PG heap, and archived rows are cold in Iceberg. | Every row is in Iceberg. |
| Setup | Create a partitioned table and let the archiver convert it on the first run that finds a partition older than `hot_period`. | One SQL call, `coldfront.create_iceberg_table(...)`, sets up the table. |
| Archiver | The archiver is required; it runs from cron and moves old partitions to cold. | The archiver is not used. |
| Best when | The workload has a recent-row OLTP part that benefits from PG indexes and transactional ergonomics. | The workload is purely analytic or append-mostly, and you want zero PG storage and stateless compute. |

Once the table exists, **the SQL surface is identical**: `SELECT`, `INSERT`,
`UPDATE`, `DELETE` all work normally against the relation name (e.g. `events`),
except that a write touching the cold tier rejects `RETURNING`.

## Prerequisites (Both Modes)

The setup needs three services: PostgreSQL with the pg_duckdb and coldfront
extensions, Lakekeeper, and any S3-compatible object store (SeaweedFS, MinIO,
GCS, etc.). The one-time setup below brings them up and bootstraps them.

## One-Time Setup

Bring up the end-user stack (the example uses SeaweedFS, gated behind the
`local-store` compose profile; host ports are published so the `localhost`
commands below work directly). For the image build itself, see
[installation.md](installation.md):

```bash
docker compose --profile local-store up -d --build
```

Then bootstrap Lakekeeper, create the warehouse, and pre-create the Iceberg
namespace:

```bash
# 1. Bootstrap Lakekeeper
curl -X POST http://localhost:8181/management/v1/bootstrap \
  -H "Content-Type: application/json" -d '{"accept-terms-of-use":true}'

# 2. Create warehouse (adjust endpoint/credentials for your S3 store)
curl -X POST http://localhost:8181/management/v1/warehouse \
  -H "Content-Type: application/json" -d '{
    "warehouse-name": "wh",
    "storage-profile": {
      "type": "s3", "bucket": "iceberg", "region": "us-east-1",
      "endpoint": "http://seaweedfs:8333", "path-style-access": true,
      "flavor": "s3-compat", "sts-enabled": false,
      "remote-signing-enabled": false
    },
    "storage-credential": {
      "type": "s3", "credential-type": "access-key",
      "aws-access-key-id": "admin", "aws-secret-access-key": "adminsecret"
    }
  }'

# 3. Create the Iceberg namespace in the new warehouse.
#    REQUIRED for decoupled (iceberg-only) mode: the Iceberg CREATE SCHEMA is
#    deferred to transaction COMMIT but the CREATE TABLE POST is sent
#    immediately, so coldfront.create_iceberg_table - which runs both in one
#    transaction - would fail with HTTP 404 against a cold warehouse.
#    Pre-creating the namespace here (its own committed REST call) makes the
#    function's in-txn CREATE SCHEMA IF NOT EXISTS a no-op so the table create
#    succeeds. The archiver (tiered mode) creates the namespace itself and does
#    not need this.
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H "Content-Type: application/json" -d '{"namespace":["public"]}'
```

Then install the extensions and set the cold-tier credentials, once per
database:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
```

The secret is stored in the `coldfront.storage_secret` table (excluded from
`pg_dump`; in a Spock mesh it replicates by value once added to the default
repset - one-time mesh setup step 4) and materialized as a DuckDB PERSISTENT
SECRET that loads at instance init. There is **no per-session setup**: the
Iceberg catalog `ice` attaches **lazily** by the coldfront C hook on the first
query that touches a tiered/decoupled view (read or write).

Every `set_storage_secret()` argument after the secret is optional.
`p_endpoint` defaults to `NULL`, `p_region` to `'us-east-1'`, `p_url_style` to
`'path'` (the other value is `'vhost'`), and `p_use_ssl` to `false`.
`p_url_style` and `p_use_ssl` apply only when an endpoint is given. A TLS
endpoint such as GCS's needs `p_use_ssl => true`, and AWS S3 omits the endpoint
and sets `p_region` to the bucket's Region.

The image writes the server settings ColdFront needs into `postgresql.conf`
when it initializes a new data directory. A server built another way sets them
itself, as [installation.md](installation.md#bare-metal-no-docker) shows:

- `shared_preload_libraries = 'pg_duckdb,coldfront'` loads both extensions at
  server start. coldfront refuses to load any other way: `CREATE EXTENSION
  coldfront` fails on a server that does not preload it, with an error that
  names the setting.
- `coldfront.warehouse` and `coldfront.lakekeeper_endpoint` name the Lakekeeper
  warehouse and its catalog endpoint, which the Iceberg catalog `ice` attaches
  to. Only a superuser can set them, and while either is empty the catalog does
  not attach.
- `coldfront.local_pg_dsn` is the connection string DuckDB uses to read
  PostgreSQL tables from this server, which a decoupled table's
  `INSERT … SELECT` from a PostgreSQL table needs, as does a cold write to a
  table with a clustered vector column. Only a superuser can set or read it.
  Set it before calling `set_storage_secret()`, which installs the DuckDB
  `postgres` extension this path loads only when the setting is present.

An application that connects as a non-superuser needs its role granted access
with `coldfront.grant_app_access()`, which takes an existing role:

```sql
SELECT coldfront.grant_app_access('alice');
```

`coldfront.grant_app_access()` derives the grants from the registry when it
runs, so run it again after you create or adopt a table, or tier one for the
first time. The call fails while `duckdb.postgres_role` is unset, because only
superusers can then run DuckDB.
[Least-Privilege Application Roles](index.md#least-privilege-application-roles)
lists what it grants.

For a real cloud-S3 setup, see [object_store.md](object_store.md).

## Mode 1 - Tiered (Hot + Cold)

Create a partitioned table normally:

```sql
CREATE TABLE events (
    id     bigint GENERATED ALWAYS AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text,
    data   jsonb,
    PRIMARY KEY (id, ts)
) PARTITION BY RANGE (ts);

CREATE TABLE p_2026_04 PARTITION OF events
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
```

The archiver connects the way psql does, from the libpq environment (`PGHOST`,
`PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSERVICE`) or `--dsn`, and reads every
other setting from the server: the tables from `coldfront.partition_config`,
the cold-store credential from `coldfront.storage_secret`, and the catalog from
the `coldfront.warehouse` and `coldfront.lakekeeper_endpoint` settings. It
needs no file to run.

A deployment YAML is a way to write that configuration into the server once,
with `import`:

```yaml
s3:
  endpoint: "seaweedfs:8333"
  access_key: "admin"
  secret_key: "adminsecret"
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      hot_period: "1 month"
```

The `import` command writes the file into the server:

```bash
./bin/archiver import --config config.yaml
```

`import` writes the `s3:` or `azure:` stanza through `set_storage_secret` or
`set_storage_secret_azure`, then upserts each table into
`coldfront.partition_config`, validated as `register` validates one table, so
the file and the server agree when it returns. A file may also name
`iceberg.warehouse` and `iceberg.lakekeeper_endpoint`; the import checks those
against the server settings, which live in `postgresql.conf`, before it writes
anything, and refuses the file if they differ. From then on the server is the
configuration: change it with `set`, `register`, `set_storage_secret` or
`postgresql.conf`. A YAML passed to any later run is checked, value by value,
against what the server holds, and any difference is refused with an error
that says where configuration lives. A file that agrees, such as the output of
`export`, runs. `s3.region` defaults to `us-east-1`;
[Storage Backends](#storage-backends) describes the other `s3:` and `azure:`
keys, and a deployment on [vended credentials](#vended-credentials) has no
stanza to import.

Register a single table in `coldfront.partition_config` without a file:

```bash
./bin/archiver register --table events \
    --period monthly --hot-period "1 month"
# optional: --retention "5 years" DROPs cold data past that age
# (must exceed --hot-period; omit = keep forever)
```

Run the archiver (typically via cron):

```bash
./bin/archiver
```

`--version` prints the version that `make build` stamps from `git describe`
(the release tag, or the commit it was built from) and exits; a plain
`go build` prints `unknown`. The partitioner and compactor accept the same
flag.

The archiver also accepts `--debug-export-delay`, a test-only Go duration
(such as `5s`) that holds each partition's capture window open between the
bulk export and the replay, so that a test can race concurrent writes into it.
Leave it unset in production.

The first run that finds a partition older than `hot_period` renames `events`
→ `_events`, creates the unified view `events`, and registers it; until then
the archiver only premakes partitions, and the table stays a plain partitioned
table. From then on every cycle (1) tiers partitions older than `hot_period`
from hot PG to cold Iceberg and advances the watermark, and (2) if
`retention_period` is set, drops cold Iceberg rows older than it. The data
lifecycle is **hot → `hot_period` → cold → `retention_period` → gone**;
omit `retention_period` to keep cold data forever.

### Inbound Foreign Keys

A tiered table cannot be the target of an enforced foreign key from another
table over its archivable range. Archiving physically removes the rows from
PostgreSQL (export to Iceberg, then `DETACH` + `DROP` the partition), and
PostgreSQL cannot enforce a foreign key against the cold tier. So the `DETACH`
is refused (SQLSTATE 23503) and the archiver fails fast, naming the blocking
constraint.

This is inherent, not an edge case: referencing rows rarely have a hot-only
lifecycle. They usually outlive the partition they point at, so the foreign key
still pins those rows in PostgreSQL by the time the partition ages into the
cold tier.

The foreign key is fundamentally incompatible with archiving the rows it
references, so before archiving such a table, drop it:

```sql
ALTER TABLE event_logs DROP CONSTRAINT event_logs_events_fkey;
```

Better still, do not point an enforced foreign key at a tiered table over its
archivable range in the first place.

### 2-Level (LIST → RANGE) Tiered Tables

A table partitioned `LIST (region) → RANGE (ts)` can be tiered too - the same
`sub_partition` block as the standalone partition manager (Mode 3), so a
partition-manager-managed table can be "upgraded" to tiered by pointing the
archiver at it:

```yaml
    - source_table: regional
      partition_column: ts          # the RANGE (time) column - required for 2-level
      partition_period: monthly
      hot_period: 1 month
      # retention_period: 5 years   # optional cold expiry (region-agnostic, by ts)
      sub_partition:
        values_source: "SELECT region FROM regions"
```

One Iceberg table holds every region (region is an ordinary column); the
archiver tiers leaves a whole `ts` period at a time across **all** regions
before advancing the shared hot/cold watermark, so a period only becomes cold
once it is cold for every region. `id` mode is not supported in tiered mode
(the cold tier is time-keyed). For why the ordering works that way, see the
[Two-level tiering](architecture_tiered.md#two-level-list-range-tiering)
section of the Tiered Mode page.

## Mode 2 - Decoupled (Iceberg-Only)

A single call creates a decoupled table:

```sql
SELECT coldfront.create_iceberg_table(
    p_schema  => 'public',
    p_table   => 'events',
    p_columns => '[
      {"name":"id",     "type":"bigint"},
      {"name":"ts",     "type":"timestamptz"},
      {"name":"status", "type":"text"},
      {"name":"data",   "type":"jsonb"}
    ]'::jsonb,
    p_partition_cols => '{month(ts)}'
);
```

`p_partition_cols` partitions the Iceberg table, here by the month of `ts`:
each month's rows land in their own data files, and a query with a time filter
skips the months outside it before reading anything. Each element is one term
as DuckDB's `PARTITIONED BY` takes it: a column name, `year(col)`, `month(col)`
or `day(col)` on a timestamp or date column, `hour(col)` on a timestamp column,
`bucket(N, col)` or `truncate(W, col)`; `'{month(ts), region}'` partitions by
both. The argument is a PostgreSQL array literal, so a term that contains a
comma is double-quoted inside it, the comma being the array's delimiter:
`'{"bucket(16, id)"}'`. A column name that itself needs double quotes has them
backslashed inside such an element: `'{"month(\"Event Time\")"}'`. Leave the
argument out for an unpartitioned table.

That single statement provisions:

- `ice.public.events` on the attached Iceberg catalog.
- a PG-side wrapper view `public.events` with proper PG-typed columns.

- a `coldfront.tiered_views` registry row, so that the coldfront C hook
  intercepts every `INSERT`, `UPDATE`, `DELETE`, and `MERGE` on the view and
  rewrites each one to a single `duckdb.raw_query(...)` against
  `ice.public.events`.


In a mesh one node provisions: Spock's `ddl_sql` repset replicates the
`CREATE VIEW`, and the `default` repset replicates the name-keyed registry row,
which enables the write hook on every peer. Each node also needs the one-time
setup call `coldfront.ensure_replicated()` - see the one-time mesh setup
below.

### Changing a Decoupled Table's Columns

An `ALTER TABLE` on the wrapper view adds, drops, renames or widens a column
of the Iceberg table, and the view follows, with its owner and table-level
grants kept; a column-level grant on the view is not kept. Only the view's
owner, or a role holding its privileges, can change its columns, and that role
needs the cold access `grant_app_access` gives, since the Iceberg change runs
as that role. The following statements change the columns of the table created
above:

```sql
ALTER TABLE public.events ADD COLUMN qty integer;
ALTER TABLE public.events ALTER COLUMN qty TYPE bigint;
ALTER TABLE public.events RENAME COLUMN qty TO quantity;
ALTER TABLE public.events DROP COLUMN quantity;
```

A column takes the same type map as at creation, though an array column cannot
be added, because duckdb-iceberg does not add a nested column to an Iceberg
table. A type change is limited to the widening Iceberg accepts: `integer` to
`bigint`, `real` to `double precision`, `date` to `timestamp`, and a wider
`numeric` precision. An added column takes a name and a type only: a default,
a constraint, a collation, or a storage or compression option is refused, as
is a `USING` or `COLLATE` clause on a type change, and a column change shares
an `ALTER TABLE` only with other column changes. A vector column is neither
added nor changed, a table adopted read-only refuses every column change, and
an object built on the view, such as another view, makes a column change
fail. In a mesh, the change runs on one node: the Iceberg table is shared, and
the rebuilt view and registry row replicate.

### Adopting a Table That Already Exists in the Catalog

A table another engine wrote needs no provisioning, only a wrapper view and a
registry row. `coldfront.adopt_iceberg_table()` reads the schema from the
catalog and builds both, so the call names the relation and nothing else:

```sql
SELECT coldfront.adopt_iceberg_table(
    p_schema    => 'public',
    p_table     => 'orders',
    p_namespace => 'lake'
);
```

`p_schema` is the PostgreSQL schema the wrapper view goes in, and it must
exist. `p_namespace` is the Iceberg namespace the table lives in, which need
not exist as a PostgreSQL schema; it defaults to `p_schema` when omitted. The
view takes the table's name.

Adoption is read-only by default, so reading someone else's lake table cannot
become writing it by accident. Passing `p_writable => true` enables the same
`INSERT`, `UPDATE`, `DELETE` and `MERGE` rewrite a created table gets:

```sql
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake',
                                     p_writable => true);
```

Because Iceberg records no PostgreSQL type, an adopted column reads as whatever
its storage type maps to; a `jsonb` column comes back as `text`. Pass `p_types`
to restore one, provided the override maps to the type the catalog already
stores:

```sql
SELECT coldfront.adopt_iceberg_table('public', 'orders', 'lake',
                                     p_writable => true,
                                     p_types    => '{"meta":"jsonb"}'::jsonb);
```

Adoption binds the name once. A second call under a registered name is refused
whatever its arguments; to enable writes or change an override, release the
table with `coldfront.release_iceberg_table()` and adopt it again. A
non-superuser deployment runs `coldfront.grant_app_access()` after adopting,
because the grant reads the registry at call time.

In a mesh one node adopts. The wrapper view replicates through Spock's
`ddl_sql` repset and the registry row through the `default` repset (see the
one-time mesh setup below), so every peer reads and writes the table under the
same name, and a peer's own adopt is refused as already registered. Adoption
takes the table's bakery claim around that check and the registry write, so two
nodes adopting the same table at the same moment are serialized: the second
waits, then reads the first's row and refuses, rather than both registering the
one table. A writer outside ColdFront is outside the bakery and can still
collide at Lakekeeper.

One relation can be registered per Iceberg table. A namespace that needs
quoting, such as `Lake-EU`, works.

## Mode 3 - Standalone Partition Manager (No Cold Tier)

**You do not need Iceberg at all.** If automated PostgreSQL partition
maintenance is all you want - declarative time- or id-based RANGE partitioning
with a premade forward window and automatic age-out of old partitions -
ColdFront's `partitioner` binary is the whole product: stock PostgreSQL (or a
Spock mesh), no cold tier, no DuckDB, no Iceberg, nothing to preload. Each
invocation makes one reconcile pass per managed table: premake the forward
window, ensure the partition covering *now* exists, and detach-then-drop
partitions past retention (`DETACH ... CONCURRENTLY`, never a bare `DROP` of
attached data). Build the partitioner with `make build` and run it from cron:

```bash
go build -o bin/partitioner ./cmd/partitioner   # or: make build
./bin/partitioner
```

A database set up this way can gain the cold tier later:
`CREATE EXTENSION coldfront` adopts the `coldfront.partition_config` the
partitioner created, registrations included.

The partitioner connects from the libpq environment or `--dsn`, like psql, and
reads its tables from `coldfront.partition_config`; it needs no file. A
partition-only deployment has no cold tier: a table with a `hot_period`
belongs to the archiver, and the partitioner leaves it alone.

Register each managed table in `coldfront.partition_config`:

```bash
./bin/partitioner register --table events \
    --period monthly --retention "12 months" \
    --strategy drop   # drop (DETACH+DROP, destroy; default)
                      #   | detach (DETACH only, keep as a
                      #     standalone table - data preserved)
```

### Operating It

Schedule one pass per period or more often - a cron line, or a systemd
`oneshot` service plus timer (systemd then reports a failed pass as a failed
unit, so alerting is free):

```text
17 * * * * postgres PGDATABASE=mydb /usr/local/bin/partitioner >> /var/log/coldfront-partitioner.log 2>&1
```

Keep the following operational behavior in mind when scheduling it:

- The exit code is `0` when every table reconciled (a self-healed *behind*
  condition still exits `0`) and non-zero when at least one table failed
  (`N table(s) failed`), each failure logged with a `[table]` prefix (the bare
  table name) followed by the schema-qualified error. Alert on a non-zero exit
  code.
- If a table already has a *past* partition but none covers *now* at the start
  of a pass (a lagging cron - live inserts had no home), the pass heals the
  table (creates the current partition), logs a `WARNING (self-healed)` line,
  and still exits `0`. Monitor for that warning in the log rather than via the
  exit code, and widen `future_partitions` or run more often. A fresh table
  (only just-premade future partitions) is **not** behind: its first reconcile
  succeeds cleanly.
- With the default `expiration_strategy: drop`, expiry is
  `DETACH CONCURRENTLY` + `DROP TABLE` - the data is **gone**, so back up
  before shrinking `retention_period`. Set `expiration_strategy: detach` to
  instead leave the expired partition as a standalone table (detached from the
  parent, data preserved) and reclaim it yourself. A partition is expired only
  once its *entire* range is older than `now − retention_period`, computed
  with calendar-accurate PostgreSQL interval arithmetic (a real month, leap
  years correct). `detach` is partition-only - the tiered archiver always drops
  after exporting to cold.

### Primary Keys on Time-Partitioned Tables (id Mode)

PostgreSQL requires a unique index to include the partition key, so a plain
`PRIMARY KEY (id)` is impossible on a table partitioned by a separate `ts`
column. Partition instead by RANGE on a **time-ordered id** and the partition
key *is* the key - a single-column `PRIMARY KEY (id)`:

```yaml
    - source_table: events
      partition_column: id
      partition_period: monthly
      retention_period: 12 months
      part_mode: id
      id_scheme: snowflake             # snowflake | uuidv7
```

`uuidv7` reads the RFC 9562 leading-millisecond timestamp; `snowflake` decodes
the pgEdge Snowflake extension's layout. Either way the manager computes the
month/day partition bounds as id values, so id-order equals time-order and the
forward/retention schedule is unchanged.

### Two-Level (LIST → RANGE) Sub-Partitioning

For a table partitioned by `LIST (region)` whose children are themselves
`RANGE`-partitioned by time, add a `sub_partition` block. `values_source` is a
query returning the current level-1 values; the manager provisions and
maintains a RANGE sub-tree under each, creating sub-trees for newly appearing
values automatically:

```yaml
    - source_table: events
      partition_column: ts             # the level-2 RANGE column
      partition_period: monthly
      retention_period: 12 months
      sub_partition:
        values_source: "SELECT code FROM regions"
```

Each level-1 child is named `<table>_<value>`, with the value lowercased and
every character outside `a-z`, `0-9` and `_` replaced by `_`. That name must
fit in 50 bytes, which leaves room for the daily leaf suffix within
PostgreSQL's 63-byte identifier limit. A pass that meets a longer name fails,
for tiered two-level tables as well. The partitioner and the archiver also
fail a pass in which two values map to the same name.

## Dropping an Iceberg Table (Both Modes)

`coldfront.drop_iceberg_table()` removes the Iceberg table backing a registered
relation. The function is the only sanctioned way to do so: a plain
`DROP TABLE` or `DROP VIEW` on a registered relation stays blocked, because it
would leave the cold tier behind with nothing pointing at it.

The call takes the schema, the table, and an explicit purge decision:

```sql
-- drop the catalog entry and delete the stored objects
SELECT coldfront.drop_iceberg_table('public', 'events', true);

-- drop the catalog entry and leave the objects in the object store
SELECT coldfront.drop_iceberg_table('public', 'events', false);
```

What remains afterwards depends on the mode, and the call reports which path it
took:

- in decoupled mode the Iceberg table is the whole relation, so nothing remains
  in PostgreSQL.
- in tiered mode the Iceberg table is the cold tier, so the cold tier is
  removed and the hot table returns under the relation's own name, as an
  ordinary partitioned table holding the data that had not yet aged out.

In tiered mode the call also deletes the table's `partition_config` row, which
stops the archiver from tiering it again on the next run.

There is no default for the purge argument, because the two outcomes are
irreversible in opposite directions. Passing `true` deletes the Parquet and
metadata objects, which for the cold tier are the only copy of that data.
Passing `false` keeps those objects but removes the catalog entry that
ColdFront would need to reach them again, so nothing reclaims them afterwards;
use it when another system is taking ownership of the files.

ColdFront has no guard of its own against dropping the wrong table. The
preventive control lives in Lakekeeper: table protection has to be enabled
manually, per table, and a protected table cannot be dropped at all, whether or
not purge is requested. This function cannot override a hold.

Deletion is not instantaneous. The catalog entry disappears with the call, and
Lakekeeper's own background queue removes the objects shortly afterwards, so a
listing taken immediately after the call can still show them.

### Handing an Adopted Table Back

An adopted table is released rather than dropped, because ColdFront does not
own it. `coldfront.release_iceberg_table()` removes the wrapper view, the
registry row and the relation's vector configuration, and performs no Iceberg
I/O, so the table keeps every row and stays in the catalog:

```sql
SELECT coldfront.release_iceberg_table('public', 'orders');
```

Release refuses a tiered registration, because removing one would leave its
cold rows unreachable while the hot table returned under the relation's name.
`drop_iceberg_table()` refuses a relation adopted read-only, for the mirrored
reason: read access gives no authority to destroy.

## Managing Partitioned Tables (CLI)

ColdFront's configuration lives in the server. **Per-table lifecycle** lives in
`coldfront.partition_config`, a name-keyed table that replicates by value
across a Spock mesh (like `tiered_views`/`archive_watermark`), so every node
reads identical config - no per-node file syncing. The cold-store credential
lives in `coldfront.storage_secret` and the catalog in the
`coldfront.warehouse` and `coldfront.lakekeeper_endpoint` settings. The
**connection** alone comes from outside, from the libpq environment or
`--dsn`, as for psql. Manage the lifecycle table with the CLI below (both
`partitioner` and `archiver` expose these subcommands; with no subcommand they
do their normal reconcile/archive run).

`register` is the primary way to manage tables: one command adds or adopts one
table, validated on the spot. `import` and `export` are bulk helpers for
(re)configuring a machine - write a deployment YAML into a fresh server, or
dump the live config to git and replay it on another node - not the day-to-day
path. A YAML passed to anything but `import` is checked against the server and
refused if it disagrees in any value.
`register` and `import` run the full validation; `set` re-runs it only when it
changes the partition period or column, `hot_period`, `retention_period` or the
sub-partition source, and otherwise relies on the table's CHECK constraints.

The data lifecycle is **hot PG → `hot_period` → cold Iceberg →
`retention_period` → dropped** (tiered) or **hot PG → `retention_period`
→ dropped** (partition-only). Setting `hot_period` makes a table tiered;
omitting it makes it partition-only.

### What Registration Refuses

`register` and `import` run the same validation, so a table that one rejects
cannot be added by the other; `set` re-runs it when it changes a validated
field. Registration fails when:

- any relation in the partition tree is `UNLOGGED`, because that data is
  truncated after a crash and replicates nowhere, so archiving it would
  preserve rows PostgreSQL never promised to keep.
- the table has a `DEFAULT` partition. Rows the `DEFAULT` partition catches
  have no time bounds, so they can never be tiered or expired, and PostgreSQL
  refuses `DETACH PARTITION ... CONCURRENTLY` for every partition of a table
  that has one, which is how partitions are expired. The partition's mere
  existence is enough; it does not have to hold any rows. Move any rows the
  `DEFAULT` partition holds into real partitions and detach it.
- the name differs only by case from an already-registered table. PostgreSQL
  keeps `public."Events"` and `public.events` apart, but DuckDB matches
  identifiers case-insensitively even when they are quoted, so both names would
  resolve to one Iceberg table and overwrite each other.
- the name starts with an underscore, which is reserved for the tiered hot
  table.
- the name leaves no room for the generated partition suffix: 53 bytes for
  monthly and 50 for daily, within PostgreSQL's 63-byte identifier limit.
- a tiered table has a column whose type has no Iceberg equivalent (see
  [Supported Column Types](#supported-column-types)). Every column goes through
  the same type map the cold tier itself uses, so the answer comes back at the
  prompt rather than hours later from cron, and the refusal names the column.
  Partition-only tables are exempt: nothing about them reaches Iceberg, so
  their column types are PostgreSQL's business alone.
- a tiered table has a column whose name DuckDB parses as a keyword, such as
  `by`, `at` or `show` (see [Caveats](#caveats)). The archiver checks the
  names again before it tiers or expires data, so a column added after
  registration is refused there, before any table or data reaches Iceberg.

Registration validates the table as it is at that moment, not continuously.
Adding a `DEFAULT` partition to an already-registered table is therefore not
caught then; the next archiver run fails while reading that table's partition
bounds.

Other unusual bounds are supported rather than refused. Partitions open at
either end (`MINVALUE`, `MAXVALUE`, `infinity`) are handled, as is PostgreSQL's
full timestamp range, from 4713 BC through year 294276.

`hot_period` and `retention_period` are native PostgreSQL `interval`s - use any
interval syntax (`1 month`, `90 days`, `1 year 2 mons`, `5 years`). Expiry
boundaries are computed with calendar-accurate interval arithmetic
(`now() - period`: real months, leap years), and `retention_period` must exceed
`hot_period` (validated at `register`/`set` time).

The following table describes the CLI subcommands:

| Command | Purpose |
|---|---|
| `register` | Adds or adopts a table, and validates that the PRIMARY KEY covers the partition key. |
| `list` | Shows the managed tables and their lifecycle. |
| `set` | Changes fields, or disables or enables a table with `--disable`/`--enable`. |
| `remove` | Stops managing a table; the table itself is left intact. |
| `import` | Writes a deployment YAML into the server once: its `archiver.tables` as rows, validated as `register` validates each table, and its `s3:` or `azure:` stanza as the storage secret. |
| `export` | Dumps the active (enabled) config to YAML or SQL, as a git-reviewable backup to replay on another node. |

The following examples register, inspect, and change managed tables:

```bash
# Partition-only: keep 3 future partitions, drop those older than 12 months.
partitioner register --table events --period monthly --retention "12 months"

# Partition-only, but DETACH (preserve) expired partitions instead of dropping them.
partitioner register --table events --period monthly \
    --retention "12 months" --strategy detach

# Tiered: tier to cold Iceberg after 1 month, then drop cold data after 5 years.
archiver register --table events --period monthly \
    --hot-period "1 month" --retention "5 years"

# id mode - a real single-column PRIMARY KEY (id) on a snowflake-keyed table.
partitioner register --table events --period monthly \
    --column id --part-mode id --id-scheme snowflake --retention "1 year"

# 2-level LIST(region) → RANGE(ts), tiered; region values come from a table.
archiver register --table regional --period monthly --column ts \
    --hot-period "1 month" --sub-values-source "SELECT region FROM regions"

partitioner list                                   # what's managed
partitioner set    --table events --retention "24 months"
partitioner set    --table events --disable        # pause (keeps the row)
partitioner remove --table events                  # unregister, keep the table
partitioner import --config deploy.yaml            # write a deployment YAML into the server once
partitioner export > managed.yaml                  # active config, git-reviewable (--format sql for INSERTs)
```

Run `partitioner` (or `archiver`) with `help` or `--help` for the command
overview, and with no arguments for its normal run; every subcommand has a
detailed `--help` with worked examples. The write commands accept
`--print-sql` (emit the SQL without running it - review/commit it; `import`
prints its table `INSERT`s); `register` and `import` also accept `--dry-run`.
`set --enable`/`--disable` (mutually exclusive) pause/resume a table without
removing it; a disabled table is skipped by reconcile and omitted from
`export`. Per table, only the cadence and a lifecycle boundary (`hot_period` or
`retention_period`) are required; `partition_column` is auto-detected from
`pg_catalog` for flat tables (required for 2-level). `register` writes a row
whose `CHECK` constraints enforce the lifecycle rules at write time.

The subcommands also take the following connection and table flags:

- `--dsn` takes a PostgreSQL connection string on every subcommand. Without
  it the connection comes from the libpq environment, as for psql.
- `--config` names a deployment YAML. On `import` it is required, since it
  names the file to write into the server. On any other subcommand the file is
  checked against the server, value by value, and refused if it disagrees; its
  `postgres.dsn` connects when `--dsn` is unset.
- `--schema` (default `public`) names the table's schema on `register`, `set`
  and `remove`.
- `--premake` (default `3`) sets on `register` how many future partitions are
  kept ahead of now, stored as `future_partitions`.

`set` changes only the fields whose flags are passed: `--period`, `--column`,
`--premake`, `--hot-period`, `--retention`, `--sub-values-source` and
`--strategy`, each taking the same value as on `register`. An empty value
clears the field, so `--hot-period ""` makes a tiered table partition-only and
hands it to the partitioner. A change that leaves neither a `hot_period` nor a
`retention_period` is refused.

For managing tables, the archiver and partitioner read the managed set only
from `coldfront.partition_config`. `register` adds one table; `import` adds
every table in a YAML `archiver.tables` list. Both write through the same
validation (the PK must cover the partition key; `retention` must exceed
`hot_period`), so an imported table is checked exactly as a registered one.
`export` dumps the active rows back to YAML or SQL for git.

The archiver manages only the rows that have a `hot_period`, and the
partitioner only the rows without one, so each table belongs to one binary. A
run that finds none of its own rows exits non-zero with
`no tables in coldfront.partition_config`, naming the `register` and `import`
commands that add one.

In an `archiver.tables` entry, `source_schema` names the table's schema and
defaults to `public`. `source_table` also accepts the `schema.table` form, and
an explicit `source_schema` takes precedence over that prefix.
`future_partitions` defaults to `3`, as `--premake` does on `register`.

## Storage Backends

Configure **exactly one** of the following cold-store backends, through
`set_storage_secret` or through the `s3:` or `azure:` stanza of a deployment
YAML, which `import` writes through the same setters.

### S3

The S3 backend works with any S3-compatible store (SeaweedFS, MinIO). Set
`endpoint`, `use_ssl: true` for a TLS endpoint, and `url_style: path` (default)
or `vhost`. `region` defaults to `us-east-1`.

### Virtual-Hosted Cloud S3

For virtual-hosted cloud S3 (AWS S3 is the canonical one), **omit `endpoint`**
(and the `endpoint` arg to `set_storage_secret`) so DuckDB uses the native
per-Region virtual-hosted + HTTPS addressing; set `region` to your bucket's
Region. DuckDB derives the endpoint from `region`, and a bucket in a Region
launched after 2019-03-20 (e.g. `ap-south-2`) rejects requests sent to another
Region's endpoint with HTTP 400. The Lakekeeper warehouse profile must be a
virtual-hosted `s3` profile (`flavor: aws`, `path-style-access: false`, no
custom endpoint); the full walkthrough is [object_store.md](object_store.md).

### Google Cloud Storage

Google Cloud Storage is *not a separate backend*: use `s3:` pointed at GCS's
S3-interoperability endpoint with an
[HMAC key pair](https://cloud.google.com/storage/docs/authentication/hmackeys)
(`endpoint: storage.googleapis.com`, `use_ssl: true`,
`access_key`/`secret_key` = the HMAC id/secret). Lakekeeper's warehouse uses an
`s3` profile (`flavor: s3-compat`, `path-style`) at the same endpoint.
ColdFront's test suite covers this setup end to end, reading and writing
Iceberg through the interoperability endpoint. Lakekeeper's native `gcs`
profile is service-account only and is **not** used.

### Azure ADLS Gen2

Azure ADLS Gen2 is a supported cold-store backend; the access key rides inside
`connection_string`. Set the credential with `set_storage_secret_azure()`
instead of `set_storage_secret()` - it takes a CONFIG-provider connection
string. The storage-account access key rides inside `AccountKey=…`; the
DuckDB azure secret has no separate account-key parameter, so shared-key auth
lives entirely in the connection string:

```sql
SELECT coldfront.set_storage_secret_azure(
    'DefaultEndpointsProtocol=https;AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net');
```

`set_storage_secret_azure()` writes the same `coldfront.storage_secret` row
(replicated, `pg_dump`-excluded) and materializes a `TYPE azure` PERSISTENT
SECRET. The Azure cold tier is subject to the soft-delete / change-feed
restriction in [Caveats](index.md#caveats).

## Vended Credentials

Vended credentials let a deployment run with no object-store credential stored
in the database, in a DuckDB secret file, or in an archiver config; this suits
compliance environments that forbid persisting long-term keys. Lakekeeper
issues a short-lived, per-table credential (an S3 STS access key, secret, and
session token) at read and write time, and ColdFront uses it directly. The
long-term credential lives only in the Lakekeeper warehouse.

Enable vended credentials with a single call that stores no credential:

```sql
SELECT coldfront.set_storage_secret_vended();
```

This writes a `coldfront.storage_secret` row marked as vended, so nothing is
materialized as a DuckDB secret; `ensure_attached()` then attaches the catalog
with credential vending turned on. The archiver and the compactor read the
same row, so a vended deployment has no `s3:` or `azure:` stanza to import and
no credential in any file.

Vended mode targets the two clouds that issue scoped credentials: AWS S3 (STS)
and Azure ADLS Gen2 (SAS). The `set_storage_secret_vended()` call above enables
AWS S3; the same call with `'azure'` enables Azure through the identical path:

```sql
SELECT coldfront.set_storage_secret_vended('azure');
```

Vending requires a Lakekeeper warehouse configured to vend credentials:

- On AWS S3, the warehouse uses `flavor: aws` with `sts-enabled: true`, an
  `assume-role-arn` for a bucket-scoped IAM role, and an `external-id` on the
  warehouse credential that the role's trust policy also requires. The full
  warehouse and IAM-role setup is in
  [object_store.md](object_store.md#3b-create-the-s3-warehouse).
- On Azure ADLS Gen2, the warehouse is an `adls` warehouse with `sas-enabled`
  (on by default). Lakekeeper vends a per-container SAS token; the warehouse
  credential can be a `shared-access-key`, `client-credentials`, or
  `azure-system-identity`.

Google Cloud Storage over the S3-interoperability endpoint has no STS to issue
short-lived credentials, so GCS stays on static HMAC credentials.

The compactor runs fully under vended credentials: compaction, snapshot expiry,
and orphan-file reclaim all use the vended per-table credentials.

Switching a running deployment between static and vended credentials changes
the attach mode, which is fixed per PostgreSQL backend at attach time; open a
new session (or restart the archiver and compactor, which are short-lived
processes) so the new mode takes effect.

## Reading + Writing (Identical for Both Modes)

The same SQL works against the relation name in either mode, as the following
examples show:

```sql
-- Reads - pg_duckdb handles the iceberg side; PG handles the heap side
SELECT count(*) FROM events;
SELECT id, status, data->>'k' FROM events WHERE ts >= '2026-04-01';

-- Inserts, updates, and deletes all go through the coldfront C hook,
-- which rewrites the query into one PG-set-based statement (hot side)
-- + duckdb.raw_query calls (cold side). For iceberg-only mode every write
-- goes cold; for tiered mode the hook splits by ts vs the watermark.
INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{"k":1}');
UPDATE events SET status = 'fixed' WHERE id = 123;
DELETE FROM events WHERE ts < '2025-01-01';

-- Bulk INSERT shapes: the source is read once, the hot rows are one
-- set-based INSERT and the cold rows are written in batches:
INSERT INTO events (ts, status, data) VALUES (...), (...), (...);
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM staging;
INSERT INTO events (ts, status, data) SELECT now() + i*'1s'::interval, 'ok', '{}'
                                       FROM generate_series(1, 1000) i;
-- A WITH clause works in both positions; a nested INSERT takes no RETURNING:
WITH moved AS (DELETE FROM staging RETURNING ts, status, data)
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM moved;
WITH i AS (INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{}'))
SELECT 1;
-- COPY FROM loads the same way, one INSERT per cold_write_batch_size rows:
COPY events (ts, status, data) FROM '/path/to/events.csv' WITH (FORMAT csv);

-- Transactions work; ROLLBACK undoes Iceberg writes too
BEGIN;
  UPDATE events SET status = 'pending' WHERE id = 1;
  SELECT status FROM events WHERE id = 1;   -- sees 'pending' if row 1 is hot
ROLLBACK;
SELECT status FROM events WHERE id = 1;     -- back to whatever it was
```

## Supported Column Types

The following PostgreSQL column types are supported:

`bigint` · `integer` · `smallint` · `real` · `double precision` ·
`boolean` · `timestamp with time zone` · `timestamp without time zone` ·
`date` · `time without time zone` · `uuid` · `text` · `varchar(N)` ·
`char(N)` · `bytea` · `numeric(P,S)` (P ≤ 38) · `jsonb` / `json` ·
`interval` · `vector(N)` / `halfvec(N)` (pgvector; see
[usage_vectors.md](usage_vectors.md)) · one-dimensional arrays of most of
these types (see [Arrays](#arrays))

Anything else (unbounded `numeric`, `xml`, `tsvector`, range/multirange types,
custom enums, composite types, pgvector's `sparsevec`, and the arrays that
[Arrays](#arrays) lists as refused at registration) is rejected when a tiered
table is registered, and when a decoupled table is created. ColdFront refuses
silent fallback to `varchar` - losing precision/identity is worse than no
support.

Iceberg cannot hold a `numeric` `NaN`, or an `infinity` or `-infinity` in a
`date`, `timestamp` or `timestamptz` column, so ColdFront refuses those values,
as array elements too. A tiered table's hot table has a check constraint named
`coldfront_guard_<column>` on each column of those types and on each array
column; an `INSERT` or `UPDATE` that stores one of the values fails with an
error that names the constraint. A write that goes to the cold tier, in either
mode, is refused by DuckDB.

The archiver adds the constraints at the first archive pass that tiers a
partition of the table, and validates them once that pass's bootstrap
transaction has committed. A value written before then is accepted, and each
archive pass stops with an error that names the constraint until the row is
fixed; the next pass then validates the constraint and tiers the table. A
column that an `ALTER TABLE` adds through the DDL hook gets its constraint in
the same statement, which PostgreSQL validates against every row of the hot
table, so an `ADD COLUMN` whose default the constraint refuses, such as
`DEFAULT 'NaN'`, fails. A renamed column's constraint takes the new column
name, and a column whose name is longer than 47 bytes gets a constraint named
after a hash of the name.

A cold `UPDATE ... FROM`, a `MERGE` whose source is a PostgreSQL table, and an
`INSERT ... SELECT` into a decoupled table read that PostgreSQL table through
DuckDB's postgres extension, which reads a `numeric` `NaN` as `0` and drops an
array's lower bound. ColdFront cannot refuse those values on that path, so
filter them out of such a source.

`char(N)` is stored and read as `varchar`. The data round-trips losslessly:
values, comparisons, and `length()` match a hot PG table, where `length()`
already ignores `char(N)` trailing padding. The only difference is cosmetic: a
cold `char(N)` column reads back unpadded with `pg_typeof varchar`, because
pg_duckdb has no fixed-length `char` type. Use `text` or `varchar` if
blank-padded display matters.

`json`, `jsonb` and `interval` are stored as `varchar` in Iceberg (no native
primitive). On read, `interval` is view-cast back to the rich PG type; `json`
and `jsonb` come back as DuckDB's `json` (the equivalent of PG's `jsonb`), not
the rich PG `jsonb` type, because Iceberg-backed reads run entirely in DuckDB.
Queries like `data->>'key'` and `data->'key'` work, and ColdFront translates
the `::jsonb` cast, `jsonb_array_length`, `jsonb_build_object` / `jsonb_agg`
(and their `json_` twins, which DuckDB also lacks) and `date_bin` on read: the
builders become the `concat` / `to_json` / `array_agg` form both engines
evaluate identically (the result is JSON-equal to jsonb's rendering, in compact
form and in argument order), and `date_bin` becomes DuckDB's `time_bucket`,
which takes the same arguments and agrees on every fixed-width bucket. The
jsonb-only operators (`?`, `@>`, `<@`, `#>`, `#>>`) and most jsonb functions
(`jsonb_typeof`, `jsonb_extract_path`, `jsonb_extract_path_text`, `jsonb_set`,
`jsonb_path_*`, `jsonb_each`, `jsonb_object_keys`) are not supported on tiered
or decoupled data: DuckDB either lacks them or its same-named function differs
in signature or result. Reach into the document with `->`/`->>`.

These limits apply only to reads that go through a tiered or iceberg-only view,
which pg_duckdb plans entirely in DuckDB. Ordinary (non-tiered) PostgreSQL
tables are untouched by ColdFront and keep full jsonb support, as does the hot
partition table itself.

Bound parameters (`$1` from a prepared statement, a driver's extended protocol,
or a plpgsql variable) work in such reads. DuckDB types most placeholders from
their context (`ts > $1`); one that is a direct argument of a DuckDB function
with several overloads (`time_bucket`'s origin, so `date_bin`'s) or any
argument of a table function (`generate_series`) it cannot, so ColdFront plans
such a read from the bound values on every execution instead of caching a
generic plan. Under `plan_cache_mode = force_generic_plan` those reads cannot
run: the forced generic plan has no values and fails with
`only works with DuckDB execution`.

A hot-only read is the exception. When a `SELECT` reads a tiered view directly
(no join, CTE, or sub-query) and its `WHERE` provably restricts to the hot
tier, ColdFront rewrites it to read the hot partition table in plain
PostgreSQL: the full jsonb operator and function set works, and the query skips
DuckDB entirely. Such a read returns `data` as native `jsonb` rather than the
view's `json`. Reads that span tiers, are cold-only, or reach the view through
a join or sub-query stay in DuckDB, where the limits above apply.

`inet`/`cidr`/`oid` are **not supported**: pg_duckdb cannot process them
(`inet` Oid 869, `oid` Oid 26) in any Iceberg-backed query, and every
cross-tier read is planned by pg_duckdb - so no cast makes them readable. Store
IP data as `text` and `oid` values as `bigint` (you can still index/compare
them; cast on the hot side only if needed).

### Arrays

A one-dimensional array of a supported type tiers as an Iceberg list of that
type. The following table shows how each array type is stored and how the view
reads it back:

| PG type | Iceberg/Parquet storage | Reads back as |
|---|---|---|
| `bigint[]`, `integer[]`, `real[]`, `double precision[]`, `boolean[]`, `date[]`, `time[]`, `timestamp[]`, `uuid[]`, `bytea[]`, `numeric(P,S)[]` | A list of the element's storage type. | The same type. |
| `smallint[]` | A list of `INTEGER`. | `integer[]`, as a `smallint` column reads as `integer`. |
| `text[]` | A list of `VARCHAR`. | `text[]`. |
| `varchar(N)[]`, `char(N)[]` | A list of `VARCHAR`. | `character varying[]`, with `char(N)` elements unpadded. |

The following arrays are refused when a tiered table is registered and when a
decoupled table is created, with an error that names the column:

- `timestamptz[]`, because pg_duckdb cannot read a `timestamptz[]` column of a
  PostgreSQL table, which a tiered table's hot tier is; store `timestamp[]` in
  UTC instead.
- `jsonb[]`, `json[]` and `interval[]`, because those types are stored as text
  and read back through a cast that an array element does not get.
- arrays of `vector` or `halfvec`, because a vector is itself stored as a list,
  and ColdFront stores an array as a list of scalar values.

An Iceberg list has one dimension and numbers its elements from 1, so ColdFront
refuses an array with more than one dimension or with a lower bound other than
1, such as `'[0:2]={1,2,3}'`. The hot table's check constraint refuses such an
array when it is written. A write to the cold tier refuses it too: a tiered
`INSERT` with an error that names the column, and a bound parameter with an
error that names no column. A tiered table with a column declared with more
than one dimension, such as `integer[][]`, passes registration and is refused
at its first archive pass, because pg_duckdb reads a column by its declared
dimensions; a decoupled table refuses such a column when it is created. A
decoupled table's array type is spelled as its element type followed by `[]`,
such as `integer[]`; the spellings `integer[3]` and `integer ARRAY` are
refused. `ALTER TABLE ... ADD COLUMN` cannot add an array column to a tiered
table, because duckdb-iceberg does not add a nested column to an Iceberg table.

A tiered `INSERT` accepts an array in any spelling, because its source runs in
PostgreSQL. A cold `UPDATE` and a decoupled `INSERT` run in DuckDB, which does
not read PostgreSQL's brace literal: a `'{a,b}'` literal reaches DuckDB as text
and fails to cast. Write the array as `ARRAY['a', 'b']`, or pass it as a bound
parameter.

Reads through a view run in DuckDB once the table has a cold tier, and the
following array operations work there:

- `x = ANY(arr)`, `arr @> ARRAY[...]` and `arr && ARRAY[...]`.
- subscripts and slices, which count from 1, such as `arr[1]` and `arr[1:2]`.
- `array_length(arr, 1)` and `unnest(arr)`.

A brace literal and a bound array parameter fail in such a read, as they do for
a vector, and so does `cardinality()`, which DuckDB defines for maps only.

## Caveats

Keep the following caveats in mind when running either mode:

- `jsonb` reads come back as `json`. The `->`/`->>` operators work, and
  ColdFront translates the `::jsonb` cast, `jsonb_array_length`,
  `jsonb_build_object` / `jsonb_agg` and `date_bin`; other jsonb operators and
  functions are unsupported on cold or cross-tier reads. A hot-only read of the
  view runs in PostgreSQL with full jsonb (see
  [Supported Column Types](#supported-column-types)).
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

## Distributed Setup (3-Node Mesh, Decoupled Mode)

For multi-writer iceberg workloads, run ColdFront on N PG nodes in a Spock mesh
against the same Lakekeeper + S3. The bakery serializes commits PG-side so
writers never collide at the catalog.

### Per-Node `postgresql.conf`

The configuration below applies to each node in the mesh:

```ini
wal_level = logical
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'

# The bakery rules a peer dead when its walsender's last reply is older than
# coldfront.peer_alive_window_ms (default 10 s), and an idle peer replies only
# to the walsender's keepalive, every wal_sender_timeout/2. The claim refuses
# to run unless wal_sender_timeout is positive and below twice the window.
wal_sender_timeout = 15s

# Spock prereq + DDL replication. The ddl_sql repset (and with it the
# one-node provisioning promise for wrapper views) only works with DDL
# replication on; allow_ddl_from_functions covers DDL issued inside
# coldfront's plpgsql helpers.
track_commit_timestamp = on
spock.enable_ddl_replication = on
spock.allow_ddl_from_functions = on
spock.include_ddl_repset = on

# Only on a server that has this setting (PostgreSQL 16.15, 17.11 and 18.6 in
# pgEdge's builds):
# it lists the libraries allowed as logical decoding output plugins, and its
# default leaves out Spock's, so no subscription can create its slot. A server
# without the setting refuses to start with this line in place.
output_plugin_libraries = 'pgoutput, test_decoding, spock_output'

# Per-node - any distinct integer 1..1023 (must be unique per node; the value
# is otherwise arbitrary - the bakery matches acks by spock node name, not by id).
snowflake.node = 1

# DSN of the node's loopback, which runs the bakery's autonomous claim
# INSERT/DELETE. It must name a unix socket: every onboarded role can read
# this setting, so it must never need a password. The claim session only
# touches the coldfront.claims/claim_acks heap tables, so it never attaches
# the Iceberg catalog (the lazy catalog-attach hook fires only on a tiered
# view). application_name=coldfront_loopback marks the session as bakery
# traffic. Only a superuser can set it.
coldfront.loopback_dsn = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_loopback'

coldfront.warehouse = 'wh'
coldfront.lakekeeper_endpoint = 'http://lakekeeper:8181/catalog'

# Upload the Parquet outside the bakery claim and serialize only the catalog
# commit. Set both, and only where duckdb-iceberg includes ColdFront's patch (the
# ColdFront image does). With either off, the upload is serialized too.
coldfront.iceberg_async_parquet = on
coldfront.iceberg_bakery_patch = on
```

The bakery has no peer-ack timeout. R-A's only failure mode is a dead peer
(would wait forever), and a liveness check inside the wait loop closes it:
the bakery treats a peer whose `pg_stat_replication.reply_time` is older than
`coldfront.peer_alive_window_ms` as already acked, whatever the walsender's
state (a peer that has just reconnected is catching up and still alive). The
peer's apply worker sends that reply after it applies, every
`spock.feedback_frequency` messages, and in answer to the walsender's
keepalive; `wal_receiver_status_interval` plays no part, since Spock's apply
worker does not read it. The window and `wal_sender_timeout` go together; set
them as [Timeouts](#timeouts) below describes. An alive peer that has
not acked is either deferring legitimately (R-A's defer rule) or about to
ack, and waiting for it is correct, not a failure.

A claim whose owner is gone (a hard backend crash) is reaped without operator
action: by that node's next cold write, to any table, by a peer's arriving
claim, or by the waiting peer's poke, a no-op `UPDATE` of its own claim row
about once a second for as long as it waits. That poke is the only replication
traffic the bakery generates while a writer waits, and there is none when
nothing waits. See [architecture_decoupled.md](architecture_decoupled.md),
*Orphan reaping*.

Sync-rep (`synchronous_standby_names`) is **not required** by the bakery - the
R-A ack barrier is what serializes iceberg commits. You can still enable
sync-rep cluster-wide if you want stronger durability for non-bakery writes,
but it plays no part in iceberg-commit serialization.

Run this one-time mesh setup in this order on every node, because step 3 calls
`spock.repset_add_table`, which requires the local Spock node to already exist:

```sql
-- 1. Extensions, in dependency order. snowflake is a bakery prereq
-- (claim tickets come from snowflake.nextval).
CREATE EXTENSION IF NOT EXISTS snowflake;
CREATE EXTENSION IF NOT EXISTS spock;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- 2. Spock node + full-mesh subscriptions (each node has N-1 subs). Name each
-- subscription sub_<subscriber>_from_<provider> (on n1: sub_n1_from_n2): the
-- bakery's peer-liveness check looks the walsender up by that name, and a peer
-- whose subscription is named any other way counts as dead and is treated as
-- already acked.
SELECT spock.node_create('n<i>', 'host=<this_node_priv_ip> user=coldfront dbname=coldfront port=5432');

-- on n1 (n2 and n3 symmetric):
SELECT spock.sub_create('sub_n1_from_n2', 'host=<n2> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);
SELECT spock.sub_create('sub_n1_from_n3', 'host=<n3> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);

-- 3. **Required** on every node, after its subscriptions exist and before
-- the first cold write, storage secret or table registration: put every
-- ColdFront table that replicates by value in this node's replication sets.
SELECT coldfront.ensure_replicated();
```

The subscriptions set
`synchronize_structure := false, synchronize_data := false` because the tables
already exist on every node from the coldfront extension, so no initial copy is
needed.

### Timeouts

The following table lists the two settings that decide how long a cold write
waits for a peer; set them together, on every node:

| Setting | Recommended | Where | What it does |
|---|---|---|---|
| `wal_sender_timeout` | `15s` | `postgresql.conf` on every node; the image sets it in mesh mode | The node's walsender asks each peer for a reply after half of it (7.5 s) and drops a peer that has not replied for the whole of it. |
| `coldfront.peer_alive_window_ms` | `10000` (the default) | `postgresql.conf`, superuser-only | The bakery treats a peer whose last reply is older than this as dead and stops waiting for its ack. |

The rule: half of `wal_sender_timeout` must stay below the window, with a
round trip to spare; the claim enforces the first part. An idle peer replies
only when the walsender asks, so the
PostgreSQL default of 60 s against a 10 s window would rule a live idle peer
dead; a claim refuses to run with such settings and names both. With the
recommended values a writer waits at most 10 s for a peer that is really
dead, and the walsender disconnects a peer silent for 15 s, which then
reconnects on its own.

On a slow or lossy WAN raise both together and keep the rule, for example
`wal_sender_timeout = 30s` with `coldfront.peer_alive_window_ms = 20000`.
Both take effect on a reload (`ALTER SYSTEM SET ...;` then
`SELECT pg_reload_conf();`), no restart: walsenders re-read the timeout, and
each claim reads the window once.

### What `coldfront.ensure_replicated()` Does

The call is the one ColdFront-specific step of the mesh setup. It adds eight
tables to the node's replication sets (`claim_acks` to `default_insert_only`,
the rest to `default`), each keyed by name, so a row is identical on every node
and replicates by value:

| Table | What replicates, and why a peer needs it |
|---|---|
| `coldfront.claims`, `coldfront.claim_acks` | The bakery's tickets and acknowledgements. A peer acknowledges an originator's claim by inserting into `claim_acks` on its own node, and the ack reaches the originator only if the table is in the peer's set. `claim_acks` goes in the insert-only set, because each node deletes only the ack copies it holds. |
| `coldfront.tiered_views` | The registry. A peer's hook recognizes a view by its row; without it the peer's writes through the view fail in PostgreSQL ("cannot insert into view") and its reads cannot attach the cold tier. |
| `coldfront.archive_watermark` | The hot/cold cutoff that routes each tiered write. |
| `coldfront.storage_secret` | The cold-store credential, so one `set_storage_secret` call reaches every node. |
| `coldfront.partition_config` | The per-table lifecycle. The archiver and the partitioner add this table themselves as well, because the partitioner runs without the extension. |
| `coldfront.vector_config`, `coldfront.vector_centroids` | The cluster routing state, so every node resolves a vector to the same cluster. |

Two tables stay local by design and are not added: `coldfront.deferred_acks`
(each node's queue of the acks it owes) and `coldfront._dummy_dml_target`.

The call runs on every node because a replication set is a property of the
provider: each node sends the rows of the tables in its own set, and a node
that skipped the step keeps its acks, registry rows and secret to itself. It
cannot run at `CREATE EXTENSION` time, because `spock.repset_add_table` needs
the local Spock node, and nothing runs it later on a node's behalf:
provisioning a table, setting the secret and writing cold rows all assume it
has run. It is idempotent, so running it again is harmless, and a node added to
the mesh later runs the same three steps.

A skipped step shows up late and away from the node that skipped it. If a peer
never ran it, the originator of every cold write waits at the ack barrier for
an ack that never arrives. If the node that registers a table never ran it,
the view reaches each peer as replicated DDL but the registry row does not, so
the peer's writes through the view fail with "cannot insert into view". A
secret set on such a node stays on that node.

Verify the step on every node. The query lists the eight tables:

```sql
SELECT c.relname
  FROM spock.replication_set rs
  JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
  JOIN pg_class c ON c.oid = rst.set_reloid
 WHERE rs.set_name = 'default' AND c.relnamespace = 'coldfront'::regnamespace
 ORDER BY 1;
```

Then verify the mesh before benching - insert a sentinel claim on each node
and read it back from every other node. All N×(N-1) directions must show the
row before traffic starts. `ci/journey.sh` `story_mesh_substrate` is a
copyable reference: it checks the membership above on every node and then the
sentinels.

## Tuning Knobs

The following GUCs adjust write behavior and execution; tune them as needed:

- `coldfront.allow_mixed_writes` (bool, default `on`) controls what happens for
  tiered-mode `UPDATE`/`DELETE` whose WHERE cannot be proven to target one
  tier. `on` emits a dual-tier CTE; `off` rejects with an error and a hint. The
  setting is not relevant in decoupled mode (every write is single-tier by
  definition).
- `coldfront.cold_write_batch_size` (int, default `10000`, minimum `1`) sets
  how many cold rows a tiered `INSERT` gathers (see [Caveats](#caveats)) before
  it writes them to Iceberg as one `INSERT`. A larger value writes fewer,
  larger Parquet files, and the remainder always flushes, so a small write
  stays one file.
- `coldfront.vector_probe` (bool, default `on`) sets whether a recognized
  similarity search reads only the clusters nearest its query vector. `off`
  gives an exact scan of the whole corpus. The setting affects only a table
  with a trained vector column ([usage_vectors.md](usage_vectors.md)).
- `coldfront.vector_nprobe` (int, default `0`) sets how many clusters such a
  search reads, overriding the column's own `nprobe`. `0` uses the configured
  value; at or above the column's `nlist` the search is exhaustive.
- Benchmark `duckdb.force_execution` (default off) before you turn it on: on a
  mixed workload it helps `count(distinct)` and similar but regresses index
  lookups, top-K with PK ordering, and JSON access.
- `duckdb.temporary_directory` sets where DuckDB spills. Each backend gets its
  own subdirectory there, named after its process id, so concurrent spills
  cannot collide; one left by a departed backend is reclaimed. See
  [architecture.md](architecture.md#duckdb-spill-files-are-not-namespaced-per-instance).
- `duckdb.max_temp_directory_size` is a cap **per connection**, not a cluster
  total, and when unset the cap is 90% of free space per session. For a total
  budget, divide it by the concurrent sessions or give the temp path its own
  filesystem or quota.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Architecture](architecture.md) overview describes the tiered
  architecture, the watermark, the archiver, transparent `UPDATE`/`DELETE`, and
  concurrency.
- The [Decoupled Mode](architecture_decoupled.md) deep dive describes
  decoupled-mode internals, the ACID model, and distributed scaling.
- The [Embeddings](usage_vectors.md) guide covers storing and searching
  embeddings through the pgvector interface.
- The [Compaction](compaction.md) guide covers cold-tier maintenance:
  compaction, snapshot expiry, and orphan-file removal.
