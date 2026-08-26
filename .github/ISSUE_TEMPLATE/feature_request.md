---
name: Feature request
about: Suggest a package, adapter, lifecycle, or authoring improvement
title: "[feature] "
labels: enhancement
---

## Problem

<!-- What concrete workflow or project state is difficult today? -->

## Proposed outcome

<!-- Describe what the user should be able to do and the observable result. -->

## Public surface

<!-- Which existing group owns this: init, sync, update, package, adapter, status, or registry? Avoid proposing a new top-level command when an existing group fits. -->

## Alternatives considered

<!-- What else did you try or consider, and why was it insufficient? -->

## Scope check

- [ ] Keeps project lifecycle behind universal `init` and automatic project preflight
- [ ] Keeps package operations under `intelligence package`
- [ ] Keeps adapter operations under `intelligence adapter`
- [ ] Keeps tool-specific behavior in adapters and common behavior in the CLI/engine
- [ ] Preserves `intelligence.yaml` and `intelligence.lock` reproducibility contracts
