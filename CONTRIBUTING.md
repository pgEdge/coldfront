# Contributing to ColdFront

Thanks for your interest in improving ColdFront.

## Getting started

- Build and run the stack: [Installation](docs/installation.md).
- Day-to-day usage and the two operating modes: [Usage](docs/usage.md).
- Architecture: [Architecture](docs/architecture.md) (plus the tiered/decoupled deep dives).

## Development workflow

- **Test-driven.** Write the test first, then the implementation. Prioritise
  smoke / integration / endpoint tests over unit tests.
- **Run the gate before every commit:** `./run-ci-local.sh` — gofmt,
  golangci-lint, unit tests, build, the pg_regress layer, and the canonical user
  journey. GitHub Actions runs the identical `ci/matrix.sh` harness, so local and
  CI never diverge.
- **Bakery / mesh / distributed changes** must be modelled and verified in the
  TLA+ spec **first** ([docs/formal/](docs/formal/)) before the code change lands.
- Keep it KISS (minimal lines), DRY (no repeated logic), stdlib-first, and use
  plain parameterised SQL — no ORM.

## Commits & pull requests

- Short, imperative, one-line commit messages — `fix:` / `feat:` / `build:` /
  `deps:` / `refactor:` / `test:` / `docs:`, or a plain verb.
- Open the PR against `main` and complete the
  [pull-request checklist](.github/PULL_REQUEST_TEMPLATE.md).

## Versioning

ColdFront uses two independent version numbers. Release tags follow
three-part [Semantic Versioning](https://semver.org)
(`vMAJOR.MINOR.PATCH`, for example `v1.0.0`); three parts are required
because ColdFront is a Go module and the toolchain treats only full
`vX.Y.Z` tags as releases. The PostgreSQL extension uses the conventional
two-part version in its control file (`default_version`) and
upgrade-script names (`coldfront--1.0--1.1.sql`). Extension `1.0` ships
inside release `v1.0.0`.

## Licensing

ColdFront is under the PostgreSQL License ([LICENSE.md](LICENSE.md)). By
contributing, you agree your contributions are licensed under the same terms.
Redistributed third-party components and their notices are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
