# Guided Walkthrough — Developer Reference

This directory contains an interactive walkthrough that deploys a single-node
ColdFront stack (PostgreSQL + DuckDB + Lakekeeper + SeaweedFS) and demonstrates
transparent Iceberg tiering, decoupled lake tables, and automated partition
management — all through standard SQL.

> The end-user walkthrough is at [docs/walkthrough.md](../../docs/walkthrough.md).
> This README covers how the walkthrough is structured and how to run it.

## How Users Reach the Walkthrough

The walkthrough is self-contained — it does not clone this repository or
depend on git. There are two primary entrypoints:

1. `curl ... | bash` — a one-liner that runs `install.sh` remotely. It
   downloads the walkthrough files and a tarball subset of the build sources,
   then launches the interactive guide. Requires Docker and curl.

2. GitHub Codespaces — opens a pre-configured environment with Docker-in-
   Docker and all tools pre-installed. The devcontainer runs setup during
   creation and launches the guide automatically.

If a user runs the `curl ... | bash` install inside Codespaces,
`install.sh` detects the `$CODESPACES` environment variable and exits as
a no-op — the devcontainer has already handled setup.

Both paths walk through the same three demos:

1. **Tiered storage** — relocate cold partitions to Iceberg/S3 while the
   table stays fully SQL-accessible and writeable
2. **Decoupled lake** — provision an Iceberg-native table fronted by a
   Postgres view (data in object storage from day one)
3. **Standalone partitioner** — automated range-partition maintenance
   with no cold tier or Iceberg involvement

## File Overview

```
examples/walkthrough/
├── install.sh              # Curl-pipe entry point (downloads files + sources)
├── guide.sh                # Interactive guide (three demos + menu)
├── setup.sh                # Prerequisites checker
├── runner.sh               # Terminal UX framework (sourced, not executed)
├── docker-compose.yml      # Full stack: db, archiver, Lakekeeper, SeaweedFS
├── Dockerfile.archiver     # Archiver + partitioner image (builds from source)
├── seaweedfs-s3.json       # SeaweedFS S3 gateway credentials
└── config/
    ├── archiver.yaml       # Archiver config (30-day tiering threshold)
    └── partitioner.yaml    # Partitioner config (DSN + connection settings)
```

### install.sh

Entry point for `curl ... | bash`. Downloads individual walkthrough files
from GitHub (no git clone) into a self-contained `coldfront-walkthrough/`
directory that mirrors the repo layout. Then fetches a tarball subset of
the repository (build sources only — `cmd/`, `internal/`, `extension/`,
`docker/`, `go.mod`, `go.sum`) so the Docker Compose build context is
complete without requiring a full clone.

After download it runs `guide.sh` via `exec`.

Environment variables:

- `WALKTHROUGH_DIR` — override the output directory name (default:
  `coldfront-walkthrough`)
- `WALKTHROUGH_BRANCH` — override the GitHub branch to download from
  (default: `main`)

In Codespaces (`$CODESPACES` is set), it prints guidance and exits 0.

### setup.sh

Validates that all required tools are present and the Docker environment
is ready. Does not install anything — it reports what is missing with
platform-aware install hints and exits non-zero if prerequisites are not
met.

### guide.sh

The interactive guide. Sources `runner.sh` for terminal UX, brings up
the Docker Compose stack, runs ColdFront setup SQL, then presents a
menu for the three demos.

Key behaviors:

- Polls for readiness (Postgres, Lakekeeper) rather than using fixed
  sleeps
- Retries warehouse creation until SeaweedFS is live
- `choose_volume` prompts for row count before the tiered demo
- `disk_preflight` estimates peak disk usage and warns if Docker's
  available space looks tight
- Idempotent teardown before each demo — safe to re-run at any point
- Non-interactive mode skips all prompts and runs a single demo,
  controlled by `WALKTHROUGH_NONINTERACTIVE` and `WALKTHROUGH_DEMO`

Environment variables:

- `COLDFRONT_PG_PORT` — Postgres port exposed on the host (default:
  `5432`)
- `WALKTHROUGH_NONINTERACTIVE` — set to `1` to skip all prompts and
  run one demo end-to-end (used by CI)
- `WALKTHROUGH_DEMO` — which demo to run in non-interactive mode:
  `tiered` (default), `decoupled`, or `partitioner`
- `WALKTHROUGH_ROWS` — row count for the tiered demo in non-interactive
  mode (default: `1000000`)

### runner.sh

Reusable terminal UX framework, sourced by `guide.sh`. Provides brand
colors (teal and orange from the pgEdge palette), `header`, `explain`,
`info`, `warn`, `error`, `show_cmd`, `prompt_run`, `prompt_continue`,
and `start_spinner`/`stop_spinner`.

This file is standalone and could be reused for other interactive guides.

### docker-compose.yml

Defines six services (five start by default; `archiver` is profile-gated):

- `db` — PostgreSQL with the `coldfront` extension, built from source
- `seaweedfs` — local S3-compatible object store (stands in for AWS S3,
  Azure Blob, or GCS)
- `lakekeeper-db` — Postgres instance backing the Lakekeeper catalog
- `lakekeeper-migrate` — one-shot migration job for Lakekeeper
- `lakekeeper` — Iceberg REST catalog
- `archiver` — the ColdFront archiver + partitioner binary (profile:
  `tools`, run on demand via `docker compose run`)

The `db` and `archiver` services build from source. The build context
is `../..` (the repo root, or `$WORK_DIR` after `install.sh` downloads
the tarball subset), so the Dockerfile can reach `docker/`,
`extension/`, `cmd/`, `internal/`, and `go.*`.

## Running the Walkthrough

### Interactive Guide (`curl ... | bash`)

The primary entrypoint. Downloads the walkthrough files and build
sources, then launches the guide.

```bash
curl -fsSL \
  https://raw.githubusercontent.com/pgEdge/coldfront/main/examples/walkthrough/install.sh \
  | bash
```

What happens:

1. `install.sh` downloads scripts and config into `coldfront-walkthrough/`
   (no git clone — individual file downloads from GitHub raw)
2. `install.sh` fetches a tarball subset from GitHub to provide the
   build sources the Docker images need (`cmd/`, `internal/`,
   `extension/`, `docker/`, `go.mod`, `go.sum`)
3. `guide.sh` calls `setup.sh`, then brings up the Docker Compose stack
   and walks through setup before presenting the demo menu

### GitHub Codespaces

Open a Codespace from the repository and select the walkthrough
devcontainer when prompted. The devcontainer handles prerequisites and
opens the guide automatically. Running `curl ... | bash` inside
Codespaces is a no-op — `install.sh` detects `$CODESPACES` and exits.

### From a cloned repo

The walkthrough works without the `install.sh` download path if you
already have the repository cloned:

```bash
# Run the interactive guide (calls setup.sh automatically)
bash examples/walkthrough/guide.sh

# Or run setup and guide separately
bash examples/walkthrough/setup.sh
bash examples/walkthrough/guide.sh
```

## Apple Silicon Note

The `db` service is pinned to `platform: linux/amd64` in
`docker-compose.yml` because the `coldfront-duckdb-base` image is built
for amd64. On Apple Silicon (M1/M2/M3) Docker Desktop runs this under
Rosetta 2 emulation — the walkthrough is fully functional, but image
pull and the initial build take longer than on a native amd64 host. If
you see a slow `docker build` on first run, this is expected.
