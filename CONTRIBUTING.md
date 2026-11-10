# Contributing to ColdFront

Thanks for your interest in improving ColdFront.

## Getting started

- Build and run the stack: [Installation](docs/installation.md).
- Day-to-day usage and the two operating modes: [Usage](docs/using_coldfront/index.md).
- Architecture: [Architecture](docs/architecture_guides/index.md) (plus the tiered/decoupled
  deep dives).

## Development workflow

- **Test-driven.** Write the test first, then the implementation. Prioritise
  smoke / integration / endpoint tests over unit tests.
- **Run the gate before every commit:** `./run-ci-local.sh` — gofmt,
  golangci-lint, shellcheck, hadolint, actionlint, unit tests, build, the
  pg_regress layer, and the canonical user journey. GitHub Actions runs the
  identical `ci/matrix.sh` harness, so local and CI never diverge.
- **Bakery / mesh / distributed changes** must be modelled and verified in the
  TLA+ spec **first** ([docs/formal/](docs/formal/)) before the code change
  lands.
- Keep it KISS (minimal lines), DRY (no repeated logic), stdlib-first, and use
  plain parameterised SQL — no ORM.

## Commits & pull requests

- Short, imperative, one-line commit messages — `fix:` / `feat:` / `build:` /
  `deps:` / `refactor:` / `test:` / `docs:`, or a plain verb.
- Open the PR against `main` and complete the
  [pull-request checklist](.github/PULL_REQUEST_TEMPLATE.md).

## Reviewing Pull Requests

Every change to `main` goes through a pull request. A pull request merges into
`main` when the pull request meets these requirements:

- The description links the GitHub issue that the change resolves.
- CI passes, including the tests and the linters described in
  [Checking Code Style](#checking-code-style).
- CodeRabbit and Codacy have reviewed the pull request, and the author has
  fixed each finding or answered each finding on the pull request with a
  reason.
- A code owner listed in [.github/CODEOWNERS](.github/CODEOWNERS), other than
  the author, has approved the latest commit.

[REVIEW.md](REVIEW.md) describes what a defect looks like in ColdFront and
what the reviewer checks.

A code owner may merge their own pull request without a second approval when
the change alters no code or behaviour, such as a version bump, a changelog
cleanup, or a typo fix in a comment or a document. In the CI workflows under
`.github/workflows/` and in the release and packaging scripts, such a pull
request may change only version numbers. CI and the automated reviews must
still pass, and the author adds a comment to the pull request that explains why
the pull request merged without review.

## Checking Code Style

CI checks Go code with gofmt, go vet, and golangci-lint, the shell scripts
with shellcheck, the Dockerfiles with hadolint, and the GitHub workflows with
actionlint. CI also builds the documentation with `mkdocs build --strict` and
scans the commit history for secrets with gitleaks. On each pull request,
CodeRabbit runs shellcheck, hadolint, yamllint, markdownlint, and semgrep, and
Codacy runs its static analysis.

## Versioning

ColdFront uses two independent version numbers. Release tags follow three-part
[Semantic Versioning](https://semver.org) (`vMAJOR.MINOR.PATCH`, for example
`v1.0.0`); three parts are required because ColdFront is a Go module and the
toolchain treats only full `vX.Y.Z` tags as releases. The PostgreSQL extension
uses the conventional two-part version in its control file (`default_version`)
and upgrade-script names (`coldfront--1.0--1.1.sql`). Extension `1.0` ships
inside release `v1.0.0`.

## Licensing

ColdFront is under the PostgreSQL License ([LICENSE.md](LICENSE.md)). By
contributing, you agree your contributions are licensed under the same terms.
Redistributed third-party components and their notices are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
