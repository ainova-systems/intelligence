# Roadmap

Build, version and distribute project rules, agents and skills across AI tools.
Make existing skill ecosystems easy to consume while preserving explicit source
trust, reproducible package state and deterministic native rendering.

Reviewed September 5, 2026. These are planned changes, not current CLI features
or release commitments. Completed work belongs in `CHANGELOG.md`; architectural
rationale, accepted direction and unresolved design choices are in
[decision 0006](decisions/0006-safe-skill-imports-and-adapter-growth.md).

## Product boundaries

| Resource | Responsibility |
|---|---|
| Intelligence Package | Versioned rules, agents and skills, installed under `.intelligence/packages/` |
| `intelligence.yaml` | Requested package and project configuration |
| `intelligence.lock` | Resolved source identity and reproducible package state |
| Registry | Ordered trusted name-to-source lookup |
| CLI | Discovery, acquisition, selection, verification and package lifecycle |
| Sync engine | Local sources rendered through adapter ownership contracts |

Keep the public groups `init`, `sync`, `update`, `package`, `adapter`, `status`
and `registry`. Put new content operations under `package`, catalog lookup under
`registry`, and target support under `adapter`. Exact new flags and schemas are
design deliverables. Preserve existing `github:org/repo#path` and `git+` syntax.

The core remains project-first. Recurring team workflows use managed installation
and a committed lock. Temporary skill use is an optional evaluation path. Skills,
scoped rules and custom agents remain distinct capabilities.

## Delivery order

| Step | Outcome | Prerequisites |
|---|---|---|
| 1 | Restore the exact locked commit and report integrity accurately | None |
| 2 | Share skill destinations without losing unrelated content | None; coordinate with 1 |
| 3 | Define import identity, selection, parsing and compatibility contracts | 1–2 inform the design |
| 4 | Import selected skills from conventional Git repository layouts | 1–3 |
| 5 | Read local Claude/Cursor plugin catalogs | 3–4 |
| 6 | Add a small set of maintained, widely adopted tool integrations | 2 and capability design; can proceed alongside 4–5 |
| 7 | Evaluate a skill temporarily and promote the same snapshot | 3–4; 5 only for catalog inputs |
| 8 | Resolve selected remote plugins through trusted marketplace registries | 1, 3–5 |
| 9 | Optimize acquisition and consider additional transports | Measured demand after 4/8 |

### Batch: exact locked restore (step 1, first slice)

Scope: restore Git packages by locked commit even when the requested branch or
tag moves. Keep requested refs for updates and retain the offline bundle seed.
Version intent: patch fix in pending `0.11.8`.

- [x] Restore retained commits after branch and tag movement without changing
  the manifest or lock; verify the restored content and generated output.
- [x] Refuse unavailable commits and malformed/missing required commit identities
  before publishing that package; preserve existing output and the lock on failure.
- [x] Verify matching release-bundle identities and explicitly report the
  development-bundle exception when commit verification is unavailable.
- [x] Preserve update planning, manifest/lock drift refusal and repeatable sync.
- [x] Preserve normalized checkout bytes for explicit commit refs under inherited
  Git settings.

Remaining step 1 work: comprehensive lock-schema/identity validation, installed
content rehashing, transactions across package store/manifest/lock/render state,
and bounded Git/authentication diagnostics. This batch verifies acquisition of
each restored package; it does not make a multi-package restore transactional.
Rollback: revert this batch; the lock format is unchanged, so older clients can
still read it and retain their earlier moved-ref refusal behavior.

### 1. Exact restore and integrity boundaries

**Problem.** Frozen restore currently fetches the locked ref, then compares its
commit SHA. If a branch advances, restoration fails even when the old commit is
still available. The existing store is also not fully rehashed during ordinary
sync. Output rollback does not cover every package-store/manifest/lock mutation.

**Deliver.** Fetch and verify the locked commit; keep requested refs for update
planning. Define validation for lock schema, required identities and installed
content. Specify and stage the state covered by package operations before claiming
transactional installation. Keep the bundle-seeded offline default and make any
development-build integrity exception explicit. Improve bounded Git failures and
authentication diagnostics without extracting credentials.

