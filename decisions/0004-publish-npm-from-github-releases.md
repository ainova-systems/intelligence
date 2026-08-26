# 0004 — Publish npm from GitHub Releases

Date: 2026-08-26
Status: accepted

## Context

The npm workflow accepted a manually selected channel and RC number independently of Git tags and
GitHub Releases. That created two release controls and allowed prereleases from arbitrary refs.

## Decision

1. Publishing a GitHub Release is the only action that starts npm publication.
2. `vX.Y.Z-rc.N` requires a GitHub prerelease and publishes to npm dist-tag `next`.
3. `vX.Y.Z` requires an ordinary GitHub release and publishes to npm dist-tag `latest`.
4. The tag's base version must match `engine/VERSION`, and its commit must be reachable from `main`.
5. The workflow keeps the existing package smoke test, npm provenance, and prerelease handling for
   `latest` until the first stable version exists.

## Consequences

- The GitHub Release page is the release history and manual approval surface.
- Tag, GitHub Release, npm version, and npm channel cannot be selected independently.
- Draft releases do not publish; publication starts only when the Release is published.
- A malformed tag, mismatched prerelease flag, wrong engine version, or off-main commit fails before
  npm publication.

## Rejected

- **Keep `workflow_dispatch`.** It duplicates the GitHub Release action and permits version/channel drift.
- **Publish on every tag push.** A tag alone provides no explicit GitHub Release approval step.
