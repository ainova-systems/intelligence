---
name: intelligence-learn-from-session
description: "Capture session lessons and workflows in project context"
argument-hint: "[lesson, or a folder of lesson records]"
---

# Learn from a session

Capture a durable preference, working pattern, recurring friction, or successful
workflow from a session in an established Intelligence project. This skill owns
identifying and generalizing the lesson; `intelligence-update-context` owns writing it.
A lesson is saved only through that skill, as a source every clone and tool reads,
never in a tool's own memory.

## Verify readiness

1. Locate `<manifest>`, `<content-dir>`, and `<module>`, then run
   `intelligence status --check`. Missing or inconsistent setup, an onboarding
   pending header, or unresolved preserved instructions routes to
   `/intelligence-learn-from-repository` for repair and migration. Stop session
   capture until onboarding is complete. A retained backup manifest or converted
   legacy config alone does not mean onboarding is incomplete.

## Analyze and propose

2. Identify the lesson from the conversation or explicit user input. For a
   workflow, list the actual steps performed, user decisions, branches, failure
   recovery, and verification. Retain the sequence that worked. Given a folder
   of lesson records, read every record against the current sources: report a
   record the sources already satisfy as applied and drop it, and carry the rest
   forward as lessons.
3. Generalize the evidence by removing instance-specific filenames, dates, and
   phrasing. Keep the reason needed to apply the lesson to the next task. Prefer
   a positive instruction such as "Default to one recommendation" for "Stop
   generating three options". Preserve safety prohibitions; confirm a translation
   if changing the negation changes meaning. Keep a negative example only when
   paired with its replacement and useful for recognizing the pattern.
4. Inspect configured sources for an existing owner. A preference or constraint
   belongs in a rule, path-specific context in a scoped rule, an observed
   repeatable procedure in a skill, and a persona or expertise boundary in an
   agent. Prefer extending an existing artifact over adding a sibling. A lesson
   about installed package content or the CLI itself is fixed upstream, never in
   the installed copy: draft an issue for the package's source repository, which
   `intelligence.lock` records, or for Intelligence. The draft holds only safe
   facts: versions from `intelligence version`, what was done, the expected and
   the actual behavior, and nothing confidential or specific to the project.
5. Present each proposal with its action (`CREATE`, `UPDATE`, `ARCHIVE`, or
   `UPSTREAM` for an issue draft), source path or repository, concrete draft, and
   one-line reason. This phase is read-only; only user-accepted lessons become
   persistent instructions. Reuse approval already given for the exact proposal.

## Apply and verify

6. Pass accepted proposals and their session evidence to
   `/intelligence-update-context`. It handles artifact-specific authoring,
   references, a single batch sync, and the final status check. An accepted
   `UPSTREAM` draft goes into the report; filing it is a separate request the
   person makes.
7. Compare the resulting source changes with the accepted lesson. For a workflow,
   verify that its decisions, working steps, recovery, and proof of completion
   remain executable without this conversation. Report the saved lesson, its
   owner, and verification, the records dropped as applied, and each upstream
   draft with its state; a session-specific transcript is not completion.
