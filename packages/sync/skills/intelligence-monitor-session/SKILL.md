---
name: intelligence-monitor-session
description: "Watch another session in this project and turn the problems it hits into intelligence-layer fixes"
argument-hint: "[session-id] [--closed [count]] [--autofix]"
---

# Monitor a session

Watch another agent session working in this project, keep a record of every
problem it hits, and once it ends turn those records into changes to the rules,
skills and agents that would have prevented them. This skill owns finding the
session, reading its transcript and recording the evidence;
`intelligence-learn-from-session` owns turning a record into a proposal, and
`intelligence-update-context` owns writing it.

The helper is `scripts/sessions.mjs` in this skill's directory, run with `node`
18 or later; its header lists the commands and exit codes. It reads Claude Code
and Codex transcripts. A session in any other tool leaves nothing it can read:
say so and stop rather than guess from the working tree.

Arguments:

- none - live sessions only, watched until they end;
- `<session-id>` - that session, live or closed;
- `--closed [count]` - ended sessions as well, newest first (default 5), each
  analysed once instead of watched;
- `--autofix` - the owner accepts in advance every layer proposal this run
  makes, so wrap-up goes straight to delivery. Without it, wrap-up waits for the
  owner to accept proposals.

## Find the session

1. Run `intelligence status --check`. A project that is not ready routes to
   `/intelligence-learn-from-repository`, exactly as `intelligence-learn-from-session`
   would at wrap-up, so stop now rather than after watching for an hour.
2. Collect the roots: the repository root and every path
   `git worktree list --porcelain` reports, so a session in a linked worktree
   counts as this project. Run `node <helper> list --root <root>` with one
   `--root` per path, adding `--closed --limit <count>` for closed sessions. The
   listing leaves out the Claude Code session running this skill; under another
   tool pass `--exclude <own session id>` when it is known.
3. Choose. A requested id must appear in the listing. Exactly one live session
   is the one to watch; several are the owner's choice - list tool, state and
   last write, and ask once. None live: report that, name `--closed`, and stop.
   With `--closed`, every listed session is analysed.

## Keep the records

4. Create a records folder outside version control, named `monitor-<session-id>`:
   an in-repository scratch directory that `git check-ignore -q` confirms is
   ignored, else the OS temp directory. Print its full path.
5. Write one Markdown file per problem, `<nn>-<slug>.md`, readable without the
   transcript: what happened, with timestamps and the few signal lines that show
   it; the skill, rule or agent in play (the helper's `skill=` tag); the category;
   and the suspected cause in the layer. Quote excerpts, never a transcript, and
   drop any credential the helper's redaction missed. A signal that repeats a
   recorded problem updates that record's count and evidence instead of adding a
   sibling. The folder is the "folder of lesson records" that
   `intelligence-learn-from-session` accepts, so it needs nothing else at wrap-up.

## Watch

6. Read from the start with `node <helper> read <transcript>` and keep the final
   `CURSOR=` value. Every other line is `KIND<TAB>time<TAB>detail`, KIND being
   `ERROR`, `DENIED`, `HOOK`, `APIERROR`, `INTERRUPT`, `COMPACT`, `SYSTEM`,
   `SKILL` or `USER`.
7. Judge patterns, not lines. A problem belongs in a record when the layer could
   have prevented it:
   - the same failure retried with small variations - a missing step, a wrong
     command, or an unstated precondition in a skill or rule;
   - a denial, an interrupt, or the user correcting the agent - an instruction
     the layer lacks or states wrongly;
   - a gate or hook refusing work - a skill that skips or misorders its gates;
   - a skill step failing against the repository - a skill that drifted from it;
   - compaction in the middle of a procedure - an artifact too large for its job.

   A slip the agent fixed on its own, or a failure in the code the task is
   changing, is not a layer problem. Classify each record as `layer` (a project
   rule, skill or agent), `package` (installed package content or the
   Intelligence CLI, fixed upstream), `project` (a defect in the project's own
   code, recorded where the project records defects) or `tool` (the agent tool
   itself).
8. While the session is live, run
   `node <helper> wait <tool> <id> <transcript> --from <cursor> --timeout <seconds>`
   in the foreground, with a timeout under the tool's command limit. Exit 0:
   read from the cursor and return to step 7. Exit 4: wait again. Exit 3: the
   session ended - wrap up. Exit 2: the helper refused; report its message and
   stop. Codex keeps no registry of running sessions, so the helper treats 15
   minutes without a write as the end (`--quiet <seconds>` changes it).

   The monitor only reads. It never writes to the watched session, its working
   tree, its branch or its pull request.

## Wrap up

9. Read the final delta and complete the records. Pass the records folder to
   `/intelligence-learn-from-session` for its analysis and proposal steps: it
   drops each record the sources already satisfy and turns the rest into
   proposals and upstream drafts.
10. Settle acceptance. Without `--autofix`, present the proposals and wait for
    the owner; only what they accept continues, and nothing accepted ends the run
    at the report. With `--autofix`, every `layer` proposal is accepted. Neither
    files an upstream draft, and `project` and `tool` records stay in the report.
11. Deliver through `/dev-deliver` when it is installed. The task is applying
    the accepted proposals from the records folder through
    `intelligence-learn-from-session`'s apply step. Each acceptance criterion is
    a record's scenario and the behaviour the changed artifact now produces. When
    another live session still works in this checkout, say the task runs in
    parallel with it. Its profile `worktree_policy` then decides whether the
    task gets its own worktree; the monitor never creates one. `--autofix` stops
    at the proposals: the accept and release gates of `dev-deliver` stay the
    owner's. Without `dev-deliver`, stop at the accepted proposals and the
    records folder, and say which skill would have delivered them.

## Verify

- Every record ends with exactly one outcome in the report: delivered (the pull
  request), already satisfied, declined by the owner, upstream draft, project
  defect or tool issue.
- `git status` of the watched session's checkout reads as it did before this run
  touched it, apart from the session's own work.
- With `--autofix`, the report names the pull request `dev-deliver` opened or
  the gate where it stopped.
