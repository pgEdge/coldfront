# Building ColdFront from Source

This guide builds ColdFront from source, either in Docker on top of the
published base image or on bare metal.

> **Most users should install from packages** - see
> [Installation](https://github.com/pgEdge/ColdFront/blob/main/README.md#installation)
> in the README. This document is the **build-from-source** workflow: build the
> patched DuckDB-1.5.x stack yourself, in Docker or bare-metal.

ColdFront runs on a **DuckDB 1.5.x** stack: PostgreSQL + pg_duckdb (DuckDB
1.5.4) and a **patched** duckdb-iceberg that includes ColdFront's four
patches - the bakery-aware commit-refresh patch (the no-409 guarantee for
concurrent cold-tier writers), two strict-reader interop patches (so
apache/iceberg-go, the cold-tier compactor, can read the manifests
duckdb-iceberg writes) and a port of an upstream fix that computes the time
partitions of a `timestamptz` column in UTC. No released pg_duckdb tag includes
DuckDB 1.5.x yet, so the stack is built from a pinned upstream PR plus
ColdFront's patches - all from sources you can fetch.

## What Gets Built

`docker/Dockerfile.duckdb15-base` is the recipe; it fetches the requirements,
applies ColdFront's patches, and compiles a set of components. The following
table shows each component and its source:

| Component | Source |
|---|---|
| libcurl 8.12.0 | The recipe builds libcurl from source from `curl.se`, because DuckDB 1.5.4 httpfs needs curl 7.77 or later at compile time and the pgEdge base ships 7.76.1. |
| pg_duckdb (DuckDB 1.5.4) | `github.com/duckdb/pg_duckdb`, PR #1025 |
| duckdb-iceberg | `github.com/duckdb/duckdb-iceberg`, `v1.5-variegata` @ `5edc45f0` |
| DuckDB 1.5.4 | `github.com/duckdb/duckdb`, tag `v1.5.4`, which replaces duckdb-iceberg's own DuckDB submodule |
| duckdb-avro, duckdb-azure, duckdb-postgres | `github.com/duckdb/duckdb-avro` @ `7f423d69`, `github.com/duckdb/duckdb-azure` @ `563589b2`, and `github.com/duckdb/duckdb-postgres` @ `6b2b12ca`, pinned in `docker/iceberg-azure-extension-config-v15.cmake` |
| vcpkg | `github.com/microsoft/vcpkg` |
| Base images | `ghcr.io/pgedge/pgedge-postgres:<pg>-spock5-minimal` and `quay.io/pypa/manylinux_2_28_<arch>` |

The base build runs as three Docker stages: the first builds libcurl and
pg_duckdb; the second clones duckdb-iceberg at the pinned ref, applies
ColdFront's four patches, and compiles the iceberg, avro, azure, and
postgres_scanner extensions under vcpkg; the third assembles the runtime. The
build `git apply --check`s each patch before applying it, so it fails loudly on
patch rot rather than silently shipping stock iceberg (which fails with HTTP
409 under concurrency and writes manifests strict Apache readers reject).

ColdFront applies four patches to duckdb-iceberg. The following table describes
what each one does:

| Patch | What it does |
|---|---|
| `iceberg-bakery-aware-commit-refresh-v15` | Refreshes the table head at the commit POST (and re-creates the table's storage secret in the commit context, needed under catalog credential vending) so concurrent cold writers never get a Lakekeeper 409 (the no-409 guarantee). It also lets writers queued behind the first commit into a never-written table proceed instead of failing as "already outdated". |
| `iceberg-manifest-list-format-version-v15` | Adds the spec-optional `format-version` key to the manifest-list metadata so strict Apache readers parse the entries as v2. |
| `iceberg-data-file-format-v15` | Upper-cases the data-file format in the manifest to match the spec enum strict readers check case-sensitively. |
| `iceberg-timestamptz-utc-transforms-v15` | Computes the year/month/day/hour partition of a `timestamptz` column on the UTC instant rather than in the session's time zone (a port of upstream duckdb-iceberg d3c3348271). |

The bakery patch is mandatory for the no-409 guarantee. The two interop patches
make the manifests duckdb-iceberg writes readable by strict Apache readers such
as apache/iceberg-go, the cold-tier compactor; they are inert to pg_duckdb's
own reads. The fourth is what makes a partitioned cold table correct when
written from a session whose time zone is not UTC. The canonical recipe - every
source pin and compile step - is
[`docker/Dockerfile.duckdb15-base`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base)
itself.

## Build the Image (Docker)

Build the stack in two stages, the prebuilt base and the thin app layer:

```bash
git clone <coldfront-repo> && cd coldfront

# 1. Build the base (fetches the deps above, applies our patches, compiles
#    pg_duckdb on DuckDB 1.5.4 + the patched duckdb-iceberg). ~30–60 min,
#    needs network + a few GB of disk/RAM. Repeat with =16 / =17 for those majors.
docker build -f docker/Dockerfile.duckdb15-base --build-arg PG_MAJOR=18 \
  -t ghcr.io/pgedge/coldfront-duckdb-base:pg18 .

# 2. Build the thin coldfront app layer + bring up the stack (seconds - it only
#    compiles the coldfront extension on top of the base).
docker compose up -d --build      # end-user single-node stack (ports published)
# (CI uses docker-compose.matrix.yml / docker-compose.mesh.yml - NOT for end-user setup)
```

The split keeps app builds fast and always testing current source: the
expensive, stable compiles (pg_duckdb on DuckDB 1.5.4 + the patched
duckdb-iceberg) live in the prebuilt **base**, published to
`ghcr.io/pgedge/coldfront-duckdb-base:pg{16,17,18}`; the **app** build
([`docker/Dockerfile.duckdb15`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15))
`FROM`s it and compiles the coldfront extension in seconds. If you build the
base yourself (step 1) the app layer `FROM`s your local image; otherwise it
`FROM`s the published `ghcr.io/pgedge/coldfront-duckdb-base:pg<major>`. Rebuild
the published base via the
[base-image workflow](https://github.com/pgEdge/ColdFront/blob/main/.github/workflows/base-image.yml)
(`gh workflow run base-image.yml --ref <branch> -f push=true`) when its inputs
change; without `push=true` the workflow builds but publishes nothing. CI
builds the app on the tag `ci/base-ref.sh <major>` prints, `pg<major>-r<hash>`,
where the hash covers the base Dockerfile and the files it copies in, and stops
before the app build if that tag is not published, naming the command that
publishes it. The floating `pg<major>` tag moves to the same image only when
the base-image workflow is dispatched from `main` with `push=true` and both
architectures.

Then follow [usage.md → One-Time Setup](usage.md#one-time-setup) (bootstrap
Lakekeeper → create a table → tier → verify).

> **pg_duckdb pin.** The base pins pg_duckdb to the merged PR #1025 commit
> `c04e6a2` (DuckDB 1.5.4 - its duckdb submodule is the v1.5.4 tag), a fixed
> commit for reproducible builds rather than a moving PR head.
>
> **Base foundation.** The base is
> `FROM ghcr.io/pgedge/pgedge-postgres:<pg>-spock5-minimal`; you need pull
> access to that image (or substitute an equivalent PostgreSQL base with the
> same layout).

## Verify the Build

A self-contained smoke test confirms the freshly built stack works end to end:
pg_duckdb, the patched duckdb-iceberg, Lakekeeper, and the object store. The
fastest path needs no cloud credentials; bring the stack up with the in-compose
SeaweedFS S3 emulator under the `local-store` profile:

```bash
docker compose --profile local-store up -d --build
```

Bootstrap Lakekeeper, create the `wh` warehouse against the SeaweedFS
credentials in
[`docker/seaweedfs-s3.json`](https://github.com/pgEdge/ColdFront/blob/main/docker/seaweedfs-s3.json),
and seed the `public` namespace:

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
  -H 'Content-Type: application/json' -d '{"namespace":["public"]}'
```

Create the extensions, set the cold-store secret, create a decoupled table,
insert a row, and read it back through Iceberg:

```bash
psql -h localhost -U coldfront -d coldfront <<'SQL'
CREATE EXTENSION IF NOT EXISTS pg_duckdb;
CREATE EXTENSION IF NOT EXISTS coldfront;
SELECT coldfront.set_storage_secret('admin', 'adminsecret', 'seaweedfs:8333');
SELECT coldfront.create_iceberg_table('public', 'events',
  '[{"name":"id","type":"bigint"},{"name":"ts","type":"timestamptz"},{"name":"note","type":"text"}]'::jsonb,
  '{month(ts)}');
INSERT INTO events VALUES (1, now(), 'hello');
SELECT count(*) FROM events;
SQL
```

A row count of 1 read back through Iceberg confirms the full path. For a real
cloud store, drop the `local-store` profile, point the warehouse at your own
bucket, and follow [usage.md → One-Time Setup](usage.md#one-time-setup) for the
full tier-and-verify journey.

## Build Prerequisites

The following table lists the prerequisites for each build path:

| For | You need |
|---|---|
| Docker build (above) | Docker, network access (GitHub, ghcr.io, quay.io, curl.se, and the distribution's RPM repositories), a few GB of disk and RAM, and 30-60 minutes for the base compile. |
| The archiver and partitioner (all paths) | Go 1.26.5+ (pinned in [go.mod](https://github.com/pgEdge/ColdFront/blob/main/go.mod)) and `make` (`make build` produces `./bin/archiver` and `./bin/partitioner`). |
| The compactor and the CI gate | golangci-lint for `make compactor`; `./run-ci-local.sh` also needs Docker and mkdocs with mkdocs-material. |
| Bare metal (below) | `pg_config`, PostgreSQL server dev headers, libpq client headers and library (libpq-dev / libpq-devel), `make`, and `gcc`. |

## Bare Metal (No Docker)

The coldfront extension is a standard PGXS C extension:

```bash
cd extension/coldfront
make && make install        # needs pg_config + PG server dev headers on PATH
```

You separately need pg_duckdb (DuckDB 1.5.4) and the **patched** iceberg DuckDB
extension installed in your PostgreSQL. Follow the compile steps in
[`docker/Dockerfile.duckdb15-base`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base),
and copy the built iceberg, avro, azure, and postgres_scanner extensions into
`$PGDATA/pg_duckdb/extensions/v1.5.4/linux_<arch>/`, as
[`docker/entrypoint.sh`](https://github.com/pgEdge/ColdFront/blob/main/docker/entrypoint.sh)
does. Then set the following in `postgresql.conf`:

```ini
shared_preload_libraries = 'pg_duckdb,coldfront'
# The locally built iceberg extension is unsigned.
duckdb.allow_unsigned_extensions = true
coldfront.warehouse           = '<warehouse-name>'
coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
coldfront.local_pg_dsn        = 'host=/var/run/postgresql dbname=<db> user=<role>'
# Optional, and only with the patched duckdb-iceberg: async cold-write ordering.
coldfront.iceberg_async_parquet = on
coldfront.iceberg_bakery_patch  = on
```

See [usage.md → Tuning Knobs](usage.md#tuning-knobs) for the remaining GUCs,
and the README for the optional non-superuser role that the image sets up.

## Testing & CI

One canonical user journey
([ci/journey.sh](https://github.com/pgEdge/ColdFront/blob/main/ci/journey.sh))
runs identically in every deployment cell; `ci/matrix.sh` drives the cells and
`ci/topo/*.sh` brings up each topology. All cells share the DuckDB 1.5.x app
image
([docker/Dockerfile.duckdb15](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15),
built on the prebuilt
[base](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base);
`--build-arg PG_MAJOR=16|17|18`).

### Pre-Commit Gate

`./run-ci-local.sh` runs `ci/matrix.sh --quick`: gofmt, go vet, golangci-lint,
unit tests, build, the compactor module gate (vet, lint, test, build),
`mkdocs build --strict`, the base recipe hash check, the pg_regress unit layer,
and the full journey on one representative cell (PG18 · vanilla · tiered · s3).
The gate is fast and runs on every commit. GitHub Actions
([.github/workflows/ci.yml](https://github.com/pgEdge/ColdFront/blob/main/.github/workflows/ci.yml))
runs the identical `ci/matrix.sh` harness: `--quick` on every pull request and
every push to `main`, and `--full` nightly and on demand. GitHub also runs a
gitleaks secret scan, a go-licenses check, and the path-filtered walkthrough
workflow, which the local gate does not.

### Full Matrix

`ci/matrix.sh --full` is the release gate, covering PG {16, 17, 18} × {vanilla,
mesh (3-node Spock)} × {tiered, decoupled} × {primary, standby} × {s3, aws,
azure, gcs, vended, azure-vended}, where the two vended backends run on vanilla
only. The ops-hardening and probe-snowflake cells run once, on PG18. The mesh
cells add the cross-node stories - hot visibility via Spock, cold visibility
via the shared Lakekeeper catalog, the R-A bakery serializing concurrent cold
writers (same-node and cross-node) with no 409, and an N×(N-1) probe that the
bakery's `coldfront.claims` table replicates in every direction.

### Storage-Backend Gating

The same policy applies locally and in GitHub CI: the hermetic
**SeaweedFS-as-S3** backend (`s3`) always runs - that is the default coverage
with no credentials. The real cloud stores run **only when their credentials
are present in the environment**, else they are reported `PENDING` and never
invoked (no real cloud calls without explicit creds). The following table shows
each backend, the variable whose presence turns it on, and the other variables
it then requires; a lane turned on without the rest fails instead of staying
`PENDING`:

| Backend | Store | Gate variable | Also required |
|---|---|---|---|
| `s3`    | SeaweedFS (in-compose, hermetic) | None; this backend always runs. | None |
| `vended` | SeaweedFS STS credential vending (hermetic, vanilla only) | None; this backend always runs. | None |
| `aws`   | Real AWS S3 (native virtual-hosted addressing over HTTPS) | `COLDFRONT_AWS_ACCESS_KEY` | `COLDFRONT_AWS_SECRET_KEY`, `_BUCKET`, `_REGION` |
| `azure` | Real Azure ADLS Gen2 | `COLDFRONT_AZURE_CONNECTION_STRING` | `COLDFRONT_AZURE_ACCOUNT`, `_FILESYSTEM`, `_KEY` |
| `azure-vended` | Real Azure ADLS Gen2 with SAS vending (vanilla only) | `COLDFRONT_AZURE_KEY` | `COLDFRONT_AZURE_ACCOUNT`, `_FILESYSTEM` |
| `gcs`   | Real GCS via S3 interoperability (HMAC) | `COLDFRONT_GCS_ACCESS_KEY` | `COLDFRONT_GCS_SECRET_KEY`, `_BUCKET` |

In GitHub Actions these come from repo secrets; an unset secret arrives empty,
so that backend stays `PENDING`. Fork PRs (no secret access) run
SeaweedFS-only.

## Next Steps

To go further with ColdFront, consult the following guides:

- The [Walkthrough](walkthrough.md) guide runs the demo stack hands-on.
- The [Using ColdFront](usage.md) guide covers the one-time setup and both
  modes.
- The [Object Store Setup](object_store.md) guide connects the cold tier to AWS
  S3.
