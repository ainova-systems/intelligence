---
description: Repository configuration the dev- and git- pack rules and skills resolve before auto-detecting
---

# Project Profile

Values verified against `.github/workflows/`, `CONTRIBUTING.md`, `npm/package.json`,
`engine/VERSION` and the commit history. Skills read this first and only
auto-detect what is absent.

## Branching

- default_branch: main
- integration_branch: none
- branch_prefixes: feature/, fix/, ci/
- update_strategy: merge
- protected_branches: main

## Commits

- commit_style: pack-default
- reference_ids: none
- artifact_language: english

## Verification

- typecheck: none
- lint: bash cli/tests/verify.sh lint
- test: bash cli/tests/verify.sh tests
- verify: bash cli/tests/verify.sh
- coverage_gate: none

## Workspace

- handoff_dir: auto

## Pull requests

- platform: github
- cli: gh
- pr_target: auto
- merge_method: squash
- auto_open_pr: true
- pr_template: auto
- pr_risk_size: off
- pr_risk_globs: none
- delete_local_branch: true
- delete_remote_branch: false
- post_merge: none

## Releases

- release_flow: tag-on-default
- changelog: assembled
- changelog_pending: exact-version
- release_detection: published-github-release
- release_cut: release-pr
- release_artifact: github-release
- release_notes: changelog-section
- tagger: maintainer
- version_source: engine/VERSION
- tag_format: vX.Y.Z

## Documentation

- specs_dir: none
- features_dir: none
- rules_dir: none
- decisions_dir: decisions
- adr_naming: numbered
- execution_mode: supervised

## Tracker

- tracker: github
- tracker_cli: gh
- tracker_item_ref: #123
