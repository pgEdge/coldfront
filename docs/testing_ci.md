# Testing and Continuous Integration

ColdFront's test harness runs one canonical user journey,
[`ci/journey.sh`](https://github.com/pgEdge/ColdFront/blob/main/ci/journey.sh),
in every deployment cell. The journey adapts to each cell: mesh cells run
additional cross-node stories, and cells that use vended credentials skip the
checks that read the object store directly, such as the object-store
assertions after a table is dropped. `ci/matrix.sh` drives the cells, and the
scripts in `ci/topo/` bring up each topology. Every cell uses the same DuckDB
1.5 app image,
[`docker/Dockerfile.duckdb15`](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15),
built on the prebuilt
[base image](https://github.com/pgEdge/ColdFront/blob/main/docker/Dockerfile.duckdb15-base)
with `--build-arg PG_MAJOR=16`, `17`, or `18`. To build ColdFront before you
test it, see [Installing ColdFront](installation.md).

## Pre-Commit Gate

Before you run the pre-commit gate, make sure that the host has the
following:

- Git and a clone of the ColdFront repository; run the gate from the top
  directory of the clone.
- Go 1.26.10 or later, golangci-lint v2.12.2 (the version CI installs; the
  repository's `.golangci.yml` uses the v2 format), and `make`, for the Go
  checks, the unit tests, and the build. `make test` runs the tests with the
  race detector, which needs cgo, so on Linux the host also needs a C compiler
  such as `gcc`.
- mkdocs with mkdocs-material, for the documentation build.
- Docker with the Docker Compose plugin, for the shellcheck, hadolint, and
  actionlint checks, which run in containers, and for the stack that the
  pg_regress tests and the journey use.
- `curl`, which the journey and topology scripts use to call Lakekeeper.

The topology scripts and the journey reach PostgreSQL, Lakekeeper, and
SeaweedFS from the host at each container's IP address, so the host must be
able to route traffic to Docker container IP addresses. Docker Engine on Linux
does this; Docker Desktop on macOS and Windows does not, so run the gate on a
Linux host or in a Linux virtual machine that runs Docker Engine.

The CI scripts refer to containers by names such as `coldfront-db-1`, so the
Compose project must be named `coldfront` whatever the clone directory is
called. Set the project name in the shell before you run the gate:

```bash
export COMPOSE_PROJECT_NAME=coldfront
```

!!! warning

    The gate runs `docker compose down -v` in the `coldfront` Compose project
    before it starts each cell's stack and again when the cell ends, which
    removes that project's containers and volumes. That includes a stack that
    you started from the same clone by following
    [Installing ColdFront](installation.md), and any data in it, which is lost
    as soon as the first cell starts. Back up that data first, or run the gate
    on a separate Docker host.

Run the gate with `./run-ci-local.sh`, which runs `ci/matrix.sh --quick`. The
gate is fast enough to run on every commit and performs the following checks:

- The Go checks: gofmt, go vet, golangci-lint, the unit tests, and the build.
- The shell, Dockerfile, and workflow linters: shellcheck, hadolint, and
  actionlint.
- The compactor module checks: vet, lint, test, and build.
- The documentation build, `mkdocs build --strict`.
- The base recipe hash check.
- The pg_regress unit tests.
- The full user journey on one representative cell: PostgreSQL 18, vanilla,
  tiered mode, and the `s3` backend.

GitHub Actions
([.github/workflows/ci.yml](https://github.com/pgEdge/ColdFront/blob/main/.github/workflows/ci.yml))
runs the same `ci/matrix.sh` harness: `--quick` on every pull request and every
push to `main`, and `--full` nightly and on demand. GitHub also runs a gitleaks
secret scan, a go-licenses check, and the path-filtered walkthrough workflow,
which the local gate does not run.

On the `main` branch only, GitHub also runs two sets of PostgreSQL 18 cells
against real cloud storage: the `aws-vended` cells against an AWS S3 bucket,
and the `azure-vended` cells against an Azure Data Lake Storage (ADLS) Gen2
account.
These jobs run `ci/matrix.sh --backend <backend>` inside `ci/cloud.sh <cloud>`.

The jobs store no cloud credentials. Instead, each job requests a GitHub OIDC
token, and Lakekeeper uses that token to obtain short-lived access:

- On AWS, Lakekeeper assumes an IAM role.
- On Azure, Lakekeeper signs user-delegation SAS tokens as a managed identity;
  the storage account has shared key access turned off.

Lakekeeper then vends per-table credentials to DuckDB. The account identifiers
are stored as variables in the `cloud-aws` and `cloud-azure` GitHub
environments, whose branch rules allow only `main` to use them.

The vended cloud cells, `aws-vended` and token-based `azure-vended`, clean up
their test data in three ways:

- Each cell writes under its own prefix and deletes that prefix at teardown.
- In GitHub Actions, each cloud job deletes every prefix again when it ends.
- An hourly workflow
  ([.github/workflows/sweep.yml](https://github.com/pgEdge/ColdFront/blob/main/.github/workflows/sweep.yml))
  removes `coldfront-ci/` prefixes older than six hours from the CI bucket,
  `COLDFRONT_AWS_BUCKET`, and the CI filesystem, `COLDFRONT_AZURE_FILESYSTEM`
  in `COLDFRONT_AZURE_ACCOUNT`, as the `cloud-aws` and `cloud-azure`
  environments set them, and fails if it finds anything to remove.

When you run a vended cell locally, the job-end purge does not apply. The
sweep cleans the CI bucket and the CI filesystem whatever started the run, so
it also covers a local run that uses them. It does not cover any other bucket,
or any other filesystem in the same storage account. If a local run against
other cloud resources does not finish its teardown, delete the cell's prefix
under `coldfront-ci/` in the bucket or filesystem that the run used.

The `aws`, `azure`, and `gcs` cells and key-based `azure-vended` runs do not
use these mechanisms, so remove the data that those cells write to your bucket
or container yourself.

## Full Matrix

Beyond the pre-commit gate, `ci/matrix.sh --full` is the release gate. It runs
the user journey in every combination of the following dimensions:

| Dimension | Values |
|---|---|
| PostgreSQL version | 16, 17, and 18 |
| Topology | vanilla (a single node) and mesh (three Spock nodes) |
| Operating mode | tiered and decoupled |
| Role | primary and standby |
| Storage backend | `s3`, `aws`, `azure`, `gcs`, `vended`, `azure-vended`, and `aws-vended` |

The three vended backends run on the vanilla topology only. The ops-hardening
and probe-snowflake cells run once, on PostgreSQL 18.

A full run skips a cloud backend whose gate variables are incomplete and still
exits successfully. The run prints a coverage table that lists every cell of
the grid as `RUN`, `PENDING` with the reason, or `DEFERRED` for the vended mesh
cells. `RUN` means only that the backend's gate variables are set, not that the
cell ran: the table lists every PostgreSQL version even when `PG_ONLY` limits
the run to some of them. Check the table for `PENDING` cells, and check the
results of the cell steps or jobs to confirm which cells ran, before you rely
on the run for cloud coverage.

The mesh cells also test behaviour across nodes:

- Hot data written on one node is visible on the others through Spock
  replication.
- Cold data is visible on every node through the shared Lakekeeper catalog.
- The bakery serializes concurrent cold writers, on the same node and across
  nodes, without any HTTP 409 conflicts.
- A probe confirms that the bakery's `coldfront.claims` table replicates in
  both directions between every pair of nodes.

## Storage-Backend Gating

The matrix decides which storage backends to test in the same way locally and
in GitHub CI:

- The SeaweedFS backends, `s3` and `vended`, need no credentials, because
  SeaweedFS runs inside the Compose stack. The full matrix runs both; the
  pre-commit gate and the `--quick` pull request job run only `s3`.
- A real cloud backend runs only when its credentials are set in the
  environment. Without them, the matrix reports the backend as `PENDING` and
  makes no calls to that cloud.

Each cloud backend has gate variables that turn it on, and other variables
that it then requires. In a full matrix run, a backend whose gate variables
are not all set stays `PENDING`, while a backend whose gate variables are set
but whose other required variables are missing runs, and its cells fail. When
you select one backend with `ci/matrix.sh --backend`, a backend whose gate
variables are not all set makes the script exit with an error instead. The
following table shows each backend, its gate variables, and the other
variables it requires:

| Backend | Store | Gate variables | Also required |
|---|---|---|---|
| `s3`    | SeaweedFS (in the Compose stack) | None; needs no credentials, and runs in every scope. | None |
| `vended` | SeaweedFS STS credential vending (in the Compose stack, vanilla only) | None; needs no credentials, and runs in the full matrix only. | None |
| `aws`   | Real AWS S3 (native virtual-hosted addressing over HTTPS) | `COLDFRONT_AWS_ACCESS_KEY` | `COLDFRONT_AWS_SECRET_KEY`, `_BUCKET`, `_REGION` |
| `azure` | Real Azure ADLS Gen2 | `COLDFRONT_AZURE_CONNECTION_STRING` | `COLDFRONT_AZURE_ACCOUNT`, `_FILESYSTEM`, `_KEY` |
| `azure-vended` | Real Azure ADLS Gen2 with SAS vending (vanilla only) | `COLDFRONT_AZURE_ACCOUNT`, and either `COLDFRONT_AZURE_KEY` (the account's key as the warehouse credential) or `COLDFRONT_AZURE_TOKEN_FILE` (the job's OIDC token, which `ci/cloud.sh azure` writes and sets) | `COLDFRONT_AZURE_FILESYSTEM`; with the token file, also `COLDFRONT_AZURE_CLIENT_ID` and `_TENANT_ID` (the managed identity, on an account with key access off), and the cells must run under `ci/cloud.sh azure run` |
| `aws-vended` | Real AWS S3 with STS vending and no stored key (vanilla only) | `COLDFRONT_AWS_DATA_ROLE_ARN`, `COLDFRONT_AWS_EXTERNAL_ID`, and `COLDFRONT_AWS_BUCKET` (with versioning never enabled, since the purge deletes without version ids) | `COLDFRONT_AWS_REGION`. In CI, the cells run under `ci/cloud.sh aws run`, which also requires `_CI_ROLE_ARN` and supplies the job's OIDC token. Locally, the AWS CLI on the host, which exports the caller's own AWS session with `aws configure export-credentials`; the session must be allowed to assume the data role and, since the cell purges its prefix as the caller, needs `s3:ListBucket` and `s3:ListBucketMultipartUploads` on the bucket and `s3:DeleteObject` and `s3:AbortMultipartUpload` on the objects under `coldfront-ci/` |
| `gcs`   | Real GCS via S3 interoperability (HMAC) | `COLDFRONT_GCS_ACCESS_KEY` | `COLDFRONT_GCS_SECRET_KEY`, `_BUCKET` |

In GitHub Actions, the full matrix job reads the `aws`, `azure`, `gcs`, and
key-based `azure-vended` variables from repository secrets. An unset secret
arrives empty, so a backend whose gate variable is unset stays `PENDING`; a
backend whose gate variable is set but whose other variables are not still
runs and fails, for example the `aws` cells when `COLDFRONT_AWS_ACCESS_KEY` is
set and `COLDFRONT_AWS_SECRET_KEY` is not. The full matrix job does not
pass `COLDFRONT_AWS_DATA_ROLE_ARN` or `COLDFRONT_AWS_EXTERNAL_ID`, so
`aws-vended` always stays `PENDING` there. The separate `cloud-aws` and
`cloud-azure` jobs test `aws-vended` and token-based `azure-vended` on
PostgreSQL 18 only. Fork PRs (no secret access) run SeaweedFS-only.

## Publishing the Base Image

The app image that every cell uses starts from the published DuckDB base image.
Maintainers rebuild and publish the base image with the following process:

- When the base image's inputs change, run the
  [base-image workflow](https://github.com/pgEdge/ColdFront/blob/main/.github/workflows/base-image.yml)
  with `gh workflow run base-image.yml --ref <branch> -f push=true`. Without
  `push=true`, the workflow builds the image but does not publish it.
- CI builds the app image on the base tag that `ci/base-ref.sh <major>`
  prints, in the form `pg<major>-r<hash>`; the hash covers the base Dockerfile
  and the files it copies in. When that tag is not published, CI stops before
  the app build and names the command that publishes the tag.
- The floating `pg<major>` tag moves to the new image only when the workflow
  runs from `main` with `push=true` for both architectures.
