# Reviewing Changes to ColdFront

This file describes what a defect looks like in ColdFront, which paths the
automated review tools skip, and what a reviewer checks in every pull request.
The author's AI review, CodeRabbit, and the approving reviewer all work from
this file.

## Recognizing a Failure

ColdFront runs inside the PostgreSQL server process and moves data between
PostgreSQL and Apache Iceberg, so a defect can lose data or crash the server.
A change fails review when the change can cause any of the following:

- a row that the archiver, a tiered `INSERT`, or the partitioner loses,
  duplicates, or alters as the row moves between partitions or between the hot
  and cold tiers.
- a cold read that returns rows or values that differ from what PostgreSQL
  returns for the same data.
- two cold writes that commit to one Iceberg table out of turn, or two nodes
  that register the same Iceberg table.
- a crash or memory error in `extension/coldfront/src/coldfront.c`, which
  terminates the backend and makes PostgreSQL end every other session while
  the server recovers from the crash.
- a storage credential or catalog token that appears in a log, an error
  message, a query text, or a committed file.
- a compaction or a cold `DROP` that deletes a data file that a live snapshot
  or an open transaction still reads.

## Skipping Paths in Automated Review

CodeRabbit reviews every tracked file. Codacy skips files that do not ship or
that another check covers, as the `.codacy.yaml` file lists, and a change to
that file updates this section to match.

The following table describes the paths that Codacy skips:

| Path | Reason |
|---|---|
| `.claude/**` and `CLAUDE.md` | These files instruct coding agents and do not ship. |
| `config.example.yaml` | This file is an example configuration. |
| `THIRD_PARTY_NOTICES.md` | This file is generated license text. |
| `docker/*.patch` | These patches change duckdb-iceberg, and CodeRabbit and the approving reviewer read them. |
| `docs/formal/**` | The TLC model checker checks the TLA+ model in this directory. |
| `extension/coldfront/test/**` | These files are pg_regress tests and their expected output. |
| `**/*_test.go` | These files are Go tests, which do not ship. |

## Checking a Change

A reviewer checks the following points in addition to the checklist in the
pull request template. The linters cover formatting, so the review omits
findings about formatting alone.

### Checking Cold Writes and the Bakery

The bakery protocol serializes every cold write through the
`coldfront.claims` table. A change to cold writes follows these rules:

- A change to the bakery functions in the extension SQL, the commit callback
  in `coldfront.c`, the `coldfront.iceberg_async_parquet` ordering, or the
  Spock settings that replicate claims updates `docs/formal/Bakery.tla` and
  re-runs every TLC configuration. A pure refactor instead explains in the
  pull request why the claim, commit, and release sequence is unchanged.
  [docs/formal/README.md](docs/formal/README.md) describes the model and every
  configuration.
- A cold write runs outside any subtransaction, such as a `SAVEPOINT` or a
  PL/pgSQL `EXCEPTION` block, because pg_duckdb refuses every cold write inside
  one.
- A cold write commits to the catalog without a retry, because the bakery
  prevents commit conflicts.

### Checking Generated SQL

The query rewrite emits SQL that DuckDB or a second session runs, and that SQL
must read the same in every session. Generated SQL follows these rules:

- Every relation, function, and operator reference is schema-qualified, so
  the code does not rely on `search_path`.
- Every value that leaves the session as text goes through
  `coldfront._canonical_text`.
- A change to the shape of a rendered qual or `INSERT` regenerates every
  pg_regress expected file that echoes the statement, including the `_1.out`
  variants.

### Checking Component Boundaries

Each component keeps a narrow set of dependencies. A change respects these
boundaries:

- SQL and the C extension make HTTP calls only through the catalog client in
  duckdb-iceberg, and only the Go programs call the Lakekeeper management API.
- The archiver orchestrates plain parameterized SQL through pgx and uses no
  DuckDB, Iceberg, or Arrow Go libraries.
- The compactor in `cmd/compactor/` stays a separate Go module, so its
  dependencies stay out of the archiver.

### Checking Tests and Dependencies

Tests prove the behaviour that a change claims, and a dependency workaround
proves that it is still needed. A change meets these conditions:

- A bug fix includes a test that fails on the unfixed code.
- A changed test still fails on the unfixed code in every interleaving and
  input that the test can meet.
- A workaround for a dependency names the dependency and the pinned version
  that shows the defect, and includes a test that runs the dependency without
  the workaround and fails once the defect is gone.
- A change to the base image recipe (`docker/Dockerfile.duckdb15-base` and the
  files that it copies) passes CI only after `base-image.yml` publishes the
  base image under the tag that `ci/base-ref.sh` prints.

### Checking Documentation

The documentation describes the current behaviour. A change keeps the
documentation consistent in these ways:

- `README.md` and `docs/index.md` change together where they share the
  introduction.
- A new, renamed, or removed guide in `docs/` updates the `mkdocs.yml`
  navigation and the `README.md` table of contents in the same commit.
- `mkdocs build --strict` passes with no warnings.

## Reporting Findings

Every reviewer reports findings by these rules, so that the reviews of a pull
request converge:

- Label each finding as Critical, Major, or Minor. A Critical finding can cause
  a failure listed in [Recognizing a Failure](#recognizing-a-failure). A Major
  finding causes an error or a wrong result on a narrower path. A Minor finding
  is any other defect.
- State whether the finding concerns code that the pull request changes or code
  that existed before the pull request.
- Omit findings that concern style alone.
- On a later review of the same pull request, review only the new commits, and
  do not repeat an earlier finding.
