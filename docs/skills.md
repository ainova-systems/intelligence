# Intelligence skills

The `@ainova-systems/sync` package ships seven skills. Slash commands are agent
workflows; ordinary `intelligence ...` commands are deterministic CLI operations.

| Skill | Use it when |
|---|---|
| `intelligence-update-context` | Create, revise, or remove rules, agents, and skills. |
| `intelligence-learn-from-session` | Save a session lesson or turn an observed workflow into a skill. |
| `intelligence-review-context` | Audit the intelligence layer and propose reductions that preserve behavior. |
| `intelligence-learn-from-repository` | Complete initial onboarding, migrate preserved instructions, or recover interrupted setup. |
| `intelligence-manage-adapters` | Enable, disable, or remove existing adapters and assess generated-output cleanup. |
| `intelligence-sync` | Render source content and interpret sync results or failures. |
| `intelligence-update` | Interpret CLI/package update plans and verify breaking post-conditions. |

Session learning identifies and generalizes evidence; context updating owns the
artifact-writing procedure. Review is read-only until changes are accepted, then
uses that same authoring procedure. Compaction retains its behavior ledger,
measurement, and evaluation requirements. Initial onboarding keeps its separate
backup migration and recovery checks.

For example, "remember the workflow we just used" belongs to
`intelligence-learn-from-session`; "add a rule for the API" belongs to
`intelligence-update-context`; and "reduce our overlapping skills" belongs to
`intelligence-review-context`.

## Migrating from the twelve-skill catalog

The removed names have no installed aliases. Update project skill invocations,
agent bindings, links, and any deliberate overrides before relying on the new
catalog. A renamed package skill no longer matches a same-named project override;
compare its content with the new owner before deciding whether to retain it.

| Previous skill | Replacement |
|---|---|
| `intelligence-add-rule` | `intelligence-update-context` with a rule request |
| `intelligence-add-agent` | `intelligence-update-context` with an agent request |
| `intelligence-add-skill` | `intelligence-update-context` with a skill request |
| `intelligence-learn-from-context` | `intelligence-learn-from-session` |
| `intelligence-extract-skill` | `intelligence-learn-from-session` with an observed workflow |
| `intelligence-review-skills` | `intelligence-review-context` |
| `intelligence-compact-context` | `intelligence-review-context` with a compaction request |
| `intelligence-install-adapter` | `intelligence-manage-adapters enable <name>` for an existing adapter |
| `intelligence-uninstall-adapter` | `intelligence-manage-adapters disable <name>` or `remove <name>` |

After project alignment and sync, verify the seven package skills and their
reference files are present in enabled outputs and obsolete generated names are
absent. Run `intelligence status --check`. Keep project-owned overrides only after
their new responsibility and references have been reviewed.

## Adapter development

Custom adapter support remains in the CLI and the public
[adapter guide](../packages/sync/references/adapters.md). The implementation
workflow lives in this repository's
[`dev-build-adapter`](../intelligence/skills/dev-build-adapter/SKILL.md) skill and
is excluded from the shipped package and npm payload. Contributors use it for
built-in changes and project-adapter fixtures. Consumers can follow the public
guide without a separate development package.
