# Development Preferences

## Process
- Use Test Driven Development: write tests first, then implementation. Not after, not alongside — before.
- Priority: smoke tests, integration tests, and endpoint tests over unit tests
- Every public function should have a unit test
- Run `make test` after every change
- MUST run `./run-ci-local.sh` before every commit — it runs gofmt, golangci-lint, tests, build, Docker integration tests
- GitHub Actions CI (when added) must always be identical in steps to `run-ci-local.sh` — never let them diverge
- Update README.md as you implement functionality; update ARCHITECTURE.md in the same commit as the structural change it describes

## Git
- NEVER overwrite or delete files without checking if they are committed
- NEVER use the word "release" in git tag names (use "v0.1.0" not "Release v0.1.0")
- NEVER include Co-Authored-By or any Claude/AI attribution in commit messages
- Commit messages should be short, one-line, imperative (e.g. "fix: bump Go from 1.22 to 1.24")
- No `chore:` prefix — use `fix:`, `feat:`, `build:`, `deps:`, `refactor:`, `test:`, `docs:` or a plain verb
- No verbose multi-paragraph commit message bodies
- NEVER use `git checkout` or `git restore` on files with uncommitted changes — use Edit tool instead
- Prefer adding specific files by name (`git add src/foo/bar.go`) over `git add -A` or `git add .` — protects against accidentally staging secrets or large binaries
- When splitting a commit, land deps/extras declarations AFTER the code that consumes them — every intermediate commit in history should represent a working state
- Never push, force-push, or open PRs without explicit user instruction. Never skip hooks (`--no-verify` etc.) without explicit user instruction.

## Code Style
- KISS: absolute minimum lines of code
- DRY: no repeated logic — extract shared code, but only when there are at least two real callers
- stdlib-first: use Go standard library where possible
- No ORM: plain SQL with parameterized queries
- Hand-written mocks: no mock frameworks, define mock structs locally in test files
- Explicit error handling, no panic
- No speculative abstractions, no backwards-compatibility shims for scenarios that can't happen, no hypothetical-future configurability
- Don't hardcode lists that can be derived at runtime (e.g. column names from pg_catalog). Every hardcoded value is a future bug.

## Working Style
- Before making changes that span multiple files, mentally trace the FULL end-to-end path: data origin → what the code does with it → where it lands → how the query pipeline sees it
- Don't refactor interfaces (add parameters, rename types) until you've verified the concrete scenario works. Test the simple case first, abstract second.
- When an e2e test fails: read the FULL error, understand the root cause, simulate the fix mentally, THEN make ONE targeted change. Don't whack-a-mole.
- Never use `sudo` — if an operation requires root, tell the user and let them handle it

## Files to Ignore
- NEVER read, reference, or act on `OLD_PLAN.md.IGNORE`

## Dependencies (keep minimal)
- github.com/jackc/pgx/v5 (PostgreSQL driver — use pgxpool directly)
- gopkg.in/yaml.v3 (config)
- github.com/stretchr/testify (test assertions only)
- pg_duckdb: stock upstream `pgduckdb/pgduckdb:18-v1.1.1` — no fork, no patches
- `extension/coldfront/` — PGXS C extension. Requires `pg_config` and PG dev headers. Built inside the Docker image; users on bare-metal install with `make && make install`.

## Releases
- Build 4 static binaries per release: linux-amd64, linux-arm64, darwin-amd64, darwin-arm64
- Build command: `CGO_ENABLED=0 go build -ldflags="-s -w"`
- Release notes format: `## Added` / `## Changed` / `## Fixed`
  - Only list user-facing changes — no internal test additions, no same-cycle fix churn
  - `## Fixed` is for bugs that existed in the previous release, not things broken and fixed in the same cycle

## Architecture
- All Iceberg read/write happens through pg_duckdb (inside PostgreSQL)
- Lakekeeper provides the Iceberg REST catalog
- Any S3-compatible object store (SeaweedFS, MinIO, AWS S3, GCS, etc.)
- The archiver is a thin SQL orchestrator — no DuckDB/Iceberg/Arrow Go libraries
