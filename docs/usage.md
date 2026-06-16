# Using coldfront

ColdFront offers two operating modes. Pick one per table; both can coexist
in the same database. The two modes compare as follows:

| | Tiered (hot + cold) | Decoupled (iceberg-only) |
|---|---|---|
| **Where rows live** | Hot in PG heap (recent), cold in Iceberg (archived) | Everything in Iceberg |
| **Setup** | Create a partitioned table; let the archiver convert it on first run | One SQL call: `coldfront.create_iceberg_table(...)` |
| **Archiver** | Required (cron, moves old partitions to cold) | Not used |
| **Best when** | Workload has a recent-row OLTP part that benefits from PG indexes + transactional ergonomics | Pure analytic / append-mostly; you want zero PG storage and stateless compute |

Once the table exists, **the SQL surface is identical**: `SELECT`,
`INSERT`, `UPDATE`, `DELETE` all work normally against the relation name
(e.g. `events`).

## Prerequisites (both modes)

The stack must already be running with PG + pg_duckdb + coldfront +
Lakekeeper + S3-compatible storage: three services - PostgreSQL +
pg_duckdb, Lakekeeper, and any S3-compatible object store (SeaweedFS,
MinIO, GCS, etc.). The one-time setup below brings it up and bootstraps
it.

## One-time setup

Bring up the end-user stack (the example uses SeaweedFS; host ports are
published so the `localhost` commands below work directly). For the image
build itself, see [installation.md](installation.md):

```bash
docker compose up -d --build
```

Then bootstrap Lakekeeper, create the warehouse, and pre-create the
Iceberg namespace:

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
#    deferred to transaction COMMIT but CREATE TABLE is POSTed eagerly, so
#    coldfront.create_iceberg_table — which runs both in one
#    transaction — would 404 against a cold warehouse. Pre-creating the
#    namespace here (its own committed REST call) makes the function's in-txn
#    CREATE SCHEMA IF NOT EXISTS a no-op so the table create succeeds. The
#    archiver (tiered mode) creates the namespace itself and does not need this.
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H "Content-Type: application/json" -d '{"namespace": ["default"]}'
```

Then install the extensions and set the cold-tier credentials, once per
database:

```sql
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
```

The secret is stored in the `coldfront.storage_secret` table (excluded
from `pg_dump`, replicated by value across a Spock mesh) and materialized
as a DuckDB PERSISTENT SECRET that loads at instance init. There is **no
per-session setup**: the Iceberg catalog `ice` attaches **lazily** by the
coldfront C hook on the first query that touches a tiered/decoupled view
(read or write).

For a real cloud-S3 setup, see [object_store.md](object_store.md).

## Mode 1 - Tiered (hot + cold)

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

List it in the archiver config:

```yaml
# config.yaml
archiver:
  tables:
    - source_table: events
      partition_period: monthly
      hot_period: 1 month          # tier hot PG → cold Iceberg past this age
      # retention_period: 5 years  # optional: DROP cold data past this age
      #                            # (must exceed hot_period; omit = keep forever)
```

Run the archiver (typically via cron):

```bash
./bin/archiver --config config.yaml
```

The first run renames `events` → `_events`, creates the unified view
`events`, and registers it. From then on every cycle (1) tiers
partitions older than `hot_period` from hot PG to cold Iceberg and
advances the watermark, and (2) if `retention_period` is set, drops cold
Iceberg rows older than it. The data lifecycle is **hot → `hot_period` →
cold → `retention_period` → gone**; omit `retention_period` to keep cold
data forever.

### 2-level (LIST → RANGE) tiered tables

A table partitioned `LIST (region) → RANGE (ts)` can be tiered too - the
same `sub_partition` block as the standalone partition manager (Mode 3),
so a partition-manager-managed table can be "upgraded" to tiered by
pointing the archiver at it:

```yaml
    - source_table: regional
      partition_column: ts          # the RANGE (time) column — required for 2-level
      partition_period: monthly
      hot_period: 1 month
      # retention_period: 5 years   # optional cold expiry (region-agnostic, by ts)
      sub_partition:
        values_source: "SELECT region FROM regions"
