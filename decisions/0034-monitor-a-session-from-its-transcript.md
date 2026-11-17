# 0034 — Monitor a session from its transcript

Date: 2026-11-17
Status: accepted

## Context

`intelligence-learn-from-session` captures a lesson from the conversation it runs
in, so a lesson exists only when the session that hit the problem stops to
reflect on it. The sessions that hit the most problems are the ones least likely
to: they are busy finishing the task, and their context ends before the
reflection would start. A second session watching the first one sees every
failure as it happens, without spending the working session's context on it.

Claude Code and Codex both write a session's transcript to local JSONL files,
and Claude Code also keeps one registry file per running process naming its
session and working directory. Neither documents these files.

## Decision

1. `@ainova-systems/sync` ships `intelligence-monitor-session`. It finds the
   sessions working in the project, reads the transcript of the chosen one,
   writes each problem as a lesson record in a folder outside version control,
   and when the session ends hands that folder to `intelligence-learn-from-session`,
   whose existing "folder of lesson records" input turns the records into
   proposals. The monitor only reads; it never writes to the watched session.
2. Live sessions are the default; `--closed` analyses ended ones. Proposals wait
   for the owner, and `--autofix` is the owner accepting every layer proposal in
   advance. Neither changes `dev-deliver`'s accept and release gates, and neither
   files an upstream issue.
3. Accepted proposals are delivered through `dev-deliver` when the project has it.
   The monitor never creates a worktree: it tells `dev-deliver` when another live
   session still works in the checkout, and profile `worktree_policy` decides.
   This repository sets `never`, since parallel pull requests here collide on the
   pending changelog version and the next decision number.
4. The transcript reader is a bundled node helper,
   `skills/intelligence-monitor-session/scripts/sessions.mjs`, not Bash. Parsing
   tool transcripts whose lines hold escaped JSON is not something Bash and awk
   can do reliably, and node is present wherever the npm-installed CLI is. It
   reads only the shapes observed in Claude Code 2.1 and current Codex rollouts,
   skips what it does not recognise, and reports a tool it cannot read rather
   than guessing. Codex keeps no registry of running sessions, so 15 minutes
   without a write counts as the end.
5. `cli/tests/unit-monitor-session.mjs` drives the helper against fake tool homes
   and runs with the CLI suites where node is on PATH; without node it is
   reported as skipped.

## Consequences

- A change in either tool's transcript format degrades the monitor to fewer
  signals rather than wrong ones; the fixtures in the test are the record of the
  shapes it relies on.
- Records quote excerpts with obvious credentials redacted, but a transcript
  holds everything the session saw, so the records folder stays out of version
  control and the skill tells the agent to drop anything the redaction missed.
