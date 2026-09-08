# Author a rule

1. Reuse an existing rule covering the scope. A new filename matches its domain,
   such as `backend.md`, a named component, or `context.md` for global context.
2. Choose `paths:` when the guidance applies to particular files. Omit it only
   for intentionally project-wide guidance; a missing argument alone is not
   evidence that every task needs the rule.
3. Extract required patterns, invariants, architecture, relevant build commands,
   and examples from the evidence. State judgment calls as positive defaults;
   reserve absolute constraints for safety, security, and output contracts.
   Pair a useful anti-pattern with its positive replacement.
4. Write only the sections the evidence needs: Required patterns, Invariants,
   Architecture, Build and test, Examples, and Patterns to recognize and replace.
   Keep reasons that guide judgment and reference real examples. An accepted
   user preference is identified as a preference, not a claim about existing code.

For a scoped rule:

```yaml
---
description: "Conventions for the named component"
paths:
  - "<scope-glob>"
---
```

Verify that the globs match the intended files, each constraint has evidence,
and procedures have a skill owner. Name always-on rules rather than linking to
their source paths: their bodies are inlined in shared output. Apply the rule
size and description limits from the authoring conventions, then return to the
shared sync and verification steps.