```

One Iceberg table holds every region (region is just a column); the
archiver tiers leaves a whole `ts` period at a time across **all**
regions before advancing the shared hot/cold watermark, so a period only
becomes cold once it is cold for every region. `id` mode is not supported
in tiered mode (the cold tier is time-keyed).

## Mode 2 - Decoupled (iceberg-only)

Single call:

```sql
SELECT coldfront.create_iceberg_table(
    p_schema  => 'public',
    p_table   => 'events',
    p_columns => '[
      {"name":"id",     "type":"bigint"},
      {"name":"ts",     "type":"timestamptz"},
      {"name":"status", "type":"text"},
      {"name":"data",   "type":"jsonb"}
    ]'::jsonb
);
```

That single statement provisions:

- `ice.default.events` on the attached Iceberg catalog
- a PG-side wrapper view `public.events` with proper PG-typed columns
- a `coldfront.tiered_views` registry row - every INSERT, UPDATE, and
  DELETE on the view is intercepted by the coldfront C hook and rewritten
  to a single `duckdb.raw_query(...)` against `ice.default.events`

Spock's `ddl_sql` repset replicates the `CREATE VIEW` and the registry
row, so the helper only needs to run on one node - peers pick up the
wrapper view, the `coldfront.tiered_views` row, and the
`coldfront.claims` repset registration automatically.

## Mode 3 - Standalone partition manager (no cold tier)

**You don't need Iceberg at all.** If automated PostgreSQL partition
maintenance is all you want - declarative time- or id-based RANGE
partitioning with a premade forward window and automatic age-out of old
partitions - ColdFront's `partitioner` binary is the whole product: stock
PostgreSQL (or a Spock mesh), no cold tier, no DuckDB, no Iceberg, nothing
to preload. Each invocation makes one reconcile pass per managed table:
premake the forward window, ensure the partition covering *now* exists,
and detach-then-drop partitions past retention (`DETACH ...
CONCURRENTLY`, never a bare `DROP` of attached data). Build it with `make
build` and run it from cron:

```bash
go build -o bin/partitioner ./cmd/partitioner   # or: make build
./bin/partitioner --config config.yaml
```

A partition-only config omits the `iceberg:` and `s3:` sections entirely
(supply either all of them or none - a half-filled cold config is
rejected):

```yaml
postgres:
  dsn: "host=localhost dbname=mydb"
archiver:
  tables:
    - source_table: events
      partition_column: ts
      partition_period: monthly        # monthly | daily
      retention_period: 12 months      # any PostgreSQL interval (12 months, 90 days, 1 year)
      future_partitions: 3             # premake window kept ahead of now
      expiration_strategy: drop         # drop (DETACH+DROP, destroy; default)
                                       #   | detach (DETACH only, keep as a
                                       #     standalone table — data preserved)
```

### Operating it

Schedule one pass per period or more often - a cron line, or a systemd
`oneshot` service plus timer (a failed pass then surfaces as a failed
unit, so alerting is free):

```text
17 * * * * postgres /usr/local/bin/partitioner --config /etc/coldfront/partitioner.yaml >> /var/log/coldfront-partitioner.log 2>&1
```

Keep the following operational behaviour in mind when scheduling it:

- **Exit codes.** `0` = every table reconciled (a self-healed *behind*
  condition still exits `0`); non-zero = at least one table failed
  (`N table(s) failed`), each logged with its `[schema.table]` prefix.
  Alert on non-zero.
- **Behind-detection.** If the table already has a *past* partition but
  none covers *now* at the start of a pass (a lagging cron - live inserts
  had no home), the pass heals it (creates the current partition), logs a
  `WARNING (self-healed)` line, and still exits `0`. Monitor for that
  warning in the log rather than via the exit code, and widen
  `future_partitions` or run more often. A fresh table (only just-premade
  future partitions) is **not** behind: its first reconcile succeeds
  cleanly.
- **Retention strategy.** With the default `expiration_strategy: drop`,
  expiry is `DETACH CONCURRENTLY` + `DROP TABLE` - the data is **gone**,
  so back up before shrinking `retention_period`. Set
  `expiration_strategy: detach` to instead leave the expired partition as
  a standalone table (detached from the parent, data preserved) and
  reclaim it yourself. A partition is expired only once its *entire*
  range is older than `now − retention_period`, computed with
  calendar-accurate PostgreSQL interval arithmetic (a real month, leap
  years correct). `detach` is partition-only - the tiered archiver always
  drops after exporting to cold.

### Primary keys on time-partitioned tables (id mode)

PostgreSQL requires a unique index to include the partition key, so a
plain `PRIMARY KEY (id)` is impossible on a table partitioned by a
separate `ts` column. Partition instead by RANGE on a **time-ordered id**
and the partition key *is* the key - a single-column `PRIMARY KEY (id)`:

```yaml
    - source_table: events
      partition_column: id
      partition_period: monthly
      retention_period: 12 months
      part_mode: id
      id_scheme: snowflake             # snowflake | uuidv7
