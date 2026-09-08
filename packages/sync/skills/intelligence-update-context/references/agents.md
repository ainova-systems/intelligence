# Author an agent

1. Reuse an agent covering the domain when possible. Name a new one
   `<domain>-<role>` and determine its expertise from the source evidence.
2. Select tier and access: implementation normally uses `heavy` and `full`;
   review or validation uses `standard` and `readonly`; simple lookup uses
   `light` and `readonly`. Check the target's actual permission mapping when
   external read tools are required. If native read-only restrictions exclude
   those tools, use `full` only with a clear read-only boundary in the body.
3. Keep the body thin: Expertise, Boundaries, and Build & Verify. Carry its own
   completion criteria and limitations. Reference constraints by name instead
   of copying rules, and put reusable procedures in skills.
4. Find relevant existing skills across the configured sources and link them in
   `skills:`. Do not create a sibling skill or agent merely to fill a binding.

```yaml
---
name: <domain>-<role>
description: "When to use this agent"
tier: heavy
access: full
skills:
  - <existing-skill>
---
```

Quote free-text YAML strings and escape embedded quotes; malformed scalars can
prevent discovery. Verify every skill binding resolves, the tier and access use
the supported vocabulary, and the body defines a role rather than a checklist.
Apply the agent size and description limits from the authoring conventions,
then return to the shared sync and verification steps.
