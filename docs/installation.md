# Building ColdFront from source

> **Most users should install from packages** - see
> [Installation](https://github.com/pgEdge/ColdFront/blob/main/README.md#installation) in the README. This document is the
> **build-from-source** workflow: build the patched DuckDB-1.5.x stack
> yourself, in Docker or bare-metal.

ColdFront runs on a **DuckDB 1.5.x** stack: PostgreSQL + pg_duckdb
(DuckDB 1.5.3) and a **patched** duckdb-iceberg that carries ColdFront's
four patches - the bakery-aware commit-refresh patch (the no-409
guarantee for concurrent cold-tier writers) and three strict-reader
interop patches (so apache/iceberg-go, the cold-tier compactor, can read
the manifests duckdb-iceberg writes). The patch internals are in
[DUCKDB_1.5_PATCHED.md](https://github.com/pgEdge/ColdFront/blob/main/DUCKDB_1.5_PATCHED.md).
No released pg_duckdb tag carries DuckDB 1.5.x yet, so the stack is built
from a pinned upstream PR plus our patches - all from sources you can
fetch.

## What gets built

`docker/Dockerfile.duckdb15-base` is the recipe; it fetches the
requirements, applies our patches, and compiles the following
components:

| Component | Source |
|---|---|
| libcurl 8.12.0 | `curl.se`, built from source (compile-time dep of DuckDB 1.5.3 httpfs; needs curl >= 7.77, the pgEdge base ships 7.76.1) |
| pg_duckdb (DuckDB 1.5.3) | `github.com/duckdb/pg_duckdb`, PR #1025 |
| duckdb-iceberg | `github.com/duckdb/duckdb-iceberg`, `v1.5-variegata` @ `0fad545a` |
| vcpkg | `github.com/microsoft/vcpkg` |

The base build runs as three Docker stages: the first builds libcurl and
pg_duckdb; the second clones duckdb-iceberg at the pinned ref, applies
ColdFront's four patches, and compiles the iceberg, avro, azure, and
postgres_scanner extensions under vcpkg; the third assembles the runtime.
The build `git apply --check`s each patch before applying it, so it fails
loudly on patch rot rather than silently shipping stock iceberg (which
409s under concurrency and writes manifests strict Apache readers reject).

ColdFront applies the following four patches to duckdb-iceberg; the full
rationale is in
[DUCKDB_1.5_PATCHED.md](https://github.com/pgEdge/ColdFront/blob/main/DUCKDB_1.5_PATCHED.md):

| Patch | What it does |
|---|---|
| `iceberg-bakery-aware-commit-refresh-v15` | Re-stamps the parent snapshot at the commit POST so concurrent cold writers never get a Lakekeeper 409 (the no-409 guarantee). |
| `iceberg-manifest-list-format-version-v15` | Adds the spec-optional `format-version` key to the manifest-list metadata so strict Apache readers parse the entries as v2. |
| `iceberg-manifest-content-v15` | Writes the manifest's real content type instead of a hardcoded value, so strict readers accept delete manifests. |
| `iceberg-data-file-format-v15` | Upper-cases the data-file format in the manifest to match the spec enum strict readers check case-sensitively. |

The bakery patch is mandatory for the no-409 guarantee. The other three
are interop patches so the manifests duckdb-iceberg writes are readable
by strict Apache readers such as apache/iceberg-go, the cold-tier
compactor; they are inert to pg_duckdb's own reads. The canonical recipe
- every source pin and compile step - is
[`docker/Dockerfile.duckdb15-base`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base) itself.

## Build the image (Docker)

Build the stack in two stages, the prebuilt base and the thin app layer:

```bash
git clone <coldfront-repo> && cd coldfront

# 1. Build the base (fetches the deps above, applies our patches, compiles
#    pg_duckdb 1.5.3 + the patched duckdb-iceberg). ~30–60 min,
#    needs network + a few GB of disk/RAM. Repeat with =16 / =17 for those majors.
docker build -f docker/Dockerfile.duckdb15-base --build-arg PG_MAJOR=18 \
  -t ghcr.io/pgedge/coldfront-duckdb-base:pg18 .

# 2. Build the thin coldfront app layer + bring up the stack (seconds — it only
#    compiles the coldfront extension on top of the base).
docker compose up -d --build      # end-user single-node stack (ports published)
# (CI uses docker-compose.matrix.yml / docker-compose.mesh.yml — NOT for end-user setup)
```

The split keeps app builds fast and always testing current source: the
expensive, stable compiles (pg_duckdb 1.5.3 + the patched duckdb-iceberg)
live in the prebuilt **base**, published to
`ghcr.io/pgedge/coldfront-duckdb-base:pg{16,17,18}`; the **app** build
([`docker/Dockerfile.duckdb15`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15)) just `FROM`s it and
compiles the coldfront extension in seconds. If you build the base
yourself (step 1) the app layer `FROM`s your local image; otherwise it
`FROM`s the published `ghcr.io/pgedge/coldfront-duckdb-base:pg<major>`.
Rebuild the published base via the
[base-image workflow](https://github.com/pgEdge/ColdFront/blob/main/.github/workflows/base-image.yml) (`gh workflow run
base-image.yml`) when its inputs change.

Then follow [usage.md → One-time setup](usage.md#one-time-setup)
(bootstrap Lakekeeper → create a table → tier → verify).

> **Pin pg_duckdb for reproducible builds.** The base pins pg_duckdb to
> `pull/1025/head` (a moving, unreleased PR ref). For reproducible
> builds, pin it to a specific commit SHA (or the eventual DuckDB-1.5.x
> release) instead of the live PR head.
>
> **Base foundation.** The base is
> `FROM ghcr.io/pgedge/pgedge-postgres:<pg>-spock5-minimal`; you need pull
> access to that image (or substitute an equivalent PostgreSQL base with
> the same layout).

## Verify the build

A self-contained smoke test confirms the freshly built stack works end
to end: pg_duckdb, the patched duckdb-iceberg, Lakekeeper, and the object
store. The fastest path needs no cloud credentials; bring the stack up
with the in-compose SeaweedFS S3 emulator under the `local-store`
profile:

```bash
docker compose --profile local-store up -d --build
```

Bootstrap Lakekeeper, create the `wh` warehouse against the SeaweedFS
credentials in
[`docker/seaweedfs-s3.json`](https://github.com/pgEdge/ColdFront/blob/main/docker/seaweedfs-s3.json),
and seed the `default` namespace:

```bash
curl -sf -X POST http://localhost:8181/management/v1/bootstrap \
  -H 'Content-Type: application/json' -d '{"accept-terms-of-use":true}'

curl -s -X POST http://localhost:8181/management/v1/warehouse \
  -H 'Content-Type: application/json' -d '{
    "warehouse-name":"wh",
    "storage-profile":{"type":"s3","bucket":"iceberg","region":"us-east-1",
      "endpoint":"http://seaweedfs:8333","path-style-access":true,
      "flavor":"s3-compat","sts-enabled":false,"remote-signing-enabled":false},
    "storage-credential":{"type":"s3","credential-type":"access-key",
      "aws-access-key-id":"admin","aws-secret-access-key":"adminsecret"}
  }'

WID=$(curl -s http://localhost:8181/management/v1/warehouse \
  | grep -oE '"warehouse-id":"[^"]+"' | head -1 | cut -d'"' -f4)
curl -s -X POST "http://localhost:8181/catalog/v1/$WID/namespaces" \
  -H 'Content-Type: application/json' -d '{"namespace":["default"]}'
```

Create the extensions, set the cold-store secret, create a decoupled
table, insert a row, and read it back through Iceberg:

```bash
psql -h localhost -U coldfront -d coldfront <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
SELECT coldfront.create_iceberg_table('public', 'events',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},{"name":"note","type":"text"}]'::jsonb);
INSERT INTO events VALUES (1, now(), 'hello');
SELECT count(*) FROM events;
SQL
```

A row count of 1 read back through Iceberg confirms the full path. For a
real cloud store, drop the `local-store` profile, point the warehouse at
your own bucket, and follow
[usage.md → One-time setup](usage.md#one-time-setup) for the full
tier-and-verify journey.

## Build prerequisites

The following table lists the prerequisites for each build path:

| For | You need |
|---|---|
| Docker build (above) | Docker; network access (GitHub / quay.io); ~a few GB disk + RAM and 30-60 min for the base compile |
| The archiver (all paths) | Go 1.26.4+ (pinned in [go.mod](https://github.com/pgEdge/ColdFront/blob/main/go.mod)), `make` (`make build` → `./bin/archiver`) |
| Bare metal (below) | `pg_config`, PostgreSQL server dev headers, `make`, `gcc` |

## Bare metal (no Docker)

The coldfront extension is a standard PGXS C extension:

```bash
cd extension/coldfront
make && make install        # needs pg_config + PG server dev headers on PATH
```

You separately need pg_duckdb (DuckDB 1.5.3) and the **patched** iceberg
DuckDB extension installed in your PostgreSQL - follow the compile steps
in
[`docker/Dockerfile.duckdb15-base`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base) - plus, in
`postgresql.conf`:

```ini
shared_preload_libraries = 'pg_duckdb,coldfront'
coldfront.warehouse           = '<warehouse-name>'
coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
coldfront.local_pg_dsn        = 'host=/var/run/postgresql dbname=<db> user=<role>'
```

(See the README for the full GUC set and the optional turnkey
non-superuser role.)

## Testing & CI

One canonical user journey ([ci/journey.sh](https://github.com/pgEdge/ColdFront/blob/main/ci/journey.sh)) runs identically in
every deployment cell; `ci/matrix.sh` drives the cells and
`ci/topo/*.sh` brings up each topology. All cells share the DuckDB 1.5.x
app image
([docker/Dockerfile.duckdb15](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15), built on the prebuilt
[base](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base); `--build-arg PG_MAJOR=16|17|18`).

### Pre-commit gate

`./run-ci-local.sh` runs `ci/matrix.sh --quick`: gofmt, golangci-lint,
unit tests, build, the pg_regress unit layer, and the full journey on
one representative cell (PG18 · vanilla · tiered · s3). Fast; runs on
every commit. GitHub Actions ([.github/workflows/ci.yml](https://github.com/pgEdge/ColdFront/blob/main/.github/workflows/ci.yml))
runs the identical `ci/matrix.sh` harness - `--quick` on every push/PR,
`--full` nightly and on demand - so local and CI never diverge.

### Full matrix

`ci/matrix.sh --full`, the beta gate: PG {16, 17, 18} ×
{vanilla, mesh (3-node Spock)} × {tiered, decoupled} × {primary, standby}
× {s3, aws, azure, gcs}. The mesh cells add the cross-node stories - hot
visibility via Spock, cold visibility via the shared Lakekeeper catalog,
the R-A bakery serialising concurrent cold writers (same-node and
cross-node) with no 409, and an N×(N-1) probe that the bakery's
`coldfront.claims` table replicates in every direction.

### Storage-backend gating

The same policy applies locally and in GitHub CI: the hermetic
**SeaweedFS-as-S3** backend (`s3`) always runs - that is the default
coverage with no credentials. The real cloud stores run **only when
their credentials are present in the environment**, else they are
reported `PENDING` and never invoked (no real cloud calls without
explicit creds). The following table shows each backend and its gating
environment variables:

| Backend | Store | Gating env vars |
|---|---|---|
| `s3`    | SeaweedFS (in-compose, hermetic) | - always runs |
| `aws`   | real AWS S3 (native vhost+HTTPS) | `COLDFRONT_AWS_ACCESS_KEY`, `_SECRET_KEY`, `_BUCKET`, `_REGION` |
| `azure` | real Azure ADLS Gen2             | `COLDFRONT_AZURE_ACCOUNT`, `_FILESYSTEM`, `_KEY`, `_CONNECTION_STRING` |
| `gcs`   | real GCS via S3-interop (HMAC)   | `COLDFRONT_GCS_ACCESS_KEY`, `_SECRET_KEY`, `_BUCKET` |

In GitHub Actions these come from repo secrets; an unset secret arrives
empty, so that backend stays `PENDING`. Fork PRs (no secret access) run
SeaweedFS-only.
