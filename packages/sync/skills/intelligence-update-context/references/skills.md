# Author a skill

1. Name it `<domain>-<verb>-<noun>`. Reuse established verbs: `add` adds a member,
   `create` creates a container, `update` revises existing state, `run` executes
   an operation, and `review` analyzes it. Preserve a distinct, discoverable task.
2. Reuse an existing skill when its trigger and responsibility fit. For a new
   skill, find a matching agent across configured sources. Bind it when useful;
   if a new specialist is warranted, include that agent in the authoring proposal.
   A skill can stand alone when no specialist is needed.
3. Write concrete ordered steps from repository evidence or an observed workflow.
   Keep decisions, failure handling, and a final proof of completion. A step
   calling another skill names it and passes its inputs instead of copying it.
4. Bundle helpers, templates, and optional detail beside `SKILL.md`. Require each
   reference only for the condition that needs it. Resolve movable project paths
   and commands from the manifest or project profile. Test executable helpers.
5. Quote free-text YAML values, including descriptions and argument hints. Escape
   embedded quotes or use a compatible quoted scalar. Keep `name` equal to the
   directory name and make the description distinguish its trigger.

```yaml
---
name: <domain>-<verb>-<noun>
description: "What the skill does and when to use it"
argument-hint: "Expected arguments"
agent: <existing-agent>
---
```

Omit optional fields that do not apply. Add the skill to its matching agent's
`skills:` list when that agent is project-owned; propose an upstream change for
a package-owned agent instead of editing the installed copy. Verify bindings,
relative resource links, executable steps, and final success criteria. Apply the
1000-line skill limit and other budgets from the authoring conventions, then
return to the shared sync and verification steps.