```

`uuidv7` reads the RFC 9562 leading-millisecond timestamp; `snowflake`
decodes the pgEdge snowflake extension's layout. Either way the manager
computes the month/day partition bounds as id values, so id-order equals
time-order and the forward/retention schedule is unchanged.

### Two-level (LIST → RANGE) sub-partitioning

For a table partitioned by `LIST (region)` whose children are themselves
`RANGE`-partitioned by time, add a `sub_partition` block. `values_source`
is a query returning the current level-1 values; the manager provisions
and maintains a RANGE sub-tree under each, creating sub-trees for newly
appearing values automatically:

```yaml
    - source_table: events
      partition_column: ts             # the level-2 RANGE column
      partition_period: monthly
      retention_period: 12 months
      sub_partition:
        values_source: "SELECT code FROM regions"
```

## Managing partitioned tables (CLI)

ColdFront splits configuration into two kinds. **Connection** config -
the Postgres DSN, and (tiered archiver only) the Iceberg/S3 connection -
stays in a small per-node YAML and is never replicated. **Per-table
lifecycle** lives in `coldfront.partition_config`, a name-keyed table
that replicates by value across a Spock mesh (like
`tiered_views`/`archive_watermark`), so every node reads identical config
- no per-node file syncing. Manage it with the CLI below (both
`partitioner` and `archiver` expose these subcommands; with no subcommand
they do their normal reconcile/archive run).

The data lifecycle is **hot PG → `hot_period` → cold Iceberg →
`retention_period` → dropped** (tiered) or **hot PG → `retention_period`
→ dropped** (partition-only). Setting `hot_period` makes a table tiered;
omitting it makes it partition-only.

`hot_period` and `retention_period` are native PostgreSQL `interval`s -
use any interval syntax (`1 month`, `90 days`, `1 year 2 mons`, `5
years`). Expiry boundaries are computed with calendar-accurate interval
arithmetic (`now() - period`: real months, leap years), and
`retention_period` must exceed `hot_period` (validated at `register`/`set`
time).

The CLI exposes the following subcommands:

| Command | Purpose |
|---|---|
| `register` | add/adopt a table - validates the PRIMARY KEY covers the partition key |
| `list` | show managed tables and their lifecycle |
| `set` | change fields, or `--disable`/`--enable` a table |
| `remove` | stop managing a table (the table itself is left intact) |
| `import` | seed `partition_config` from a YAML's `archiver.tables` (migration) |
| `export` | dump the **active (enabled)** config to YAML or SQL - a git-reviewable copy |

```bash
# Partition-only: keep 3 future partitions, drop those older than 12 months.
partitioner register --config cf.yaml --table events --period monthly --retention "12 months"

# Partition-only, but DETACH (preserve) expired partitions instead of dropping them.
partitioner register --config cf.yaml --table events --period monthly \
    --retention "12 months" --strategy detach

# Tiered: tier to cold Iceberg after 1 month, then drop cold data after 5 years.
archiver register --config cf.yaml --table events --period monthly \
    --hot-period "1 month" --retention "5 years"

# id mode — a real single-column PRIMARY KEY (id) on a snowflake-keyed table.
partitioner register --config cf.yaml --table events --period monthly \
    --column id --part-mode id --id-scheme snowflake --retention "1 year"

# 2-level LIST(region) → RANGE(ts), tiered; region values come from a table.
archiver register --config cf.yaml --table regional --period monthly --column ts \
    --hot-period "1 month" --sub-values-source "SELECT region FROM regions"

