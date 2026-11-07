# 0027 – Publish npm through trusted publishing

Date: 2026-11-07
Status: accepted

## Context

`release-npm` authenticated `npm publish` and `npm dist-tag` with the `NPM_TOKEN`
repository secret, a granular access token with publish rights on the
`ainova-systems` npm organization. [Decision 0001](0001-separate-legacy-intelligence-sync-from-intelligence.md)
named that secret, and the workflow of
[decision 0004](0004-publish-npm-from-github-releases.md) kept it. A token that
publishes from CI without a one-time password bypasses two-factor
authentication, and npm is restricting such tokens: the GitHub changelog entry
[Restricting npm bypass-2FA granular access tokens](https://github.blog/changelog/2026-07-31-restricting-npm-bypass-2fa-granular-access-tokens/)
(2026-07-31) says they lose direct publish, with January 2027 as the target. After that the Publish step
fails on the next release.

[Trusted publishing](https://docs.npmjs.com/trusted-publishers) (checked
2026-11-07) exchanges the workflow's GitHub Actions OIDC token for a short-lived
credential when the run matches the trusted publisher configured for the package
on npmjs.com: organization or user, repository, workflow file name and an
optional environment. npm tries it before any token. It needs npm 11.5.1 and
Node 22.14.0 or later, and `npm dist-tag` through it needs npm 11.21.0; Node 24
on the runner ships npm 11.19.1. npm does not validate the configuration when it
is saved, so a mismatch shows as `ENEEDAUTH` at publish, and a new configuration
expires unless a publish succeeds through it within two days. Provenance is
generated automatically for a public package from a public repository.

## Decision

1. `release-npm` publishes and moves dist-tags through trusted publishing. No
   step passes an npm token. The job keeps `id-token: write`, and
   `npm publish` keeps `--provenance`.
2. The job installs npm `11.21.1` exactly, right after `setup-node`, so the npm
   that packs and smoke-tests the package is the one that publishes it and runs
   `npm/align-dist-tags.sh`.
3. The trusted publisher for `@ainova-systems/intelligence` on npmjs.com names
   organization `ainova-systems`, repository `intelligence`, workflow file
   `release-npm.yml` and no environment, and allows both direct `npm publish`
   and `npm dist-tag`.
4. After the first release that publishes through it, the package's publishing
   access becomes "Require two-factor authentication and disallow tokens",
   `NPM_TOKEN` is revoked on npm, and the repository secret is deleted.

## Consequences

- The repository holds no long-lived npm credential, so no stored secret can
  publish the package.
- The repository and the workflow file name are part of the publishing identity.
  Renaming `release-npm.yml`, or renaming or transferring the repository, stops
  publishing until the trusted publisher names the new value. `repository.url`
  in `npm/package.json` must keep naming this repository.
- The identity is the file name, not its content: npm matches a run of
  `release-npm.yml` from any ref of this repository. The tag, version and `main`
  checks inside the workflow are not part of what npm verifies.
- The npm pin is exact, so a release never runs an npm version nobody chose. It
  moves in its own reviewed change, never below 11.21.0, and the next release is
  the check that publishing and dist-tags still work with it.
- Publishing now depends on configuration outside the repository. This record
  and the workflow header are where its values are written down.

## Rollout

The configuration expires and the token stays the fallback until the end, so
the order is fixed except for the first two steps, which may happen either way
round:

1. Configure the trusted publisher on npmjs.com with the values in decision
   point 3.
2. Merge the workflow change. A Release published after the merge but before
   step 1 fails at Publish, because no step passes the token.
3. Publish the next GitHub Release within two days of step 1. Confirm that
   Publish and the dist-tag step succeeded and that the npm version shows
   provenance. A release that misses the two days needs the configuration
   created again first.
4. Disallow tokens for the package, revoke `NPM_TOKEN` on npm and delete the
   repository secret.

## Backout

Until step 4, revert the workflow commit: the `NPM_TOKEN` secret still exists,
and the reverted workflow publishes with it as before. After step 4 a revert
alone cannot publish; it also needs a new token, the secret recreated and
publishing access that allows tokens, and after the January 2027 restriction a
bypass-2FA token cannot publish directly at all.

## Rejected

- **Keep `NPM_TOKEN`.** A bypass-2FA granular token loses direct publish under
  the restriction, and a long-lived publish credential in the repository is the
  exposure trusted publishing removes.
- **Staged publishing.** Every release would wait for a maintainer's two-factor
  approval on npm, a second release action beside publishing the GitHub Release,
  which decision 0004 made the only one.
- **A GitHub environment gate.** Naming an environment in the trusted publisher
  would limit publishing to jobs in that environment, with its own reviewers or
  branch rules. Not adopted now: the GitHub Release is already the approval step,
  and the workflow refuses a tag outside `main`. Adding it later means creating
  the environment, naming it in the job and naming it in the trusted publisher
  together, since a mismatch on either side fails the publish.
