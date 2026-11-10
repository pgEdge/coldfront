## Summary

<!-- What does this change and why? Link the issue that it resolves. -->

Closes #

## Checklist

- [ ] The pull request links a tracking issue.
- [ ] `./run-ci-local.sh` passes (gofmt, golangci-lint, shellcheck, hadolint,
  actionlint, build, pg_regress, journey).
- [ ] The change includes unit tests, written before the code, or the Testing
  section explains why it has none.
- [ ] The change includes regression tests in `extension/coldfront/test/`, or
  the Testing section explains why it has none.
- [ ] The Testing section notes any impact on the integration tests
  (`ci/journey.sh` and the CI matrix).
- [ ] The change updates `README.md` and `docs/`, or the Notes for Reviewers
  explain why it needs no update.
- [ ] The change adds no secrets, and the Risk section covers its security
  impact.
- [ ] A bakery, mesh, or distributed change updates the TLA+ model and re-runs
  TLC (`docs/formal/`).
- [ ] Author's AI review completed and findings addressed.
- [ ] Commit messages are short and imperative.

## Testing

<!-- How was the change tested? -->

## Risk

<!-- What could go wrong, and what would the automated checks not catch? -->

## How to Revert

<!-- How can the change be undone if needed? -->

## Notes for Reviewers

<!-- Known limitations, design rationale, or follow-up tasks. -->