partitioner list   --config cf.yaml                      # what's managed
partitioner set    --config cf.yaml --table events --retention "24 months"
partitioner set    --config cf.yaml --table events --disable   # pause (keeps the row)
partitioner remove --config cf.yaml --table events       # unregister, keep the table
partitioner import --config legacy.yaml                  # migrate a YAML's tables
partitioner export --config cf.yaml > managed.yaml       # active config, git-reviewable (--format sql for INSERTs)
```

Run `partitioner` (or `archiver`) with no arguments, `help`, or `--help`
for the command overview; every subcommand has detailed `--help` with
worked examples. The write commands accept `--print-sql` (emit the SQL
without running it - review/commit it) and `--dry-run`. `set
--enable`/`--disable` (mutually exclusive) pause/resume a table without
removing it; a disabled table is skipped by reconcile and omitted from
`export`. Per table, only the cadence and a destroy boundary are
required; `partition_column` is auto-detected from `pg_catalog` for flat
tables (required for 2-level). `register` writes a row whose `CHECK`
constraints enforce the lifecycle rules at write time.

**YAML `archiver.tables` still works** as a deprecation bridge: when
`partition_config` is empty the binaries fall back to a YAML table list.
Move off it with `import`.

## Storage backends

Configure **exactly one** cold-store backend:

- **S3** - any S3-compatible store (SeaweedFS, MinIO). Set `endpoint`,
  `use_ssl: true` for a TLS endpoint, and `url_style: path` (default) or
  `vhost`.
- **Virtual-hosted cloud S3** (AWS S3 is the canonical one) - **omit
  `endpoint`** (and the `endpoint` arg to `set_storage_secret`) so DuckDB
  uses the native per-Region virtual-hosted + HTTPS addressing; just set
  `region` to your bucket's Region. This is **required** for Regions
  launched after 2019-03-20 (e.g. `ap-south-2`), whose DNS does not route
  path-style requests and returns HTTP 400. The Lakekeeper warehouse
  profile must be a virtual-hosted `s3` profile (`flavor: aws`,
  `path-style-access: false`, no custom endpoint); the full walkthrough is [object_store.md](object_store.md).
- **Google Cloud Storage** - *not a separate backend*: use `s3:` pointed
  at GCS's S3-interoperability endpoint with an [HMAC key pair](https://cloud.google.com/storage/docs/authentication/hmackeys)
  (`endpoint: storage.googleapis.com`, `use_ssl: true`,
  `access_key`/`secret_key` = the HMAC id/secret). Lakekeeper's warehouse
  uses an `s3` profile (`flavor: s3-compat`, `path-style`) at the same
  endpoint. Verified end-to-end (iceberg read+write over interop).
  Lakekeeper's native `gcs` profile is service-account only and is
  **not** used.
- **Azure ADLS Gen2** - a supported cold-store backend; the access key
  rides inside `connection_string`.

For an **Azure ADLS Gen2** cold tier, set the credential with
`set_storage_secret_azure()` instead of `set_storage_secret()` - it takes
a CONFIG-provider connection string. The storage-account access key rides
inside `AccountKey=…`; the DuckDB azure secret has no separate
account-key parameter, so shared-key auth lives entirely in the
connection string:

```sql
SELECT coldfront.set_storage_secret_azure(
    'DefaultEndpointsProtocol=https;AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net');
```

It writes the same `coldfront.storage_secret` row (replicated,
`pg_dump`-excluded) and materializes a `TYPE azure` PERSISTENT SECRET.
The Azure cold tier is subject to the soft-delete / change-feed
restriction in [Gotchas](#gotchas).

## Reading + writing (identical for both modes)

The same SQL works against the relation name in either mode, as the
following examples show:

```sql
-- Reads — pg_duckdb handles the iceberg side; PG handles the heap side
SELECT count(*) FROM events;
SELECT id, status, data->>'k' FROM events WHERE ts >= '2026-04-01';

-- Inserts, updates, and deletes all go through the coldfront C hook,
-- which rewrites the query into one PG-set-based statement (hot side)
-- + one duckdb.raw_query (cold side). For iceberg-only mode every write
-- goes cold; for tiered mode the hook splits by ts vs the watermark.
INSERT INTO events (ts, status, data) VALUES (now(), 'ok', '{"k":1}');
UPDATE events SET status = 'fixed' WHERE id = 123;
DELETE FROM events WHERE ts < '2025-01-01';

-- Bulk INSERT shapes are all set-based — no per-row work:
INSERT INTO events (ts, status, data) VALUES (...), (...), (...);
INSERT INTO events (ts, status, data) SELECT ts, status, data FROM staging;
INSERT INTO events (ts, status, data) SELECT now() + i*'1s'::interval, 'ok', '{}'
                                       FROM generate_series(1, 1000) i;

-- Transactions work; ROLLBACK undoes Iceberg writes too
BEGIN;
  UPDATE events SET status = 'pending' WHERE id = 1;
  SELECT status FROM events WHERE id = 1;   -- sees 'pending' (read-your-own-write)
