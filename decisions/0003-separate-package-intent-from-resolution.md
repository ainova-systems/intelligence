# 0003 — Separate package intent from resolved source state

Date: 2026-08-26
Status: accepted

## Context

Early v2 RC manifests used two package shapes. Registry packages stored only a
version range, while direct and built-in packages also stored repository URL
and path. This exposed resolver mechanics to users and duplicated fields that
were already required in `intelligence.lock`.

## Decision

1. A manifest package entry stores only requested intent: `version` or `ref`.
2. The lock stores the resolved URL/path, tag/ref and commit SHA for every package.
3. `@ainova-systems/sync` resolves from the CLI's built-in descriptor during init/alignment.
4. Named packages resolve through trusted registries only when added.
5. Updates use the source already committed in the lock. Re-adding is the explicit source-change operation.
6. v2 lifecycle alignment removes RC-era manifest URL/path fields automatically.

## Consequences

- Built-in, registry and direct Git packages have one manifest shape.
- Fresh-clone restoration remains registry-free and reproducible from the lock.
- A registry re-point cannot silently change an installed package's source.
- Source review happens in the committed lock diff created by `package add`.

## Rejected

- **Keep URL/path in direct and built-in manifest entries.** This preserves two user-facing package shapes and duplicates the lock.
- **Re-resolve the registry on every update.** A registry re-point would change source without an explicit package acquisition decision.
