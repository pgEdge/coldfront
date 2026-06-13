![pgEdge Labs](assets/pgEdge_labs_178px.png)

# pgEdge ColdFront

Tables in PostgreSQL, storage in Apache Iceberg (Parquet on S3-compatible
storage). Two operating modes, both queried as ordinary PG relations:

- **Tiered (hot + cold)** — recent data in native PG partitions, old data
  archived to Iceberg on a watermark; the application sees a unified view.
  The archiver moves rows hot → cold on a cron.
- **Decoupled (iceberg-only)** — the table lives entirely in Iceberg from
  row 1; PG holds a thin wrapper view and a registry row that arms the
  coldfront hook to handle every DML on the view. No archiver, no PG
  storage for the data, no watermark. Scales out horizontally to N PG
  nodes pointing at one Lakekeeper + S3; the **bakery protocol** in
  the coldfront extension serializes iceberg commits PG-side via
  Spock-replicated snowflake tickets so concurrent writers never
  collide at the catalog. Implementation is Lamport-1978 + Ricart–
  Agrawala over Spock's per-origin FIFO apply; safety properties are
  TLC-checked in [docs/formal/Bakery_v2.tla](docs/formal/Bakery_v2.tla).

Both modes coexist per-database, picked per-table at creation time. SQL
surface is identical for both: standard SELECT/INSERT/UPDATE/DELETE on
the named relation.

User-level setup and DML examples for both modes: **[USAGE.md](USAGE.md)**.

## How It Works

```
Application
  │
  ├── SELECT * FROM events             ← reads hot + cold transparently
  ├── INSERT INTO events ...            ← coldfront rewrites: hot via PG, cold via raw_query
  ├── UPDATE events SET ... WHERE ...   ← coldfront rewrites to the right tier
  └── DELETE FROM events WHERE ...      ← coldfront rewrites to the right tier
         │
┌────────▼──────────────────────────────────────────────────┐
│  PostgreSQL 16/17/18 + pg_duckdb + coldfront extensions    │
│                                                            │
│  _events (renamed partitioned table, hot data)             │
│  ├── p_2026_04  (hot, native PG)                           │
│  ├── p_2026_05  (hot, native PG)                           │
│  └── ...                                                   │
│                                                            │
│  events  VIEW (replaces original table — hot + cold)       │
│  + INSTEAD OF INSERT trigger (fallback only — bypassed     │
│    when coldfront is preloaded)                            │
│  + archive_watermark table (cutoff boundary)               │
│  + coldfront.tiered_views catalog                          │
│                                                            │
│  coldfront extension: rewrites INSERT / UPDATE / DELETE    │
│  on tiered views — hot side stays plain set-based PG,      │
│  cold side becomes one duckdb.raw_query (or a plpgsql      │
│  cursor loop when an IDENTITY column is omitted)           │
│                                                            │
│  pg_duckdb: intercepts iceberg_scan() queries,             │
│  handles Iceberg reads via DuckDB engine in-process        │
└────────┬──────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  Lakekeeper (Iceberg REST catalog, single Rust binary)     │
│  Backed by same PostgreSQL instance                        │
└────────┬──────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  S3-compatible object store (AWS S3, SeaweedFS, MinIO, etc.) │
│  Parquet data files + Iceberg metadata                     │
└───────────────────────────────────────────────────────────┘
         │
┌────────▼──────────────────────────────────────────────────┐
│  Archiver (~9 MB static Go binary, no CGO, runs via cron)  │
│  Moves expired PG partitions → Iceberg, updates watermark  │
└───────────────────────────────────────────────────────────┘
```

## Installation

> ### 📦 Packages — coming with the Beta release
>
> With the Beta release, ColdFront installs from **pgEdge package
> repositories**: the PostgreSQL `coldfront` extension (with its pg_duckdb +
> patched-iceberg dependencies) and the `archiver` binary, via your platform's
> package manager. This section will carry the exact repo setup + install
> commands once the packages are published.
>
> <!-- STUB — fill in once the Beta packages are published:
>   RHEL / Rocky:      dnf install coldfront           (package names + repo TBD)
>   Debian / Ubuntu:   apt install coldfront
>   Container image:   docker pull ghcr.io/pgedge/coldfront:<pg>   (public image TBD)
> -->

