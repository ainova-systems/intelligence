---
name: intelligence-authoring
description: "Authoring discipline for the intelligence layer — rule vs skill vs agent, scoping, size"
paths:
  - "<umbrella>/**"
---

# Authoring the intelligence layer

Applies when writing or changing anything under `<umbrella>/`. The mechanics — frontmatter fields, tier and access vocabulary, routing per tool — live in `<module>/docs/CONVENTIONS.md`. This rule is the judgement that sits on top of them.

Everything in this layer is context the model pays for on every turn. The discipline below is what keeps it worth its price.

## Source of truth

Edit `<umbrella>/{rules,agents,skills}` and `<umbrella>/config.yaml`. Everything else is derived: `.claude/`, `.cursor/`, `.github/{instructions,agents,skills}/`, `.codex/`, `.agents/skills/`, `.pi/`, `.opencode/` and `AGENTS.md` are **generated output** — a hand edit there survives exactly until the next sync.

After any change: `bash <module>/scripts/sync.sh`. A change that was not synced does not exist for any tool.

## Pick the right artifact

| Type | Intent | How it loads |
|---|---|---|
| **Rule** | The model **respects** a constraint while doing other work | Automatically — always-on, or path-scoped via `paths:` |
| **Skill** | The model **performs** a defined procedure | Explicitly — `/skill-name` |
| **Agent** | The model **adopts** a persona | Explicitly — via the agent picker |

The mistakes that actually happen, in order of frequency:

- A **checklist** written into an agent body → a checklist is a *procedure*; it belongs in a **skill**. This one keeps happening because a checklist *feels* like expertise. It is not: it changes with the task, a role does not.
- A **convention** written into an agent body → it belongs in a **rule**, so every agent gets it, not just the one you happened to be editing.
- A **workflow** written into a rule body → it belongs in a **skill**. A rule is loaded always; a procedure should be invoked.
- **Expertise** written into a skill body → it belongs in an **agent**; the persona is reusable across skills.

## Rules

**Scope with `paths:`.** A rule without `paths:` is loaded into *every* session and inlined into `AGENTS.md` — the most expensive context real estate there is. Earn it. A rule that only matters when someone touches the frontend belongs scoped to the frontend.

**Lead with the positive default, then the invariant.** The model acts on the first instruction it reads, and it follows whatever is named — negation ("never do X") draws attention to X. Reserve absolute language (NEVER, MUST) for true must-nots: safety, security, output format. A judgement call written as a NEVER only teaches the model that NEVERs are negotiable.

**Derive from the code, not from prose that already exists.** Every REQUIRED and every invariant must be backed by something observed in the repository. Documentation is a claim, not evidence — read the file.

**Describe the repository, not a machine.** OS, shell, editor, local dev stack, personal tooling are environment facts; they belong in a personal, gitignored `CLAUDE.md`. A rule is committed and read by everyone.

**Explain the why.** A constraint with its reason survives refactors; a bare imperative gets worked around.

### Invariants

- **Never state behaviour of a tool or engine you have not verified in its documentation or source.** An unverified claim about tooling is worse than a gap: it silently reshapes every downstream decision, and nothing in the repository will contradict it.
- **Never write a current defect into a rule as if it were the design.** Known breakage belongs in one place that says so. Every other rule describes the project *as it is meant to work* — a workaround documented as procedure becomes permanent.
- **Never link between always-on rules.** They are inlined verbatim into `AGENTS.md`, and the path-scoped channels carry only scoped rules, so a relative link is dead in at least one output. Name the rule instead; it loads on its own.

## Agents

An agent is **thin**: who it is, where it stops, how it verifies. Nothing else.

- **Do not list rules for an agent to read.** They load on their own — Claude Code loads `.claude/rules/` into every custom subagent's startup context, and Cursor, Copilot, Codex, Pi and opencode receive always-on rules inlined in `AGENTS.md`. Pointing at a rule by name is fine; copying it is duplication that drifts.
- **Point at a rule, do not restate it.** Wanting to copy a rule into an agent means the rule is in the wrong place — move it.
- **Do carry** what is genuinely the agent's own: its boundaries ("if the app will not start, stop — do not hand-write the output"), its verification commands, its definition of done.

## Skills

A skill is a repeatable procedure someone invokes, and it ends in a verification. If there is nothing to verify, or it will only ever run once, it is not a skill — it is just work.

- **`<domain>-<verb>-<noun>`.** The domain prefix carries the weight: it clusters siblings and says which system the skill acts on. Take it from the set already in use.
- **`add-` creates exactly one artifact; `create-` orchestrates several `add-` skills** and repeats none of their content.
- **A skill is executed, so it must not hardcode what can move.** Paths, commands and project names belong in a rule the skill can read; a literal path baked into a procedure breaks the moment the layout moves. (Rules and agents are free to name paths — describing the repository is their job.)
- **`intelligence-` is reserved** for the engine's own meta-skills. Never use it for a project skill; the updater prunes what matches it.

## Keep it short

Ceilings, not quotas — an artifact that says everything it needs to is finished, not underweight.

| Type | Comfortable | Hard cap |
|---|---|---|
| Rule | ~300 lines | 500 |
| Agent | ~150 lines | 200 |
| `SKILL.md` | under 500 lines | 1000 |

Over budget means one of two things: the artifact is doing two jobs and should be split, or the detail belongs in `references/<topic>.md` with a pointer from the body.

`description` fields compete for one shared budget across the whole registry — a long one pushes another artifact out of reach. Four to eight words when the name is unambiguous; up to ~20, with a distinguishing trigger, only when siblings do something similar.

## Verifying a change to this layer

The per-artifact checks are a procedure, not a constraint to hold in mind while doing other work — so they live in the meta-skills, not here. Invoke the one that matches what you are doing: `intelligence-add-rule`, `intelligence-add-agent`, `intelligence-add-skill`, `intelligence-extract-skill`, `intelligence-review-skills`, `intelligence-learn-from-context`, `intelligence-sync`, `intelligence-update`, `intelligence-install-adapter`, `intelligence-uninstall-adapter`.

A change to this layer is done when `bash <module>/scripts/sync.sh` reports `IS_STATUS=ok` and the skill you invoked reports clean.
