# Roadmap

The product concept and the remaining ordered changes. Completed work belongs in the changelog; architecture rationale belongs in `decisions/`.

## Concept

**Positioning:** Build, version, govern and distribute AI agent intelligence across an organization. The mental model is npm for AI agent intelligence: one CLI, one package ecosystem and a project ready in under a minute.

| Term | Meaning | Concrete artifact |
|---|---|---|
| Intelligence Package | Versioned rules, agents and skills | `packages.<name>`; store at `.intelligence/packages/@scope/name/` |
| Intelligence Manifest | What a project consumes and where it renders | root `intelligence.yaml` |
| Intelligence Lockfile | Resolved URL, path, tag and SHA per package | `intelligence.lock` |
| Intelligence Registry | Ordered trusted name → source index | Git repository with `index.yaml` |
| Intelligence Sync | Deterministic renderer bundled with the CLI | engine invoked by `intelligence sync` |

“Pack” survives only in the historical `intelligence-dev-packs` repository name. Public product surfaces use “package.”

## Public surface

```text
intelligence CLI
  init
  sync [adapter]
  update [@scope/name] [--preview | --apply]
  package add | remove | list | search
  adapter list | create | enable | disable | remove
  status [--check]
  registry list | add | remove
    ↓
package resolver   trusted name → source · semver range → stable Git tag
    ↓
sync engine        local sources → native tool output
    ↓
adapters           agents · claude · cursor · copilot · codex · pi · opencode
```

`init` is universal: create a new Intelligence project, convert an eligible legacy Intelligence Sync project, or align an existing Intelligence project. Project-aware mutations align the project automatically before continuing; CI refuses an implicit tracked alignment and requires a reviewed `intelligence init --apply` diff. `sync` restores a missing locked package store before rendering.

Intelligence includes the root manifest/lock/store layout, semver-over-Git-tag packages, trust-list-only name resolution, explicit Git sources, bundle-seeded `@ainova-systems/sync`, transactional legacy-project conversion, npm distribution and fail-closed security checks. It remains prerelease until the owner approves a stable release.

## Ordered changes

### 1. Per-package manifests in intelligence-dev-packs

**Problem.** The repository versions its contents, but a package has no self-describing identity, so registries and lockfiles can display only what the index and Git tags imply.

**Shape.** Add `packages/<name>/package.yaml` with name, version and description. Keep repository-level tags while every package shares one release cadence; introduce per-package tags only if independent cadence becomes real. Surface metadata through `package list`, `package search` and `status --check` when present.

**Size:** S. **Now:** yes.

### 2. Independently pinned engine content

**Problem.** `@ainova-systems/sync` is a package by user experience but remains exact-pinned to the CLI engine and bundle-seeded, so its content cannot yet follow an independent range.

**Shape.** Allow an opted-in sync-content range to resolve like another package while preserving the bundle-seeded offline default. Only separate repository/version boundaries when independent pinning exists; avoid cross-repository release choreography before then.

**Size:** L. **Now:** later, after the CLI contract has proven stable.

### 3. Hosted registry and governance

**Problem.** Organization-scale governance eventually needs identity, private scopes, access control, audit and signing.

**Shape.** Provide a service that speaks the same `index.yaml` resolution contract, allowing the resolver implementation to change without changing project manifests or package identity.

**Now:** later; design from adoption evidence rather than speculation.