ROLLBACK;
SELECT status FROM events WHERE id = 1;     -- back to whatever it was
```

## Supported column types

The following PostgreSQL column types are supported:

`bigint` · `integer` · `smallint` · `real` · `double precision` ·
`boolean` · `timestamp with time zone` · `timestamp without time zone` ·
`date` · `time without time zone` · `uuid` · `text` · `varchar(N)` ·
`char(N)` · `bytea` · `oid` · `numeric(P,S)` (P ≤ 38) · `jsonb` / `json` ·
`interval`

Anything else (unbounded `numeric`, `xml`, `tsvector`, range/multirange
types, custom enums, arrays, composite types) is rejected at
table-creation time. We refuse silent fallback to `varchar` - losing
precision/identity is worse than no support.

`jsonb`, `json` and `interval` are stored as `varchar` in Iceberg (no
native primitive) and view-cast back to the rich PG type on read. Queries
like `data->>'key'` work; jsonb-only operators (`?`, `@>`) need an
explicit `data::jsonb` cast.

`inet`/`cidr` are **not supported**: pg_duckdb cannot process PG `inet`
(Oid 869) in any Iceberg-backed query, and every cross-tier read is
planned by pg_duckdb - so no cast makes them readable. Store IP data as
`text` (you can still index/compare it; cast to `inet` in your own
queries on the hot side only if needed).

## Gotchas

Keep the following caveats in mind when running either mode:

- **`jsonb` reads**: surface as `json`, not `jsonb`. Most operators
  work; the binary-only ones don't.
- **Cross-tier isolation**: a long-running `SELECT` that touches the
  Iceberg side multiple times within one transaction may see writes from
  other sessions interleaved between scans. PG's repeatable-read does not
  extend across the pg_duckdb boundary. Read-your-own-write *within* one
  tx works (verified) - it's only cross-statement consistency vs.
  concurrent writers that's weaker.
- **Crash-mid-commit (decoupled mode)**: if a backend crashes between
  Iceberg snapshot commit and PG commit, S3 objects can be orphaned.
  Iceberg housekeeping reclaims them - not corrupting, but a real failure
  mode.
- **Concurrent writes from multiple PG nodes (decoupled mode)**:
  serialized PG-side by the bakery protocol - every iceberg-only INSERT
  goes through `coldfront._exec_iceberg_with_claim`, which holds a
  globally-ordered snowflake ticket and waits for its turn before
  committing to Lakekeeper. No 409 conflicts, no app-level retry. The
  protocol is Lamport-1978 mutex with the Ricart-Agrawala (1981)
  deferred-reply optimisation; claims and acks replicate as Spock rows
  and it stays safe under Spock's asymmetric apply (modelled in [docs/formal/Bakery_v2.tla](https://github.com/pgEdge/ColdFront/blob/main/docs/formal/Bakery_v2.tla)). The bakery requires the `dblink` + `snowflake`
  extensions, the `coldfront.dblink_self` GUC, and a one-time `SELECT
  coldfront._ensure_claims_replicated()` call on every node after spock
  mesh setup; see [architecture_decoupled.md](architecture_decoupled.md#concurrency--horizontal-scaling--the-bakery-protocol). Sync-rep is **not** required.
  The throughput ceiling is Lakekeeper's commit rate, not the writer
  count.
- **Direct table access**: `_events` is the hot heap (tiered mode only).
  `ice.default.<name>` is the Iceberg table - only addressable via
  `iceberg_scan(...)` or `duckdb.raw_query('… ice.… …')`, never via
  PG-native 3-part names.
- **Tiered INSERT with omitted IDENTITY column** (e.g. `INSERT INTO
  events (ts, status, data) VALUES …` where `id` is `GENERATED ALWAYS AS
  IDENTITY`): the cold side falls back to a plpgsql cursor loop that
  calls `nextval()` per row so cold ids share the hot side's sequence.
  Correctness is full; throughput is lower than the set-based fast path.
  Either supply `id` explicitly in the INSERT, or use a partition-column
  predicate that proves the rows are all hot, to stay on the fast path.
  For very large historical seeds (mostly-cold), prefer iceberg-only mode
  where ids come from your source data.

## Distributed setup (3-node mesh, decoupled mode)

For multi-writer iceberg workloads, run coldfront on N PG nodes in a
Spock mesh against the same Lakekeeper + S3. The bakery serializes
commits PG-side so writers never collide at the catalog.

### Per-node `postgresql.conf`

The configuration below applies to each node in the mesh:

```ini
wal_level = logical
shared_preload_libraries = 'snowflake,spock,pg_duckdb,coldfront'

# Keep pg_stat_replication.reply_time fresh on every walsender.  PG
# default is 10 s; with the bakery's 5 s liveness window that would
# false-positive every idle peer as "dead" on the first claim after a
# quiet period.  1 s leaves comfortable margin.
wal_receiver_status_interval = 1s

