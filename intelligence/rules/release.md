---
description: "Concrete pending versions, lockstep files, and the GitHub-Release-only publishing path"
---

# Versioning and releases

Every PR merged into `main` belongs to one concrete version. Read
`engine/VERSION`, then use `gh release view vX.Y.Z` to determine whether its
non-prerelease GitHub Release is already published:

- When it is published, the first following PR selects the next SemVer version,
  moves all lockstep files, and creates `## [X.Y.Z]` in `CHANGELOG.md`.
- While it is not published, later PRs keep that pending version and add their
  lines to its existing section.
- When a pending patch receives a feature or breaking change, promote the
  pending version to the required SemVer level before merge.

Changelog headings contain the version only, with no date. GitHub Release is the
authority for publication time. The file has no `[Unreleased]` section: exact
pending versions provide the same collection point without ambiguous release
state.

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
- a non-prerelease GitHub Release tagged `vX.Y.Z` publishes `X.Y.Z` to dist-tag `latest`;
- the tag's base version must equal `engine/VERSION`, and its commit must be
  reachable from `main`;
- `engine/VERSION` and `schema_version` never carry the npm RC suffix.

Create and push the tag from a reviewed `main` commit whose version and changelog
are already prepared, then publish the Release for that tag and mark an RC as a
prerelease. The release workflow publishes artifacts and never commits back to
`main`; the immutable tag must contain the exact state it releases.

The Intelligence tag line starts at `v0.11.0`. Legacy Intelligence Sync tags are
never recreated here.
