# Preserve behavior while compacting

Read [principles.md](principles.md) when preparing a structural or size reduction.
The review skill supplies the source inventory, audit findings, and baseline counts.

## Behavior ledger

Before drafting, record each candidate's behavior, constraint, procedure, or
expertise; its authoritative owner; when it loads; the reason or example needed
to apply it; and the repository evidence or documentation supporting it. Similar
words with different scope, priority, or failure behavior are not duplicates.

## Draft in this order

1. Replace instructions with deterministic commands or gates the repository
   already enforces where they cover the same behavior.
2. Delete generic knowledge and directly readable facts unless their non-obvious
   interpretation is the instruction.
3. Keep one owner of duplicated guidance. Call skills by name without repeating
   their procedure; let agents bind skills without copying their steps.
4. Scope narrow rules with `paths:`. Move procedures to skills, constraints to
   rules, and reusable expertise to agents.
5. Move optional detail to skill-local references with exact read conditions.
   An unconditional import spends the same context. A plain link is navigation,
   not guaranteed loading; keep critical constraints in the executable core.
   Large always-on rules need subtraction, scoping, or a gate, not a reference index.
6. Tighten prose only after structural reductions. Keep complete sentences,
   ordinary vocabulary, reasons that guide judgment, and one clarifying example.

Preserve triggers, boundaries, ordering, failure behavior, verification, and output
contracts. Keep descriptions distinguishable. Do not teach terse, abbreviated,
clipped, or vague responses, introduce dense acronyms or unexplained labels, or
remove grammar to reduce bytes. Response style changes require their own explicit
product requirement.

Proposals use `DELETE`, `MERGE`, `SCOPE`, `MOVE`, `REFERENCE`, or `REWRITE` and name
the owner, semantic contract, estimated savings, and any changed behavior or load
timing. Keep unapproved passages byte-for-byte; the review skill routes only
accepted proposals to the shared authoring procedure.

## Verify the accepted result

1. Compare the ledger with the diff. Each original behavior exists once in its
   authoritative owner, was deliberately removed with approval, or is enforced by
   the named deterministic mechanism. Check for dead links, unconditional reference
   loads, conflicting instructions, and unintended scope expansion.
2. After the authoring skill's successful sync and `intelligence status --check`,
   compare source line and byte counts and rendered `agents-md` bytes with the
   baseline. Reuse its `CONTEXT:` output; do not run a duplicate sync. Report bytes
   and percentages for always-on and on-demand context separately. Label estimates
   or unavailable baselines rather than reporting them as measured savings.
3. When behavioral evaluation is available, exercise three prompts: a direct case
   governed by the changed instruction, an adjacent judgment needing its reason,
   and an ordinary explanation that reveals clipped language. Report explicitly
   when this evaluation is unavailable: fewer bytes prove size, not quality.
4. Report artifacts changed, behavior checks, measurements, and remaining owner
   decisions. Return these results to the review skill's final report.
