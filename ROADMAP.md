# Roadmap

Build, version and distribute project rules, agents and skills across AI tools.
Make existing skill ecosystems easy to consume while preserving explicit source
trust, reproducible package state and deterministic native rendering.

Reviewed September 7, 2026. These are planned changes, not current CLI features
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

Keep the public groups `init`, `sync`, `update`, `upgrade`, `package`, `adapter`,
`status` and `registry`. Put new content operations under `package`, catalog lookup
under `registry`, and target support under `adapter`. Exact new flags and schemas are
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

### 1. Exact restore and integrity boundaries

**Problem.** Exact locked acquisition and lock-metadata validation are in place, so
what remains is everything they deliberately did not cover. Installed package bytes
are not authenticated against their locked source by sync's local change detection,
manifest intent is validated only where the lock forced it, and
rollback still spans one operation at a time rather than the package store, manifest,
lock and rendered output together. Git and authentication failures reach the user as
raw transport errors.

**Deliver.** Define and apply an integrity check over installed package content.
Complete manifest-intent validation beside the lock validation already shipped.
Specify and stage the state a package operation covers before calling it
transactional, keeping the bundle-seeded offline default and the explicit
development-build exception. Improve bounded Git failures and authentication
diagnostics without extracting credentials.

**Acceptance.** A tampered store is detected by the chosen integrity check. A late
fetch or render failure preserves the prior state covered by the operation's
documented transaction. An unreachable or unauthenticated remote reports what to fix
without echoing credentials. The delivered exact-commit and lock-validation refusals
keep their tests; they are replaced only by stronger assertions.

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
and GitHub stars are not interchangeable. Antigravity is delivered; continue with
Cline and Qoder, then evaluate OpenHands and Kiro. Implement one validated target
at a time. The candidate assessment below is not a commitment to add every listed tool.

**Acceptance.** A host smoke test proves each advertised capability: instructions
load once, a skill can read its resources, scoped rules activate only as intended,
and exported agents respect the documented model/tool mapping, including the
three access values of [decision 0026](decisions/0026-one-access-vocabulary-across-tools.md).
Unsupported channels
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

## Known defects

Found and still open. Each is independent of the delivery order above.

### 10. A sync-lock test that races its own timing

**Problem.** The `e2e-sync-lock` case "each ownerless moment gets its own grace,
however long the wait" drives the lock with fixed sleeps: each ownerless window
lasts two seconds, against the three seconds `sync_lock_acquire` grants an
ownerless lock, counted in whole `SECONDS` and polled once a second. On a loaded
host the window plus scheduling delay reads as three, the command refuses with
"another intelligence sync is starting", and the case fails; a rerun passes.

**Deliver.** Drive the case from events the test controls, or size its windows
from the grace with a margin the one-second measurement cannot consume, without
lengthening the suite noticeably.

**Acceptance.** The case still fails when a later ownerless moment inherits the
first one's start, and passes repeatedly while other suites run alongside it.

### 11. Byte 0x1c renders as `<`

**Problem.** The token escape holds `\<token>` on byte 0x1c while the other
tokens expand, and `fin_line` then turns every 0x1c in the line into `<`.
`token_keep_var` uses the same placeholder for the YAML, TOML and Pi string
escapers. A 0x1c already present in a source line or in a layout token value
therefore renders as `<` instead of itself.

**Deliver.** Restore only the placeholders the escape created, keeping
`fin_line`'s path for lines without `<` free of added work.

**Acceptance.** A source line and a token value holding 0x1c render it unchanged
in plain lines and in quoted YAML, TOML and Pi values; `\<module>` still renders
as `<module>`; output for sources without 0x1c stays byte-identical.

### 12. A failed dist-tag read moves `next` over a newer preview

**Problem.** `npm/align-dist-tags.sh` reads the current tag with
`npm view ... 2>/dev/null || true`, so a read that fails - a registry error, the
network, authentication - looks exactly like a tag that is unset. On a stable
release the script then points `next` at the stable version even when `next`
holds a newer preview, the one case it exists to leave alone.

**Deliver.** Tell an unset tag from a failed read, and fail the step on a failed
one before any tag moves.