# Per-node — distinct integer 1..1023.  MUST equal
# (hashtext(<spock node_name>) & 1023); the bakery alignment check raises
# at first claim if these disagree.
snowflake.node = 1

# DSN used by the bakery's autonomous-tx claim INSERT/DELETE via dblink.
# Unix socket avoids TCP overhead. The claim session only touches the
# coldfront.claims/claim_acks heap tables, so it never attaches the
# Iceberg catalog (the lazy catalog-attach hook fires only on a tiered
# view). application_name=coldfront_dblink marks the session as bakery
# traffic.
coldfront.dblink_self = 'host=/tmp dbname=coldfront user=coldfront application_name=coldfront_dblink'

coldfront.warehouse = 'wh'
coldfront.lakekeeper_endpoint = 'http://lakekeeper:8181/catalog'
```

The bakery has no peer-ack timeout. R-A's only failure mode is a dead
peer (would wait forever), closed by a liveness check inside the
wait-loop: a peer whose `pg_stat_replication.reply_time` is older than
`coldfront.peer_alive_window_ms` (default `5000`) is implicitly treated
as already-acked. Raise this on slow/lossy WAN links if false-positive
dead-peer rulings become a problem. An alive peer that hasn't acked is
either deferring legitimately (R-A's defer rule) or about to ack - either
way, waiting is correct, not a failure.

Sync-rep (`synchronous_standby_names`) is **not required** by the bakery
- the R-A ack barrier replaces it. You can still enable it cluster-wide
if you want stronger durability for non-bakery writes, but it's no longer
load-bearing for iceberg-commit serialisation.

**One-time mesh setup** - must be done in this order on every node,
because `coldfront._ensure_claims_replicated()` calls
`spock.repset_add_table` and so requires the local spock node to already
exist:

```sql
-- 1. Extensions, in dependency order. dblink + snowflake are bakery
-- prereqs (R-A's autonomous-tx claim/ack INSERTs go through dblink;
-- claim tickets come from snowflake.nextval).
CREATE EXTENSION IF NOT EXISTS dblink;
CREATE EXTENSION IF NOT EXISTS snowflake;
CREATE EXTENSION IF NOT EXISTS spock;
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- 2. Spock node + full-mesh subscriptions (each node has N-1 subs).
SELECT spock.node_create('n<i>', 'host=<this_node_priv_ip> user=coldfront dbname=coldfront port=5432');

-- on n1 (n2 and n3 symmetric):
SELECT spock.sub_create('sub_n1_from_n2', 'host=<n2> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);
SELECT spock.sub_create('sub_n1_from_n3', 'host=<n3> user=coldfront dbname=coldfront port=5432',
                        ARRAY['default','default_insert_only','ddl_sql'],
                        false, false, '{}', '0', false);

-- 3. **Required** on every node, after spock setup: register the R-A
-- bakery tables (coldfront.claims + coldfront.claim_acks) in the local
-- node's default repset.  Without this on a peer, the peer's ack INSERTs
-- never replicate back to the originating writer and every claim
-- ack-waits to timeout.
SELECT coldfront._ensure_claims_replicated();
```

`synchronize_structure := false, synchronize_data := false` - tables
already exist on every node from the coldfront extension; no initial copy
needed.

**Verify before benching** - insert a sentinel claim on each node and
read it back from every other node. All N×(N-1) directions must show the
row before traffic starts. `ci/journey.sh` `story_mesh_substrate` is a
copyable reference.

## Tuning knobs

The following GUCs adjust write behaviour and execution; tune them as needed:

- `coldfront.allow_mixed_writes` (bool, default `on`) - controls what
  happens for tiered-mode UPDATE/DELETE whose WHERE can't be proven to
  target one tier. `on` emits a dual-tier CTE; `off` rejects with an error
  and a hint. Not relevant in decoupled mode (every write is single-tier
  by definition).
- `duckdb.force_execution` - bench it before flipping: on a mixed
  workload it helps `count(distinct)` and similar but regresses index
  lookups, top-K with PK ordering, and JSON access. **Default off.**

## Going deeper

For deeper detail on each mode's internals, see the architecture references:

- Tiered architecture, watermark, archiver, transparent UPDATE/DELETE, concurrency: [architecture.md](architecture.md).
- Decoupled mode internals, ACID model, distributed scaling: [architecture_decoupled.md](architecture_decoupled.md).
