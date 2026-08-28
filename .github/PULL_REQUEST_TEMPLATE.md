## Summary

<!-- What observable behavior or documentation changes, and why? -->

## Type of change

- [ ] CLI lifecycle or package behavior
- [ ] Sync engine or adapter
- [ ] Rule, agent, or skill content
- [ ] Documentation
- [ ] Refactor with no behavior change

## Public CLI check

- [ ] Uses only the established groups: `init`, `sync`, `update`, `package`, `adapter`, `status`, `registry`
- [ ] Keeps preview/apply behavior explicit for planned writes
- [ ] Covers automatic project alignment and CI refusal when project schema/content can change
- [ ] Keeps fresh-clone package restoration behind `intelligence sync`

## Verification

- [ ] `bash cli/tests/verify.sh` reports `verify ok` and skipped nothing this change needed
- [ ] `intelligence status --check` succeeds in the relevant fixture/project
- [ ] A second `intelligence sync` produces no unexpected diff
- [ ] Adapter changes were checked against the real tool format and preserve hand-authored sibling files
- [ ] User-facing docs and examples use the current public command groups

## Versioned artifacts

- [ ] `CHANGELOG.md` records the user-visible change; breaking items are verifiable post-conditions
- [ ] If `engine/VERSION` changed, every example's `schema_version` and exact `@ainova-systems/sync` pin changed with it
- [ ] No stable release is implied or published without owner approval

## Notes for reviewers

<!-- Edge cases, security boundaries, design tradeoffs, or related work. -->
