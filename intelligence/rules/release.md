---
paths:
  - "engine/VERSION"
  - "examples/**"
  - "npm/**"
  - ".github/workflows/**"
description: "Version lockstep and the GitHub-Release-only publishing path"
---

# Versioning and releases

`engine/VERSION`, every example's `schema_version` and every example's exact
`@ainova-systems/sync` pin move together in one commit. CI's `repo-purity` job fails
the build otherwise: examples are "ready to sync at the current engine" fixtures, so
a bumped VERSION with an un-bumped example turns the smoke job into a confusing
exit 6 instead of a clear failure.

`npm/build.sh` assembles the distribution from `cli/`, `engine/` and `packages/sync/`.
npm publishes with provenance, so `npm/package.json` repository metadata must keep
naming this repository.

Publishing a GitHub Release is the only release action — there is no separate npm
workflow to trigger. `release-npm` runs on `release.published`:

- a GitHub prerelease tagged `vX.Y.Z-rc.N` publishes `X.Y.Z-rc.N` to dist-tag `next`;
- an ordinary GitHub release tagged `vX.Y.Z` publishes `X.Y.Z` to dist-tag `latest`;
- the tag's base version must equal `engine/VERSION`, and its commit must be
  reachable from `main`;
- `engine/VERSION` and `schema_version` never carry the npm RC suffix.

Create and push the tag from a reviewed `main` commit, then publish the Release for
that tag and mark an RC as a prerelease.

The Intelligence tag line starts at `v0.11.0`. Legacy Intelligence Sync tags are
never recreated here.
