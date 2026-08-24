# Roadmap

The product concept (final) and the ordered list of changes that implement it. Each entry states the problem it exists to fix, what depends on it, and a size, so any session can estimate whether it can be done now without re-deriving the reasoning. Shipped entries move to the CHANGELOG.

## Concept

**Positioning:** Build, version, govern and distribute AI agent intelligence across your organization. The mental model is *npm for AI agent intelligence*: one CLI, one package ecosystem, a new project configured in under a minute.

**Terminology (final):**

| Term | Meaning | Concrete artifact |
|---|---|---|
| Intelligence Package | The unit of distribution: a versioned set of rules / agents / skills | `packages.<name>` in config (today `packs:`) |
| Intelligence Manifest | A project's declaration of what it consumes and where it goes | `intelligence/config.yaml` (role name; the file does not move) |
| Intelligence Lockfile | The resolved state: per package, url + resolved tag + SHA | `intelligence.lock` (formalizes today's per-mirror `.pack` stamps) |
| Intelligence Registry | The name → source index that makes `@scope/name` the whole interface | GitHub-backed index first; a hosted service speaks the same contract later |
| Intelligence Sync | The engine that renders packages into each tool's native format | `intelligence/sync/` — an internal layer, no longer the product interface |

"Pack" survives only in the `intelligence-dev-packs` repo name and its history; every user-facing surface says *package*.

**Layering:**

```
intelligence CLI        init · add · remove · install · update · list · sync · doctor
  → package resolver    name → source (registry) · range → version (git tags)
  → sync engine         sync.sh — role unchanged
  → adapters            claude · cursor · copilot · codex · pi · opencode · agents
```

**Shipped in 0.11.0** (branch `feature/intelligence-cli` — see the CHANGELOG entry for the full record): the `intelligence` CLI with the v2 project layout (root `intelligence.yaml`, gitignored `.intelligence/` store, committed `intelligence.lock`), Intelligence Packages with semver-over-git-tags and the three-level name resolution (scope bindings → bundled index → `@org/name` convention), the transactional `migrate` from the vendored setup, npm packaging as `@ainova-systems/intelligence` with the `release-npm` pipeline, and the `legacy-golden` CI guarantee that vendored projects' outputs stay byte-identical. The vendored flow remains fully supported; it prints a one-line migrate recommendation.

## Ordered changes

### 1. Per-package manifests in intelligence-dev-packs

**Problem.** dev-packs versions the repo, not the packages: a package has no self-describing identity, so registries and lockfiles display only what the index and tags imply.

**Shape.** `packs/<name>/package.yaml` with name, version, description; repo-level tags keep versioning all packages lockstep (per-package tags only if release cadences ever actually diverge). The CLI surfaces the metadata in `list` and `doctor` when present — it is an enhancement, not a dependency: the provides convention already makes dev-packs consumable.

**Size:** S (a day). **Now:** yes.

### 2. The engine as the core package — *later*

**Problem.** The engine ships inside the CLI package, so engine and CLI versions move together; a project cannot pin the engine independently, and vendored projects still update through the bespoke `update.sh` channel.

**Shape.** The engine published as `@ainova-systems/sync` and listed in the manifest like any package; engine install and update ride the resolver and lockfile (`.intelligence/engine` becomes an installed package rather than staged CLI content), with `update.sh` reduced to the internal executor for vendored projects. Migrations stay, and run from the freshly resolved version — the self-overwrite dance disappears. Only after the CLI has proven stable across a few releases: this touches the update contract every project depends on.

**Size:** L. **Now:** no.

### 3. Hosted registry and governance — *later*

**Problem.** The positioning's "govern": identity, private scopes, RBAC, audit, signing.

**Shape.** A registry service speaking the same `index.yaml` contract the CLI already resolves, so the CLI swaps resolvers without changing. Nothing else is designed now — designing governance before CLI adoption data exists would be speculation.

**Now:** no.