**Acceptance.** With the read failing, the step fails and both tags stay as they
were; with `next` unset, a stable release still points it at that version; with a
newer preview on `next`, a stable release still leaves it alone.

### 13. The CLI and the engine disagree on a target's default output

**Problem.** For a target whose manifest entry has no `output:`, the engine
renders into `.<adapter>` (`engine/sync.sh`), while `default_target_output` in
`cli/lib/cli-common.sh` assumes `.github` for Copilot and `AGENTS.md` for
`agents`. `adapter list`, the Git-policy writer and the contract checks of
`status --check` read the CLI's value, so for such a manifest they describe paths
the engine never writes. `init` always writes `output:`, so only a hand-written
manifest meets it.

**Deliver.** One answer for the default output of each target, read by the CLI
and the engine alike.

**Acceptance.** For a manifest whose targets carry no `output:`, `adapter list`,
`status --check` and the ignore entries name the paths a sync writes; a manifest
with explicit outputs behaves as before.

### 14. The OpenCode `frontier` default names an older Fable

**Problem.** `get_model_default_var` maps `opencode:frontier` to
`anthropic/claude-fable-5-1`, while Claude Code's `fable` alias, the Claude Code
`frontier` default, resolves to Fable 5.2 ([model configuration](https://code.claude.com/docs/en/model-config),
checked 2026-11-10). One tier therefore renders two different models across the
two Claude-backed targets.

**Deliver.** Move the OpenCode default to the models.dev catalog ID of the current
Fable, with the tier table in `packages/sync/references/conventions.md` and the
expected matrix in `cli/tests/unit-engine.sh`, and a `### Changed` line saying how
to keep the earlier model.

**Acceptance.** A `frontier` agent renders the current Fable ID in OpenCode; a
`models.opencode.frontier` pin still renders as written, and the drift report
names it.

### 15. Agent frontmatter edge cases in the Claude Code and Cursor transforms

**Problem.** Two cases the agent transforms read differently from YAML. A key the
transform drops (`tier`, `access`, `model`, a `tools` that `access:` replaces,
`targets`) takes its block list along only when the list items are indented, so
a valid `tools:` followed by an unindented `- Read` leaves the `- Read` lines in
the rendered frontmatter. And an agent without frontmatter gets `model:`,
`tools:` or `readonly:` written at its second `---` line, and the wrapped forms
(`fence` mode) keep whatever follows a later `---` pair; neither tool loads an
agent without frontmatter, so that case shows only in the rendered file.

**Deliver.** Treat an unindented `- ` item as a continuation of a dropped block
list, and write the derived keys only into frontmatter that starts on line 1.

**Acceptance.** An agent with an unindented block list under a dropped key
renders without those items; an agent without frontmatter renders its body
unchanged; every other agent renders byte-identical.

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
| Antigravity | Existing `antigravity` adapter | Maintain native rules, skills and agents in `.agents/`. |
| Cline | **First queue.** Publisher reports [8M+ developers](https://cline.bot/). | Rules + skills; [native skills documentation](https://docs.cline.bot/customization/skills) does not establish shared `.agents/skills` loading. Reusable agent-file export needs separate evidence. |
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
- **The breaking half of [decision 0026](decisions/0026-one-access-vocabulary-across-tools.md):**
  `runner` and the warning about an `access:` value outside the vocabulary shipped
  in 0.26.0, with `readonly` rendered as before. What remains changes `readonly` in
  two tools: Claude Code drops `Bash` (`tools: Read, Grep, Glob`), and Codex drops
  the `sandbox_mode` line it ignores and gets `features.shell_tool = false`. It waits
  until the packages that ship `readonly` agents which run commands have moved
  them to `runner`, in a package release that requires CLI 0.26.0 or later, and
  then ships in a release of its own whose `### Breaking` item is "no agent with
  `access: readonly` needs to run commands". Its tests fail on the 0.26.0 rendering.

## Completion criteria

Each milestone delivers its documented contract, regression scenarios and migration
or backout path in the same change. Run the profile's single verification command;
new gates belong in that runner. Host compatibility claims also require a recorded
smoke test against the stated product/version. Do not report fixture placement as
proof of host loading, or a successful render as verification of every package byte.
