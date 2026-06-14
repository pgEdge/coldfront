# Contributing to ColdFront

Thanks for your interest in improving ColdFront.

## Getting started

- Build and run the stack: [INSTALL.md](INSTALL.md).
- Day-to-day usage and the two operating modes: [USAGE.md](USAGE.md).
- Architecture: [ARCHITECTURE.md](ARCHITECTURE.md) (plus the tiered/decoupled deep dives).

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
  `deps:` / `refactor:` / `test:` / `docs:`, or a plain verb. **No AI attribution.**
- Open the PR against `main` and complete the
  [pull-request checklist](.github/PULL_REQUEST_TEMPLATE.md).
- **Never** put real hostnames, database/table/schema/role names, file paths, IPs,
  or credentials in code, tests, docs, or commit messages — use generic
  placeholders (`mydb`, `localhost`, `events`, …).

## Licensing

ColdFront is under the PostgreSQL License ([LICENSE.md](LICENSE.md)). By
contributing, you agree your contributions are licensed under the same terms.
Redistributed third-party components and their notices are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
