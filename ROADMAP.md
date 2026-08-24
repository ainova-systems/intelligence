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

**The estimation baseline — what 0.10.1 already has.** The hard half of a package manager exists: fetch + materialize + mirror with fail-closed validation *is* the install mechanics; the `.pack` stamp (url, ref, resolved SHA) *is* a per-package proto-lockfile; `update.sh` + the migration chain *is* the machinery a config-schema change rides on; the adapters *are* the distribution problem no competitor has solved. What is missing is exactly four layers: a CLI facade, name resolution, version resolution, and a single lockfile — all buildable in the existing zero-dependency bash + awk toolchain.

## Ordered changes

### 1. The `intelligence` CLI facade — *minor*

**Problem.** The engine is operated by full script paths (`bash intelligence/sync/scripts/sync.sh`) and editor-bound skills; a new user must understand the layout before the first sync. A product interface is one command.

**Shape.** `intelligence/sync/scripts/cli.sh` plus a thin `intelligence` launcher. Subcommands: `init` (detect targets, write minimal config + stamp — INIT.md's job, automated), `add` / `remove` (edit `packages:` and `sources.*` block-form and comment-preserving, the same discipline `migrate_to_0_10_0` already practices), `list`, `sync [target]` and `update` (delegate verbatim to the existing scripts), `doctor` (expose `validate_pack_refs`, `lint_frontmatter`, drift and layout checks without running adapters), `status`. No new parsing — everything reads through `lib/common.sh`.

**Depends on:** nothing. **Size:** M (days). **Now:** yes — every operation it fronts already exists.

### 2. Package versions and the lockfile — *minor*

**Problem.** `ref:` pins one commit forever and silently; there are no ranges, no `install` that restores a fresh checkout, and the only record of what a pin resolved to is a stamp buried per mirror — transient packages leave no record at all.

**Shape.** `packages.<name>.version: "^1.4.0"` (semver range; `ref:` stays as the escape hatch for a branch or SHA). Resolution is `git ls-remote --tags` plus a POSIX-awk semver compare — no clone to resolve, and no `sort -V`, which BSD sort lacks. `intelligence.lock` beside the manifest records name, url, requested range, resolved tag, SHA. `intelligence install` fetches exactly the lock; `intelligence update [pkg]` re-resolves ranges and rewrites it; sync reads the lock when present so a run never resolves a range implicitly.

**Depends on:** 1 (the CLI carries the new verbs). **Size:** M–L (about a week). **Now:** yes — resolution over git tags is plain plumbing on the existing fetch path.

### 3. Named packages and the registry index — *breaking*

**Problem.** Adding a package still means knowing its git URL and subpath. The name must be the whole interface: `intelligence add @ainova/core`, nothing else.

**Shape.** `packs:` becomes `packages:` (`migrate_to_*` rewrites the config; post-condition: no `packs:` key remains). `@scope/name` resolves through a registry index — a YAML mapping name → `{url, path}` — with a default index for `@ainova/*` pointing at `intelligence-dev-packs`, and a `registries:` override for private organizations. The CLI writes the *resolved* declaration into the manifest, so sync stays offline-capable and the fail-closed validation contract is untouched.

**Depends on:** 1, 2. **Size:** M. **Now:** yes — the index is read by the existing YAML helpers, and the migration machinery is proven.

### 4. Package manifests in intelligence-dev-packs

**Problem.** dev-packs versions the repo, not the packages: a package has no self-describing identity, so a registry entry or a lockfile line has nothing to display.

**Shape.** `packs/<name>/package.yaml` with name, version, description. Repo-level tags keep versioning all packages lockstep — per-package tags only if release cadences ever actually diverge. Registry index entries point at these paths.

**Depends on:** nothing — can land first. **Size:** S (a day). **Now:** yes.

### 5. End-to-end proof on intelligence-dev-packs

**Problem.** The loop must be demonstrated on real content, not examples: this is the product's acceptance test.

**Shape.** Throwaway project: `intelligence init` → `intelligence add @ainova/core` → `intelligence sync` → generated `.claude/` and `AGENTS.md` verified; then a fresh clone restored by `intelligence install` alone. In CI: a hermetic version against a `file://` fixture registry (the house pattern the `packs` job set), plus one live job pinned to a dev-packs tag.

**Depends on:** 1–4. **Size:** S–M. **Now:** yes, immediately after 1–4.

### 6. npm distribution — `@ainova/intelligence`

**Problem.** "Clone the repo and run a script" is not an install story. `npm install -g @ainova/intelligence` is.

**Shape.** An npm package whose bin is a small Node launcher executing the bundled bash engine — bash is a hard requirement, present wherever git is, and Git Bash on Windows is already the supported path. `intelligence init` in a project then vendors the engine exactly as `update.sh` installs it today. A standalone binary is a later distribution channel, not part of this entry.

**Depends on:** 1. **Size:** S–M. **Now:** yes, any time after 1.

### 7. The engine as the core package — *later*

**Problem.** The engine still updates through its own bespoke channel (`update.sh`) while providing the package mechanism to everyone else; one distribution story should carry both.

**Shape.** The engine published as `@ainova/sync`, listed in the manifest like any package; engine install and update ride the resolver and lockfile, with `update.sh` reduced to the internal executor of that path (migrations stay, and run from the freshly resolved version — the self-overwrite dance disappears). Vendoring becomes the package-level choice it already is for every other package: `mirror:` present → the engine is materialized and committed (today's behaviour, the default — no forced migration); `mirror:` absent → the engine is external, living in the CLI cache, and `intelligence/sync/` leaves the project tree entirely (its skills reached as `@ainova/sync/skills`, docs read from the package). One mechanism, no engine-specific mode.

**Size:** L. **Now:** no.

### 8. Hosted registry and governance — *later*

**Problem.** The positioning's "govern": identity, private scopes, RBAC, audit, signing.

**Shape.** A registry service speaking the same index contract as entry 3, so the CLI swaps resolvers without changing. Nothing else is designed now — designing governance before CLI adoption data exists would be speculation.

**Now:** no.

---

Entries 1–6 are implementable now, in order, within the existing zero-dependency toolchain; 4 can land at any point. Entries 7–8 are sequenced after the CLI proves the developer experience.
