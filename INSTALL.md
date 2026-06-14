# Building ColdFront from source

> **Most users should install from packages** — see
> [Installation](README.md#installation) in the README. This document is the
> **build-from-source** workflow: build the patched DuckDB-1.5.x stack yourself,
> in Docker or bare-metal.

ColdFront runs on a **DuckDB 1.5.x** stack: PostgreSQL + pg_duckdb (DuckDB 1.5.3)
and a **patched** duckdb-iceberg that carries ColdFront's bakery-aware
commit-refresh patch (the no-409 guarantee for concurrent cold-tier writers). No
released pg_duckdb tag carries DuckDB 1.5.x yet, so the stack is built from a
pinned upstream PR plus our patch — all from sources you can fetch.

## What gets built

`docker/Dockerfile.duckdb15-base` is the recipe; it fetches the requirements,
applies our patch, and compiles:

| Component | Source | Public? |
|---|---|---|
| pg_duckdb (DuckDB 1.5.3) | `github.com/duckdb/pg_duckdb`, **PR #1025** | yes |
| duckdb-iceberg | `github.com/duckdb/duckdb-iceberg`, `v1.5-variegata` | yes |
| vcpkg | `github.com/microsoft/vcpkg` | yes |
| **bakery-aware commit-refresh patch** | `docker/iceberg-bakery-aware-commit-refresh-v15.patch` **(in this repo)** | ships in-repo |

The build `git apply --check`s the patch first, so it fails loudly on patch rot
rather than silently shipping stock iceberg (which 409s under concurrency). The
canonical recipe — every source pin and compile step — is
[`docker/Dockerfile.duckdb15-base`](docker/Dockerfile.duckdb15-base) itself.

## Build the image (Docker)

```bash
git clone <coldfront-repo> && cd coldfront

# 1. Build the base (fetches the deps above, applies our patch, compiles
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
expensive, stable compiles (pg_duckdb 1.5.3 + the patched duckdb-iceberg) live
in the prebuilt **base**, published to
`ghcr.io/pgedge/coldfront-duckdb-base:pg{16,17,18}`; the **app** build
([`docker/Dockerfile.duckdb15`](docker/Dockerfile.duckdb15)) just `FROM`s it and
compiles the coldfront extension in seconds. If you build the base yourself
(step 1) the app layer `FROM`s your local image. To `FROM` the published base
instead of recompiling, note it is **PRIVATE/INTERNAL** — it embeds the bakery
patch (ColdFront IP) — so building the app layer against it requires
`docker login ghcr.io` first. Rebuild the published base via the
[base-image workflow](.github/workflows/base-image.yml) (`gh workflow run
base-image.yml`) when its inputs change.

Then follow [USAGE.md → One-time setup](USAGE.md#one-time-setup)
(bootstrap Lakekeeper → create a table → tier → verify).

> **Pin pg_duckdb for reproducible builds.** The base pins pg_duckdb to
> `pull/1025/head` (a moving, unreleased PR ref). For reproducible builds, pin it
> to a specific commit SHA (or the eventual DuckDB-1.5.x release) instead of the
> live PR head.
>
> **Base foundation.** The base is `FROM ghcr.io/pgedge/pgedge-postgres:<pg>-spock5-minimal`;
> you need pull access to that image (or substitute an equivalent PostgreSQL base
> with the same layout).

## Build prerequisites

| For | You need |
|---|---|
| Docker build (above) | Docker; network access (GitHub / quay.io); ~a few GB disk + RAM and 30–60 min for the base compile |
| The archiver (all paths) | Go 1.24+, `make` (`make build` → `./bin/archiver`) |
| Bare metal (below) | `pg_config`, PostgreSQL server dev headers, `make`, `gcc` |

## Bare metal (no Docker)

The coldfront extension is a standard PGXS C extension:

```bash
cd extension/coldfront
make && make install        # needs pg_config + PG server dev headers on PATH
```

You separately need pg_duckdb (DuckDB 1.5.3) and the **patched** iceberg DuckDB
extension installed in your PostgreSQL — follow the compile steps in
[`docker/Dockerfile.duckdb15-base`](docker/Dockerfile.duckdb15-base) — plus, in
`postgresql.conf`:

```
shared_preload_libraries = 'pg_duckdb,coldfront'
coldfront.warehouse           = '<warehouse-name>'
coldfront.lakekeeper_endpoint = 'http://<lakekeeper-host>:8181/catalog'
coldfront.local_pg_dsn        = 'host=/var/run/postgresql dbname=<db> user=<role>'
```

(See the README for the full GUC set and the optional turnkey non-superuser role.)

## Testing & CI

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
