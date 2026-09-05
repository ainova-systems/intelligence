---
name: dev-run-roadmap
description: "Implement one roadmap batch through a merge-ready PR"
---

# Run a roadmap batch

Select and deliver one coherent portion of the project's roadmap. An optional
argument identifies the roadmap, item or existing batch to resume. Otherwise pick
the next eligible work. The default endpoint is a merge-ready PR; continuing through
merge and release requires the owner's explicit approval for that PR and version.

## Establish the batch

1. Read the project profile, applicable rules, roadmap and referenced decisions.
   Resolve paths, branch policy, verification and release policy from the repository.
   Check the current branch, worktree, open PRs, recent merges and release state.
   Resume matching work instead of creating a duplicate branch or PR. Preserve
   unrelated changes; use an isolated checkout when necessary.

2. Compare roadmap intent with code, tests and merged work. Select the earliest
   useful, unblocked outcome whose prerequisites are satisfied. A large item may
   need a smaller slice; combine items only when they share one observable outcome,
   verification strategy and practical rollback. Leave independent work for later.
   Pending design choices are prerequisites to resolve, not accepted architecture.
   If no eligible outcome remains, report what is completed or blocked instead of
   inventing new roadmap work.

3. State the proposed behavior, selected roadmap items, acceptance criteria,
   exclusions and expected version impact. Ask concise clarifying questions when
   product intent, compatibility or a material tradeoff cannot be inferred. Continue
   independent work while waiting; do not guess a required decision or treat silence
   as approval. Proceed without an extra plan-approval round when scope is clear.

4. Create a short-lived branch from the current integration/default branch using
   the profile's naming and update strategy. Resume an existing matching branch
   without resetting its work. Do not implement on a protected branch.
   Record the batch in the repository's existing plan convention, or a concise
   section in the roadmap when none exists. Include scope, acceptance checklist and
   remaining portions of split items. Keep transient CI/review state in the PR.

## Implement and prepare the PR

5. Implement the selected behavior with its regression coverage. Use existing
   primitives and applicable implementation skills. If new evidence expands the
   work beyond one coherent PR, split the remaining work and update the plan; ask
   about changed product decisions before dependent implementation.

6. Update affected documentation, conventions and decisions with the implementation.
   Record only the delivered part in the roadmap and leave unfinished criteria
   open. Progress in the feature branch describes that branch; confirm its merge
   before a later run counts it as completed project work. Keep release/publication
   state grounded in Git and the release platform, not roadmap checkboxes.

7. Apply the repository's version/changelog policy to the complete pending release.
   Check publication before choosing a version, promote a pending version when the
   combined changes require it, and regenerate required lockstep artifacts through
   their existing workflow. Resolve any source-content sync through
   `intelligence-sync`. Preparing a version does not authorize publishing it.

8. Use `dev-run-tests` and `dev-review-changes`; address evidenced findings. Invoke
   `git-commit-push`, then `git-open-pr`, then `git-finalize-pr`. Delegate those
   procedures rather than duplicating their commands here. The PR must explain
   the final behavior, roadmap coverage, remaining work and actual verification.
   Do not end at an unverified draft or report a failing check as ready.

9. At readiness, report the PR URL, reviewed commit, verification outcome, version
   intent and remaining roadmap work. Retain the finalizer's outcome label. If the
   owner has not explicitly authorized the next action, request the missing approval
   for the concrete PR and any named release, then wait for that authorization.
   Roadmap approval, a previous batch's approval and invoking this skill do not
   authorize this PR's merge or publication.

## Continue after owner approval

10. Interpret approval for the concrete PR and release it names. A clear combined
    instruction to merge this PR and publish the stated version authorizes both;
    merge-only approval authorizes only merge. If the reviewed scope changes,
    explain the change and obtain approval for the changed scope. Reuse valid
    authorization across turns rather than asking again for the same action.

11. Revalidate the PR and invoke `git-merge-pr` for an approved merge. If the owner
    already merged it, confirm the platform's merged state and perform only the
    applicable base-sync/cleanup steps. Confirm the merge commit is on the target.
    Do not create an extra commit on the protected branch to update plan status.

12. For an explicitly approved release, invoke `git-create-release` using the
    repository's current release rules and the prepared version. Include all pending
    changes that the release will publish in the owner's reviewable release scope.
    Reuse already-merged preparation when the policy allows it; do not manufacture
    an empty release PR. Verify the tag, release object and publishing pipeline.
    On resume, inspect their existing state before any mutation; never republish
    or move a tag merely because the previous session ended before reporting it.

13. Report the achieved state: PR ready, merged, or released, with its evidence and
    exact next action. Use `dev-handoff` when continuation needs another session.
    One invocation delivers one batch; start the next roadmap batch only when asked.

## Completion

- **Ready:** acceptance criteria satisfied, required gates green on the reviewed
  commit, review threads handled and PR mergeable; owner approval pending.
- **Merged:** platform confirms merge, target contains it and local cleanup follows
  the profile; release remains pending unless explicitly authorized.
- **Released:** approved version/tag and release artifact verified, publishing
  pipeline successful, with links reported. A failure remains an explicit incomplete
  state, not permission to skip a gate or widen the approved action.