**Build from source** — the full build workflow lives in
**[INSTALL.md](INSTALL.md)**: build the DuckDB-1.5.x base + the coldfront layer
with one `docker build`, or install bare-metal. Then continue with the
Quickstart below.

**On AWS S3?** Once the image is built, the **[AWS S3 walkthrough](AWS_S3.md)**
takes you from an empty bucket to a working cold tier end-to-end.

## Quickstart

The walkthrough below covers **tiered mode**. For **decoupled (iceberg-only)** —
one SQL call provisions a wrapper view over a fresh Iceberg table and
arms the coldfront hook to handle every DML on it; no archiver
involved — see [USAGE.md → Mode 2](USAGE.md#mode-2--decoupled-iceberg-only)
and [ARCHITECTURE_DECOUPLED.md](ARCHITECTURE_DECOUPLED.md).

### 1. Convert your partitioned table

Point the archiver at your existing partitioned table and run it:

```yaml
# config.yaml
archiver:
  tables:
    - source_table: "events"       # your existing partitioned table
      partition_period: "monthly"
      retention_period: "3 months"
```

```bash
./bin/archiver --config config.yaml
```

The archiver automatically:
- Renames `events` → `_events`
- Creates a unified view named `events` (reads hot + cold transparently)
- Archives expired partitions to Iceberg
- Registers the view with coldfront so the C hook handles every DML on it (an INSTEAD OF INSERT trigger is also installed as a defensive fallback)

Your application keeps using `events` — no code changes needed for reads.

### 2. Read data (hot + cold, transparent)

```sql
-- Same queries as before, transparently spans hot and cold:
SELECT * FROM events;
SELECT * FROM events WHERE ts > '2026-01-01';
SELECT count(*) FROM events WHERE status = 'error';
```

- **Hot-only queries**: PG partition pruning, never touches Iceberg
- **Cold-only queries**: DuckDB Iceberg pruning + Parquet row group skipping
- **Cross-tier queries**: seamless UNION ALL
- With `duckdb.force_execution = true`, hot queries also get DuckDB's
  vectorized engine (10-100x faster for analytics)
- **`jsonb` note**: returned as `json` (not `jsonb`) through the view,
  because DuckDB has no native `jsonb` type. Standard access (`->>`,
  `->`, `#>`) works without a cast; jsonb-only operators (`?`, `@>`,
  containment, de-dup) need an explicit `data::jsonb` in the caller's
  query.

### 3. Write data

All four verbs — INSERT, UPDATE, DELETE, SELECT — go through `events`.
No `_events`, no `duckdb.raw_query()` in application code.

| Operation | Syntax | Notes |
|---|---|---|
| **SELECT** | `SELECT FROM events` | pg_duckdb UNION ALL across hot + cold |
| **INSERT** | `INSERT INTO events (...)` | coldfront hook splits hot/cold by `ts` vs the watermark; hot rows go set-based to `_events`, cold rows go through one bulk `duckdb.raw_query` (or a plpgsql cursor loop when an IDENTITY column is omitted) |
| **UPDATE** | `UPDATE events SET ... WHERE ...` | coldfront rewrites based on the WHERE clause (see below) |
| **DELETE** | `DELETE FROM events WHERE ...` | coldfront rewrites based on the WHERE clause (see below) |

```sql
-- Hot rows (ts >= watermark): plain PG UPDATE on _events
UPDATE events SET status = 'fixed' WHERE ts = '2026-04-01 12:00+00';

-- Cold rows (ts < watermark): hook rewrites to SELECT duckdb.raw_query(...)
UPDATE events SET status = 'fixed' WHERE ts = '2026-01-15 01:00+00';

-- IN / BETWEEN / OR all work if every value proves one tier
UPDATE events SET status = 'archived'
  WHERE ts BETWEEN '2026-01-01' AND '2026-02-01';

-- Ambiguous predicate (no ts constraint) — permissive mode writes to both
-- tiers in one statement via a dual-tier CTE:
UPDATE events SET status = 'fixed' WHERE id = 123;
```

#### Strict vs permissive modes

`coldfront.allow_mixed_writes` (bool, default `on`) controls what happens
when the WHERE clause can't be proven to target a single tier:

- **Permissive (`on`, default)**: a dual-tier CTE writes to both sides in
  one statement.  `ROLLBACK` undoes both (pg_duckdb ties the DuckDB
  transaction to PG's via XactCallback).  Not crash-safe — a mid-commit
  crash can orphan S3 objects that Iceberg housekeeping later reclaims.
- **Strict (`off`)**: the extension raises an `ERROR` with a hint pointing
  at the partition column and asks the caller to narrow the WHERE clause.
  Recommended when you want every write attributable to exactly one tier.

```sql
SET coldfront.allow_mixed_writes = off;
UPDATE events SET status = 'x' WHERE id = 123;
-- ERROR:  UPDATE/DELETE on tiered view "events" must include a
-- WHERE condition on "ts" that targets one tier
-- HINT:  Use "ts >= <value>" for hot-tier writes, "ts < <value>" for
-- cold-tier writes, or set coldfront.allow_mixed_writes = on to permit
-- a non-atomic dual-tier rewrite.
```

See [ARCHITECTURE_TIERED.md](ARCHITECTURE_TIERED.md) — "Transparent UPDATE/DELETE" —
for the full rewrite rules and the classifier's predicate coverage, and its
"Tiered-specific limitations" for the cosmetic regressions (command tag, cold
RETURNING) in permissive mode.

#### Schema changes (DDL)

Column-shape changes on a tiered table are **blocked**: duckdb-iceberg
cannot `ALTER` an Iceberg table, so coldfront refuses
`ADD`/`DROP COLUMN`, `ALTER COLUMN ... TYPE`, and `RENAME COLUMN` rather than
let the hot and cold tiers diverge. Renaming the hot table or the view **is**
supported (neither touches the Iceberg schema).

| DDL | What coldfront does |
|---|---|
| `ALTER TABLE _events ADD/DROP COLUMN`, `ALTER COLUMN ... TYPE`, `RENAME COLUMN` | **Blocked** with an actionable error — to change the schema, untier the table, alter it, then re-tier. |
| `ALTER TABLE _events RENAME TO _events2` | Supported — updates the registry's `hot_table`, rebuilds the view. |
| `ALTER VIEW events RENAME TO events2` | Supported — migrates the name-keyed registry + watermark rows to the new name, rebuilds the view (so the cold tier survives the rename). |

```sql
ALTER TABLE _events ADD COLUMN payload jsonb;
-- ERROR:  coldfront: cannot alter columns of tiered table "public._events" —
--         its cold tier in Iceberg cannot be altered
```

`DROP TABLE` / `DROP VIEW` / `TRUNCATE` on a tiered table are **blocked by
design** — they would orphan or hide cold data on a multi-tier, multi-node
setup, so dismantling tiering is a deliberate operator action, never a
one-shot call:

```sql
DROP TABLE _events;
-- ERROR:  coldfront: cannot DROP "public._events" — it has a cold tier in Iceberg
-- HINT:  Blocked by design: the Iceberg cold tier would be orphaned. Removing a
--        tiered table is a deliberate operation — unregister it from
--        coldfront.tiered_views and drop each tier explicitly.
```

The Iceberg mirror runs only when `coldfront.warehouse` is configured.
In an active-active Spock mesh each node rebuilds its own local view from
the replicated `ALTER TABLE`; see
[ARCHITECTURE.md](ARCHITECTURE.md) — "Transparent DDL" — for the details.

#### Troubleshooting: direct access paths

If you hit an edge case the classifier doesn't cover, these paths stay
available:

```sql
-- Direct hot-side DML:
UPDATE _events SET status = 'fixed' WHERE id = 123;

-- Direct cold-side DML (requires an ATTACH; coldfront.ensure_attached()
-- handles it when coldfront.warehouse / .lakekeeper_endpoint GUCs are set):
SELECT duckdb.raw_query($$UPDATE ice.default.events
  SET status = 'fixed' WHERE id = 99$$);
```

## Archiver

Single static Go binary (~9 MB, CGO_ENABLED=0, no runtime, no daemon). Runs via cron.
Moves expired PG partitions to Iceberg:

1. Creates future partitions
2. Finds partitions older than the retention period
3. Exports each to Iceberg (PG → DuckDB temp table → Iceberg)
4. Updates the watermark
5. Renames source table and replaces with unified view (first run only)
6. Recreates view with new cutoff
7. Detaches and drops the archived partition

```bash
make build               # 9MB static binary
./bin/archiver --config config.yaml
```

### Table Swap

On the first run, the archiver atomically renames the source table
(e.g. `events` → `_events`) and creates a view with the original name.
The view combines hot data from `_events` with cold data via `iceberg_scan()`.
The coldfront C hook intercepts every DML on the view and routes it to
the correct tier (an INSTEAD OF INSERT trigger is installed as a
defensive fallback for environments where the extension isn't preloaded).

### Watermark Strategy

The archiver maintains a cutoff timestamp in `coldfront.archive_watermark`:
- Data with `ts >= cutoff` lives in PostgreSQL (hot)
- Data with `ts < cutoff` lives in Iceberg (cold)
- Cutoff is derived from the partition's mathematical upper bound
  (from `pg_catalog`), not from `MAX(ts)` — prevents boundary gaps

### Crash Recovery

The watermark is the single source of truth. If the archiver crashes:
- After Iceberg write, before watermark update → next run re-exports (safe)
- After watermark update, before view recreate → next run recreates view
- After view recreate, before partition drop → partition excluded by cutoff

## Configuration

ColdFront splits configuration into two kinds:

**Connection — per node, YAML.** The Postgres DSN, and (tiered archiver only) the
Iceberg/S3 connection. This stays in a small YAML and is never replicated:

```yaml
postgres:
  dsn: "host=localhost dbname=mydb user=myuser password=mypass sslmode=disable"
# tiered archiver only:
iceberg:
  warehouse: "wh"
  lakekeeper_endpoint: "http://lakekeeper:8181/catalog"
s3:
  endpoint: "seaweedfs:8333"
  access_key: "admin"
  secret_key: "adminsecret"
```

#### Storage backends

Configure **exactly one** cold-store backend:

- **S3** (`s3:`) — any S3-compatible store (SeaweedFS, MinIO). Set `endpoint`,
  `use_ssl: true` for a TLS endpoint, and `url_style: path` (default) or `vhost`.
- **Real AWS S3** — **omit `endpoint`** (and the `endpoint` arg to
  `set_storage_secret`) so DuckDB uses AWS's native per-Region virtual-hosted +
  HTTPS addressing; just set `region` to your bucket's Region. This is **required**
  for Regions launched after 2019-03-20 (e.g. `ap-south-2`), whose DNS does not
  route path-style requests and returns HTTP 400. The Lakekeeper warehouse profile
  must be a real-AWS `s3` profile (`path-style-access: false`, no custom endpoint).
- **Google Cloud Storage** — *not a separate backend*: use `s3:` pointed at GCS's
  S3-interoperability endpoint with an [HMAC key pair](https://cloud.google.com/storage/docs/authentication/hmackeys)
  (`endpoint: storage.googleapis.com`, `use_ssl: true`, `access_key`/`secret_key`
  = the HMAC id/secret). Lakekeeper's warehouse uses an `s3` profile (`flavor:
  s3-compat`, `path-style`) at the same endpoint. Verified end-to-end (iceberg
  read+write over interop). Lakekeeper's native `gcs` profile is service-account
  only and is **not** used.
- **Azure ADLS Gen2** (`azure:`) — requires the DuckDB 1.5.x build (see
  [INSTALL.md](INSTALL.md)); the access key rides inside `connection_string`.

**Per-table lifecycle — `coldfront.partition_config`.** Which tables are managed
and their lifecycle live in a name-keyed table that replicates by value across a
Spock mesh (like `tiered_views`/`archive_watermark`), so every node reads
identical config — no per-node file syncing. Manage it with the CLI below
(both `partitioner` and `archiver` expose these subcommands; with no subcommand
they do their normal reconcile/archive run).

### Managing partitioned tables (CLI)

The data lifecycle is **hot PG → `hot_period` → cold Iceberg → `retention_period`
→ dropped** (tiered) or **hot PG → `retention_period` → dropped** (partition-only).
Setting `hot_period` makes a table tiered; omitting it makes it partition-only.

| Command | Purpose |
|---|---|
| `register` | add/adopt a table — validates the PRIMARY KEY covers the partition key |
| `list` | show managed tables and their lifecycle |
| `set` | change fields, or `--disable`/`--enable` a table |
| `remove` | stop managing a table (the table itself is left intact) |
| `import` | seed `partition_config` from a YAML's `archiver.tables` (migration) |
| `export` | dump the **active (enabled)** config to YAML or SQL — a git-reviewable copy |

```bash
# Partition-only: keep 3 future partitions, drop those older than 12 months.
partitioner register --config cf.yaml --table events --period monthly --retention "12 months"

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

Run `partitioner` (or `archiver`) with no arguments, `help`, or `--help` for the
command overview; every subcommand has detailed `--help` with worked examples.
The write commands accept `--print-sql` (emit the SQL without running it —
review/commit it) and `--dry-run`. `set --enable`/`--disable` (mutually
exclusive) pause/resume a table without removing it; a disabled table is skipped
by reconcile and omitted from `export`. Per table, only the cadence and a destroy
boundary are required; `partition_column` is auto-detected from `pg_catalog` for
flat tables (required for 2-level). `register` writes a row whose `CHECK`
constraints enforce the lifecycle rules at write time.

**YAML `archiver.tables` still works** as a deprecation bridge: when
`partition_config` is empty the binaries fall back to a YAML table list. Move off
it with `import`.

## Infrastructure

Three services: PostgreSQL + pg_duckdb, Lakekeeper, and any S3-compatible
object store (SeaweedFS, MinIO, AWS S3, GCS, etc.).

```bash
# Build the image first (DuckDB 1.5.x stack) — see INSTALL.md — then start the
# end-user stack (example uses SeaweedFS; host ports are published so the
# localhost commands below work directly):
docker compose up -d --build
```

### One-time setup

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
#    REQUIRED for decoupled (iceberg-only) mode on DuckDB 1.5.x: that release
#    defers an Iceberg CREATE SCHEMA to transaction COMMIT but POSTs CREATE
#    TABLE eagerly, so coldfront.create_iceberg_table — which runs both in one
#    transaction — would 404 against a cold warehouse. Pre-creating the
#    namespace here (its own committed REST call) makes the function's in-txn
#    CREATE SCHEMA IF NOT EXISTS a no-op so the table create succeeds. The
#    archiver (tiered mode) creates the namespace itself and does not need this.
WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
curl -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H "Content-Type: application/json" -d '{"namespace": ["default"]}'
```

### Database setup

```sql
-- Install the extensions. coldfront is preloaded by the image but must still be
-- created in your database (otherwise: schema "coldfront" does not exist).
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;

-- Cold-tier S3 credentials, set once per database. Stored in the
-- coldfront.storage_secret table (replicates across a Spock mesh,
-- excluded from pg_dump) and materialized as a DuckDB PERSISTENT
-- SECRET that loads at instance init.
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');

-- Create your partitioned table
CREATE TABLE events (
    id     bigint GENERATED ALWAYS AS IDENTITY,
    ts     timestamptz NOT NULL,
    status text,
    data   jsonb
) PARTITION BY RANGE (ts);

-- Create initial partitions (archiver will create future ones)
CREATE TABLE p_2026_04 PARTITION OF events
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
```

The archiver automatically creates:
- The `coldfront` schema and `archive_watermark` table
- Future partitions
- The unified view (replaces the source table name) and registers it with the coldfront hook (plus an INSTEAD OF INSERT trigger as a fallback for non-preloaded environments)

### Per-session setup

**None.** Set the cold-tier S3 credentials once per database:

```sql
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
```

This stores the secret in the `coldfront.storage_secret` table — an
extension-member table (so its data is excluded from `pg_dump` by
default) added to the Spock repset (so it replicates by value to every
mesh node) — and materializes a DuckDB PERSISTENT SECRET that DuckDB
loads at instance init. The Iceberg catalog `ice` is then attached
**lazily** by the coldfront C extension hook on the first query that
touches a tiered view (read or write), so both cold reads (`iceberg_scan`
through the unified view) and cold writes (`duckdb.raw_query` against
`ice.default.<table>`) Just Work on a fresh psql session. No
`ATTACH IF NOT EXISTS` needed in application code and no connect-time
setup. Works uniformly on PostgreSQL 16, 17, and 18.

For an **Azure ADLS Gen2** cold tier, set the credential with
`set_storage_secret_azure()` instead — it takes a CONFIG-provider connection
string. The storage-account access key rides inside `AccountKey=…`; the DuckDB
azure secret has no separate account-key parameter, so shared-key auth lives
entirely in the connection string:

```sql
SELECT coldfront.set_storage_secret_azure(
    'DefaultEndpointsProtocol=https;AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net');
```

It writes the same `coldfront.storage_secret` row (replicated, `pg_dump`-excluded)
and materializes a `TYPE azure` PERSISTENT SECRET. The Azure cold tier requires
the DuckDB 1.5.x build (see [INSTALL.md](INSTALL.md)) and is subject to the
soft-delete / change-feed restriction in [Caveats](#caveats).

One canonical user journey ([ci/journey.sh](ci/journey.sh)) runs identically in
every deployment cell; `ci/matrix.sh` drives the cells and `ci/topo/*.sh` brings
up each topology. All cells share the DuckDB 1.5.x app image
([docker/Dockerfile.duckdb15](docker/Dockerfile.duckdb15), built on the prebuilt
[base](docker/Dockerfile.duckdb15-base); `--build-arg PG_MAJOR=16|17|18`).

**Pre-commit gate** — `./run-ci-local.sh` runs `ci/matrix.sh --quick`: gofmt,
golangci-lint, unit tests, build, the pg_regress unit layer, and the full
journey on one representative cell (PG18 · vanilla · tiered · s3). Fast; runs on
every commit. GitHub Actions ([.github/workflows/ci.yml](.github/workflows/ci.yml))
runs the identical `ci/matrix.sh` harness — `--quick` on every push/PR, `--full`
nightly and on demand — so local and CI never diverge.

**Full matrix** — `ci/matrix.sh --full`, the beta gate: PG {16, 17, 18} ×
{vanilla, mesh (3-node Spock)} × {tiered, decoupled} × {primary, standby} ×
{s3, aws, azure, gcs}. The mesh cells add the cross-node stories — hot
visibility via Spock, cold visibility via the shared Lakekeeper catalog, the R-A
bakery serialising concurrent cold writers (same-node and cross-node) with no
409, and an N×(N-1) probe that the bakery's `coldfront.claims` table replicates
in every direction.

**Storage-backend gating** — the same policy applies locally and in GitHub CI:
the hermetic **SeaweedFS-as-S3** backend (`s3`) always runs — that is the
default coverage with no credentials. The real cloud stores run **only when
their credentials are present in the environment**, else they are reported
`PENDING` and never invoked (no real cloud calls without explicit creds):

| Backend | Store | Gating env vars |
|---|---|---|
| `s3`    | SeaweedFS (in-compose, hermetic) | — always runs |
| `aws`   | real AWS S3 (native vhost+HTTPS) | `COLDFRONT_AWS_ACCESS_KEY`, `_SECRET_KEY`, `_BUCKET`, `_REGION` |
| `azure` | real Azure ADLS Gen2             | `COLDFRONT_AZURE_ACCOUNT`, `_FILESYSTEM`, `_KEY`, `_CONNECTION_STRING` |
| `gcs`   | real GCS via S3-interop (HMAC)   | `COLDFRONT_GCS_ACCESS_KEY`, `_SECRET_KEY`, `_BUCKET` |

In GitHub Actions these come from repo secrets; an unset secret arrives empty, so
that backend stays `PENDING`. Fork PRs (no secret access) run SeaweedFS-only.

**Image build (base + app split)** — the DuckDB 1.5.x stack is split so builds are
fast and always test current source. The expensive, stable compiles (libcurl 8.11,
pg_duckdb 1.5.3, patched duckdb-iceberg) live in a prebuilt **base** image
([docker/Dockerfile.duckdb15-base](docker/Dockerfile.duckdb15-base)) published to
`ghcr.io/pgedge/coldfront-duckdb-base:pg{16,17,18}`; the **app** build
([docker/Dockerfile.duckdb15](docker/Dockerfile.duckdb15)) just `FROM`s it and
compiles the coldfront extension (seconds). The base is **PRIVATE/INTERNAL** (it
embeds the bakery patch — ColdFront IP), so building the app locally requires
`docker login ghcr.io` first. Rebuild the base via the
[base-image workflow](.github/workflows/base-image.yml) (`gh workflow run
base-image.yml`) when its inputs change.

## Security — non-superuser app roles

The setup snippets above run as a superuser for brevity, but ColdFront supports a
genuinely **least-privilege** model for enterprise use: application roles need
**no superuser and no server-file access**, yet read and write the cold tier
through the same transparent view. Onboarding is one call.

```sql
-- As an operator/superuser, once per application role:
SELECT coldfront.grant_app_access('alice');
-- 'alice' (a plain NOSUPERUSER role) can now SELECT/INSERT/UPDATE/DELETE through
-- every registered tiered/decoupled view — hot and cold — exactly as before.
```

`grant_app_access` grants only the minimum the cold path needs — membership in
`duckdb.postgres_role`, `USAGE` on the relevant schemas, `SELECT` on the registry,
DML on every registered view (plus the hot heap and its identity sequence behind a
tiered view, which pg_duckdb's scan touches as the invoker), and `EXECUTE` on the
runtime cold-path functions — all **derived from the registry**, never hardcoded.
It is idempotent (re-run after registering new tables) and is **not executable by
`PUBLIC`** (an app role can never self-grant). The app role is **not** granted
`pg_read_server_files` / `pg_write_server_files`, so it has no host-file access.

**How a non-superuser reaches Iceberg.** pg_duckdb force-disables DuckDB's
`LocalFileSystem` for non-superusers, which would block the side-loaded
iceberg/postgres DuckDB extensions from loading on `ATTACH`. ColdFront's attach
helpers `coldfront.ensure_attached()` / `ensure_pg_attached()` are therefore
`SECURITY DEFINER` (with a pinned `search_path`): the extension load + `ATTACH`
run elevated once per session, and because the DuckDB instance is per-backend the
attach persists, so every subsequent read (`iceberg_scan`) and write
(`_exec_iceberg_with_claim`) runs as the **app role** over S3/httpfs — no
`LocalFileSystem`, no elevation.

**Hardening.** Because the attach helpers run elevated, the deployment-config GUCs
they consume — `coldfront.warehouse`, `coldfront.lakekeeper_endpoint`,
`coldfront.local_pg_dsn` — are registered `PGC_SUSET` (superuser-set-only), so a
non-superuser cannot redirect the elevated `ATTACH` at an attacker endpoint;
`local_pg_dsn` is additionally `GUC_SUPERUSER_ONLY` (it may carry credentials).
Operators set these in `postgresql.conf` as before.

**Turnkey.** The image defaults `duckdb.postgres_role = coldfront_duckdb` and
creates that NOLOGIN role at init, so the non-superuser path works out of the box
— `grant_app_access` is the only step. Set `COLDFRONT_DUCKDB_ROLE=''` to keep
pg_duckdb's stock superuser-only behaviour. Superusers are unaffected either way.

**Spock mesh.** `CREATE ROLE` and `GRANT` both replicate via Spock DDL, so create
the role + run `grant_app_access` **once on any one node** — the role and every
grant propagate to the whole mesh. Don't repeat them per-node (a repeated
`CREATE ROLE` is a harmless local "already exists" error, just unnecessary). Mesh
cold *writes* route through the Ricart-Agrawala bakery, whose coordination
functions (`_claim_iceberg_lock` / `_release_iceberg_lock`) are `SECURITY DEFINER`
so a non-superuser drives the cross-node serialization (reading
`pg_stat_replication` liveness + dblinking the claim) with the right privilege —
verified **protocol-neutral** against the TLA+ model (`docs/formal/`). Least
privilege therefore holds for writes in a mesh too, not just single-node.

The whole boundary is asserted end-to-end by the journey's `story_app_privilege`
(non-superuser tiered read+write; in a mesh, cross-node read + a SECURITY
DEFINER-bakery cold write from a peer), by `ci/ops.sh` check 3 (the role cannot
redirect the endpoint, cannot self-grant, and an un-onboarded role is cleanly
denied), and at the catalog level by the `privilege_model` pg_regress test.

## Caveats

- **Azure ADLS Gen2 cold tier requires Blob soft-delete and change feed to be
  OFF.** Iceberg on Azure is accessed over the ADLS Gen2 (`abfss://` / `dfs`)
  endpoint, which **rejects storage accounts that have Blob soft-delete, container
  soft-delete, or change feed (blob events) enabled** — Lakekeeper warehouse
  creation fails with HTTP 409 *"This endpoint does not support BlobStorageEvents
  or SoftDelete."* Disable those features on the storage account before using it as
  a cold tier. (Plain blob access via `az://` is unaffected — it is specifically the
  ADLS Gen2 endpoint that Iceberg uses.)

## Project Structure

```
pgedge-coldfront/
├── cmd/archiver/
│   ├── main.go                 ← entry point (pure Go, pgx only)
│   └── main_test.go            ← retry, type mapping, interval tests
├── internal/
│   ├── config/                 ← YAML config loading + validation
│   ├── watermark/              ← archive_watermark table CRUD
│   ├── partition/              ← partition create/find/detach/drop
│   └── view/                   ← unified view + trigger generation
├── extension/coldfront/        ← PGXS C extension (hooks, bakery, registry)
├── ci/
│   ├── journey.sh              ← THE canonical user journey (the E2E spec)
│   ├── matrix.sh               ← drives PG×topology×mode×target cells (--quick / --full)
│   ├── probe-standby.sh        ← risk gate: iceberg_scan on a read-only hot standby
│   ├── lib.sh                  ← shared step/assert/psql helpers
│   ├── topo/                   ← vanilla.sh (1 node) · mesh.sh (3-node Spock)
│   └── runbooks/               ← failover-patroni.md (failover delegated to Patroni)
├── docker/
│   ├── Dockerfile.duckdb15      ← thin coldfront app layer (ARG PG_MAJOR=16|17|18)
│   ├── Dockerfile.duckdb15-base ← DuckDB 1.5.x base (pg_duckdb 1.5.3 + patched iceberg) — PRIVATE
│   ├── entrypoint.sh
│   └── seaweedfs-s3.json       ← SeaweedFS S3 auth config (example)
├── docker-compose.yml          ← END-USER single-node stack (ports published)
├── docker-compose.matrix.yml   ← CI only: single-node vanilla matrix
├── docker-compose.mesh.yml     ← CI only: 3-node Spock mesh
├── run-ci-local.sh             ← pre-commit gate (ci/matrix.sh --quick)
├── config.example.yaml
├── Makefile
├── USAGE.md                    ← user-level usage guide (both modes)
├── ARCHITECTURE.md             ← common architecture (shared mechanics)
├── ARCHITECTURE_TIERED.md      ← tiered (hot PG + cold Iceberg) mode
└── ARCHITECTURE_DECOUPLED.md   ← decoupled (iceberg-only) mode
```

## Dependencies

| Component | Version | Purpose |
|-----------|---------|---------|
| PostgreSQL | 16, 17, or 18 | Database with native partitioning (stock upstream; no fork) |
| pg_duckdb | 1.5.3 (PR #1025) | Iceberg reads + writes via DuckDB in-process |
| Lakekeeper | latest | Iceberg REST catalog (Rust binary) |
| S3-compatible store | any | AWS S3, SeaweedFS, MinIO, GCS, Azure Blob, etc. |
| Go | 1.24+ | Archiver binary (pure Go, no CGO) |
| pgx/v5 | 5.8.0 | PostgreSQL driver (only Go dependency) |

## License

PostgreSQL License. See [LICENSE](LICENSE).