**Acceptance.** A fresh clone restores a retained commit after a branch/tag moves;
an unavailable commit fails without substituting HEAD or changing the lock. Reject
manifest/lock drift and malformed required identity before writes. A tampered store
is detected by the chosen integrity check. A late fetch/render failure preserves
the prior state covered by the operation's documented transaction. Existing
moved-tag refusal tests are replaced only with stronger exact-commit assertions.

### 2. Skill ownership and coexistence

**Problem.** Shared skill cleanup currently owns every immediate directory and
symlink. Another manager's files can disappear on the next sync. Name normalization
and multiple consumers create additional collision and removal risks.

**Deliver.** Track generated skill ownership and consuming targets. Plan creates,
updates, removals and conflicts before writing. Preserve unknown entries; distinguish
explicit project overrides from unrelated imports with the same destination.
Migrate existing unmarked output without silently claiming external files. Include
ownership metadata in snapshot/rollback and Git-policy design.

**Acceptance.** Unrelated skills survive sync and removal. Same-name, case-only and
normalized-name collisions produce a clear decision before mutation. Removing one
target preserves another target's shared skill. Source/output parent-child overlap,
symlink aliases and junctions cannot delete source content. A failed later adapter
restores ownership and outputs; a second sync is idempotent. Repair a missing output
even when the source hash has not changed.

### 3. Import inventory and compatibility contract

**Problem.** A package name, plugin name, skill display name, source path and output
directory are different identities. Additional formats need JSON parsing and a
selection model that older clients cannot silently ignore.

**Deliver.** Define CLI importers with format-specific readers feeding one common
inventory; reserve adapters for output targets. Design that CLI-owned inventory
containing source URL/commit, format, plugin/path identity, component kind, name,
required resources, effective destination
and compatibility findings. Keep requested selections in intent and resolved paths
and digests in locked state. Define an explicit all-selection policy. Compare a
maintained JSON parser with a small CLI-only Node helper; resolve the runtime boundary
through a separate decision before implementation. Preserve the Bash sync engine.

**Acceptance.** Equivalent acquisition paths yield the same inventory. Every explicit
selector must resolve; missing or ambiguous items never become a broader install.
Inventory/preview does not change project configuration or generated output. Invalid
declared manifests report their location and reason. Root skill, package and plugin
identities remain distinct. Old-client restore/sync behavior is tested; changes
that cannot satisfy the same-major compatibility contract require a major release.

### 4. Selective external skill imports

**Deliver.** Support repositories with a root `SKILL.md`, conventional `skills/`,
recognized tool directories and bounded nested catalogs. Select complete bundles
without requiring publisher-specific package metadata. Reuse the existing Git
resolver, package lifecycle and engine copy/finalization helpers. Allow a local
checkout for inventory/evaluation; managed installation must have a reproducible
source or an explicitly designed vendoring contract, not a machine-local path in
a shared lock.

**Acceptance.** Cover root skills with assets, nested category directories, supporting
folders containing another `SKILL.md`, malformed YAML, internal skills, hidden files,
binary assets and executable scripts. Do not reimport generated output or examples
through unbounded recursion. Preserve stable selection when upstream adds skills.
Update/removal tracks the selected path even when its display name differs.
Broken/escaping links and declared missing resources produce actionable diagnostics.
Static inspection does not promise every instruction is portable between tools.

### 5. Local plugin catalogs

**Deliver.** Separate readers for `.claude-plugin/plugin.json`,
`.claude-plugin/marketplace.json`, `.cursor-plugin/plugin.json` and
`.cursor-plugin/marketplace.json`. Resolve selected local plugins and component
paths inside the pinned repository into step 3's inventory. Read child manifests
and apply each format's documented defaults and merge semantics. Record which
format won when a repository contains multiple manifests.

