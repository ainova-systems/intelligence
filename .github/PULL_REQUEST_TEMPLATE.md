## Summary

<!-- One paragraph: what changes and why. -->

## Type of change

- [ ] Bug fix
- [ ] New adapter
- [ ] New helper / skill
- [ ] Documentation
- [ ] Refactor (no behavior change)

## Verification

- [ ] `bash intelligence/sync/scripts/sync.sh` runs cleanly against an example project (note which `examples/<dir>/`)
- [ ] `lint_frontmatter` produces no new warnings
- [ ] Adapter changes tested with an actual IDE (note which one and what behavior was confirmed)
- [ ] Documentation updated (`README.md`, `docs/CONVENTIONS.md`, `docs/ADAPTERS.md`, `intelligence/INIT.md` as relevant)
- [ ] `CHANGELOG.md` has a new `## [X.Y.Z] — <date>` section (there is no `[Unreleased]` — every change ships as a release), and the version is bumped in lockstep: `scripts/VERSION`, the `sync_version` example in `INIT.md`, and every `examples/*/config.yaml`

## Notes for reviewers

<!-- Anything reviewers should pay extra attention to: edge cases, design tradeoffs, related PRs. -->
