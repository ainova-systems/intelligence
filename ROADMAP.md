# Roadmap

The product concept (final) and the ordered list of changes that implement it. Each entry states the problem it exists to fix, what depends on it, and a size, so any session can estimate whether it can be done now without re-deriving the reasoning. Shipped entries move to the CHANGELOG.

## Concept

**Positioning:** Build, version, govern and distribute AI agent intelligence across your organization. The mental model is *npm for AI agent intelligence*: one CLI, one package ecosystem, a new project configured in under a minute.

**Terminology (final):**

| Term | Meaning | Concrete artifact |
|---|---|---|
| Intelligence Package | The unit of distribution: a versioned set of rules / agents / skills | `packages.<name>` in the manifest; store at `.intelligence/packages/@scope/name/` |
| Intelligence Manifest | A project's declaration of what it consumes and where it goes | root `intelligence.yaml` (v2); `intelligence/config.yaml` for vendored (v1) |
| Intelligence Lockfile | The resolved state: per package, url + path + resolved tag + SHA | `intelligence.lock` |
| Intelligence Registry | A git repo holding an `index.yaml` (name → source); the manifest's trust list | GitHub repo first; a hosted service speaks the same contract later |
| Intelligence Sync | The engine that renders packages into each tool's native format | `intelligence/sync/` — an internal layer, no longer the product interface |

"Pack" survives only in the `intelligence-dev-packs` repo name and its history; every user-facing surface says *package*.

**Layering:**

```
intelligence CLI        init · add · remove · install · update · upgrade · list · search · sync · doctor · status · registry · migrate
  → package resolver    name → source (trusted registries only) · range → version (git tags)
  → sync engine         sync.sh — role unchanged, CLI mode gated behind IS_CLI=1
  → adapters            claude · cursor · copilot · codex · pi · opencode · agents
```

**Shipped in 0.11.0** (branch `feature/intelligence-cli` — see the CHANGELOG entry for the full record): the `intelligence` CLI with the v2 project layout (root `intelligence.yaml`, gitignored `.intelligence/` store, committed `intelligence.lock`); Intelligence Packages with semver-over-git-tags; **trust-list-only** name resolution (registries the project explicitly added — no built-in catalog, no `@org/name` → github guessing; registry-less installs are explicit `github:`/`git+` sources); the engine's own content as the auto-selected, bundle-seeded `@ainova-systems/sync` package; the transactional `migrate`; npm packaging as `@ainova-systems/intelligence` with the `release-npm` pipeline; the `legacy-golden` + `legacy-golden-code` CI guarantees that vendored outputs stay byte-identical and that engine-script changes are byte-neutral; and adversarial-review security hardening (validated untrusted names, argument-injection-safe git calls, staged/rolled-back migrate). The vendored flow remains fully supported and prints a one-line migrate recommendation.

## Ordered changes

### 1. Per-package manifests in intelligence-dev-packs

**Problem.** dev-packs versions the repo, not the packages: a package has no self-describing identity, so registries and lockfiles display only what the index and tags imply.

**Shape.** `packs/<name>/package.yaml` with name, version, description; repo-level tags keep versioning all packages lockstep (per-package tags only if release cadences ever actually diverge). The CLI surfaces the metadata in `list`/`search`/`doctor` when present — an enhancement, not a dependency: the provides convention already makes dev-packs consumable.

**Size:** S (a day). **Now:** yes.

### 2. Independently-pinned engine content — *later*

**Problem.** `@ainova-systems/sync` shipped in 0.11.0 as a package *by UX* but bundle-seeded and exact-pinned to the CLI's engine, so a project cannot yet pin engine content independently of the CLI, and vendored projects still update through the bespoke `update.sh` channel.

**Shape.** Let the sync package resolve and pin like any other (drop the bundle-seed exact-pin for projects that opt into a range), so `update`/lockfile drive engine content and `update.sh` becomes the internal executor for vendored projects only. Only after the CLI has proven stable across a few releases: this touches the update contract every project depends on, and the bundle-seed offline guarantee must be preserved as the default.

**Size:** L. **Now:** no.

### 3. Hosted registry and governance — *later*

**Problem.** The positioning's "govern": identity, private scopes, RBAC, audit, signing.

**Shape.** A registry service speaking the same `index.yaml` contract the CLI already resolves, so the CLI swaps resolvers without changing. Nothing else is designed now — designing governance before CLI adoption data exists would be speculation.

**Now:** no.