**Acceptance.** Dated fixtures cover string/array fields, conventional and explicit
skill paths, Claude `strict` modes, `pluginRoot`, curated shared roots, Cursor
replacement semantics, malformed types and physical path escapes. Selecting one
skill must not import unselected siblings accidentally. Unsupported remote sources,
hooks, MCP, commands and declared runtime dependencies are visible. Discovery never
executes catalog-provided commands. See [Claude marketplace format](https://code.claude.com/docs/en/plugin-marketplaces)
and [Cursor plugin format](https://cursor.com/docs/reference/plugins).

### 6. Focused adapter expansion

**Deliver.** A capability inventory separating skills, always-on instructions,
scoped rules, custom-agent definitions and host-specific execution. Record product
surface/version, native discovery paths, actual generated destinations and official
references. Shared-file compatibility can be smaller than a dedicated adapter.
Keep source fetching out of adapters and reuse shared rendering once per destination.

**Selection gate.** A new built-in needs current adoption evidence, maintained
interfaces and a real repository use case. Publisher reach, active users, downloads
and GitHub stars are not interchangeable. Start with Cline, Antigravity and Qoder;
evaluate OpenHands and Kiro next. Implement one validated target at a time. The
candidate assessment below is not a commitment to add every listed tool.

**Acceptance.** A host smoke test proves each advertised capability: instructions
load once, a skill can read its resources, scoped rules activate only as intended,
and exported agents respect the documented model/tool mapping. Unsupported channels
are explicit. Test project/user precedence, absent native directories, upgrade,
removal, shared consumers and rollback. Keep Linux and Windows/Git Bash fixtures in
the configured gate runner. Add official links when an adapter becomes supported.

### 7. Temporary skill evaluation

**Recommendation.** Install and lock recurring project skills. Offer use without
registration for evaluation and occasional tasks; do not make it the default for
team workflows or imply it prevents the agent from changing project files.

**Deliver.** Materialize one selected bundle in an inspectable temporary snapshot,
record source/commit/digest, and generate a prompt or entry point with correct
support-file paths. Do not edit the project manifest/lock, adapter state or generated
skill destinations. Define retention/cleanup and support promotion of the evaluated
snapshot to a managed install. Agent process launching is a separate later feature.

**Acceptance.** Explicit selection is required for ambiguous sources. Scripts and
assets remain reachable for the declared lifetime. No hooks/dependency setup is
executed implicitly; unsupported runtime requirements are reported. Temporary use
does not claim native permission enforcement. Promotion uses the evaluated bytes
even if upstream changed. Cleanup never removes files still required by a session.

### 8. Marketplace-backed registries

**Deliver.** Add supported catalog formats to the existing ordered trust list and
package search/add flow. Resolve selected remote Git plugins with provenance for
both catalog and plugin source. Freeze catalog-derived selection/configuration for
restore; updates use the locked source until an explicit source-change operation.
Use an explicit format choice when multiple catalogs conflict. Preserve global
package identity and define marketplace/plugin name mapping before implementation.

**Acceptance.** Restore works without the live catalog and does not widen selection.
A catalog repoint cannot silently redirect an installed package. Metadata versions
are not mistaken for Git tags. Same-repository plugins at different refs are checked
independently. A missing plugin or failed remote produces an unchecked/unavailable
result, not “up to date.” Malformed higher-priority catalogs never silently change
the chosen trust source. No full plugin runtime compatibility is implied.

### 9. Acquisition efficiency and additional transports

**Deliver first.** Measure registry clones, Git lookups, repeated source acquisition
and Windows process overhead. Deduplicate work by source and immutable revision;
keep the current batched renderer. Audit effective Git protocols after configuration
rewriting, private-source diagnostics, bounded timeouts and LFS-backed selected assets.

**Acceptance.** Optimization preserves exact selected bytes and commit identity.
Caches cannot answer an explicit ref with an unversioned snapshot. Source host/ref
survive every path; an unavailable lookup is distinguishable from no change.
Supporting binary files and executable bits survive, and LFS pointers are not
silently presented as usable assets. Benchmark cold restore, warm no-change sync
and multi-skill imports before setting a measurable improvement target.

**Later transports.** Well-known HTTP catalogs and archives require a separate
proposal for digest verification, durable retrieval, size/time limits, extraction
containment and complete-bundle failure behavior. Do not couple the engine to a
hosted discovery/download service.

## Adapter candidates

Assessment date: September 5, 2026. “Existing” refers to current Intelligence code;
every other row is a candidate. Population figures are qualified publisher claims
or repository-interest proxies, not a common popularity ranking. Recheck evidence
before implementation. Official links for existing adapters are in
[README: Related links](README.md#related-links).

| Tool | Current position / adoption evidence | Proposed scope or decision |
|---|---|---|
| OpenCode | Existing `opencode` adapter | Maintain native agents, skill commands, shared instructions/skills. |
| Claude Code | Existing `claude` adapter | Maintain rules, agents and skills. |
| Codex | Existing `codex` adapter | Maintain native agents and shared instructions/skills. |
| Cursor | Existing `cursor` adapter | Maintain native rules, agents and skills; verify before changing shared paths. |
| GitHub Copilot | Existing `copilot` adapter | Maintain instructions, agents and skills; distinguish supported host surfaces. |
| Pi | Existing `pi` adapter | Maintain prompt templates, rule extension and shared skills. |
| Cline | **First queue.** Publisher reports [8M+ developers](https://cline.bot/). | Rules + skills; [native skills documentation](https://docs.cline.bot/customization/skills) does not establish shared `.agents/skills` loading. Reusable agent-file export needs separate evidence. |
| Antigravity | **First queue.** Google reports [2.4M+ weekly active users](https://blog.google/company-news/inside-google/message-ceo/alphabet-earnings-q2-2026/). | Rules, skills and custom-agent candidate; verify product version and permissions using [official docs](https://www.antigravity.google/docs/subagents). |
| Qoder | **First queue.** Publisher reports [6M+ builders](https://qoder.com/), product-wide. | Native rules/skills/agents candidate; validate CLI and IDE separately against [subagent docs](https://docs.qoder.com/cli/subagent). |
| OpenHands | **Next queue.** Publisher reports [9M+ OSS downloads](https://www.openhands.dev/about), not unique users. | Start with instructions/skills. Verify SDK/CLI agent loading and ACP limitations before fuller support; [current skills](https://docs.openhands.dev/overview/skills). |
| Kiro CLI | **Next queue.** AWS reported [250k+ preview developers](https://aws.amazon.com/startups/learn/power-your-startup-with-1-year-of-kiro-pro-plus-now-available-through-aws-startups), historical product-wide reach. | Steering, skills and custom agents; prove custom agents load declared resources. [Skills](https://kiro.dev/docs/skills/); current CLI-specific adoption remains uncertain. |
| OpenClaw | **Bounded evaluation.** About 389k [repository stars](https://github.com/openclaw/openclaw), an interest proxy. | Explicit workspace skills/instructions only initially; preserve persona/memory and avoid agent/auth/routing lifecycle. [Skills](https://docs.openclaw.ai/tools/skills). |
| Zencoder | **Shared-output pilot only if demand warrants it.** Current comparable adoption evidence was not established. | [Skills](https://docs.zencoder.ai/features/skills) use shared paths; `.zencoder/skills` is deprecated. Do not promise file-based custom-agent export. |
| Amp | **Watchlist.** Comparable current user evidence was not established. | [Shared skills](https://ampcode.com/docs/customize/skills) and instructions are plausible; dedicated agent export needs separate validation and demand. |
| CodeBuddy | **Watchlist.** No reliable current adoption metric established for Tencent's product. | Distinguish CLI/IDE and similarly named products; [CLI skills](https://www.codebuddy.ai/docs/cli/skills). |
| Command Code | **Watchlist.** Publisher reports [29k+ developers](https://commandcode.ai/developers). | Evaluate shared compatibility on demand; no dedicated adapter commitment under the widespread-adoption gate. |
| Neovate | **Watchlist.** About 1.6k [repository stars](https://github.com/neovateai/neovate-code); native loader evidence incomplete. | Defer until adoption and stable host format are established. |
| Roo Code | **No new adapter.** [Official repository](https://github.com/RooCodeInc/Roo-Code) is archived and reports extension shutdown on May 15, 2026. | Legacy import only if requested; historical popularity does not justify a new maintained target. |

## Deferred product work

- **Per-package metadata:** optional name/description/license metadata after import
  identity is settled. It improves display and provenance but must not block
  consuming conventional skills. Metadata version does not establish a Git revision.
- **Independently pinned engine content:** retain bundle-seeded, exact-pinned
  `@ainova-systems/sync` until independent cadence has demonstrated value. Separate
  repository boundaries only with independent pinning.
- **Hosted registry/governance:** private scopes, access control, audit and signing
  follow adoption evidence. Preserve the existing trust and source-identity contract.
- **Global installs and full plugin execution:** separate scope/ownership and runtime
  designs; not prerequisites for the project import roadmap.

## Completion criteria

Each milestone delivers its documented contract, regression scenarios and migration
or backout path in the same change. Run the profile's single verification command;
new gates belong in that runner. Host compatibility claims also require a recorded
smoke test against the stated product/version. Do not report fixture placement as
proof of host loading, or a successful render as verification of every package byte.
