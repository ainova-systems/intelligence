---
paths:
  - "docs/**"
  - "decisions/**"
  - "README.md"
  - "CHANGELOG.md"
  - "CONTRIBUTING.md"
  - "ROADMAP.md"
description: "Documentation vocabulary, file naming and the shape of the changelog"
---

# Documentation and changelog

Write Intelligence paths and CLI commands. `INIT.md`, a vendored `scripts/update.sh`,
`packs:`, engine scripts inside a project and `intelligence/sync/...` are legacy
Intelligence Sync concepts; they belong only inside a narrowly scoped conversion or
archive explanation. CI's `repo-purity` job additionally refuses the `<umbrella>` and
`IS_UMBRELLA_REL` tokens in `engine/`, `packages/sync/`, `cli/`, `docs/`, `README.md`
and `AGENTS.md`.

Files inside any `docs/` directory use lowercase kebab-case, enforced by `repo-purity`
over `docs/*.md` and `packages/sync/references/*.md`. Standard root documents —
`README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `ROADMAP.md` — keep their conventional
names.

`ROADMAP.md` holds only work that is still open. A batch section is working state
for one in-flight PR, not a record of it: the same PR retires the section, folding
whatever the batch left unfinished back into the numbered item it came from. What
shipped is one line in `CHANGELOG.md`, its rationale a record in `decisions/`, and
its scope and backout plan the pull request's. Ticked checklists kept here turn the
roadmap into a second changelog that drifts from the first, and a numbered item then
keeps describing a problem the repository already solved.

`CHANGELOG.md` is compact: one line per change, minimal context, no rationale. The
rationale goes to `decisions/` as a numbered record with an explicit status. A
`### Breaking` subsection is a checklist of verifiable post-conditions consumed by the
upgrade meta-skill, so write each item as something a reader can check in a project,
not as a description of what changed.
