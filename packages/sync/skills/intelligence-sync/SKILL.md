---
name: intelligence-sync
description: "Sync intelligence to enabled IDE targets"
agent: intelligence-operator
context: fork
---

Run the sync engine to transform rules, agents, and skills from the intelligence sources to each enabled IDE's native format.

> **The sync never migrates.** It is a pure synchronizer: across an un-applied schema it **fails closed** with `IS_STATUS=needs-update` (exit 6) and changes nothing. Bringing the project up to the engine is the update flow's job — in a vendored setup tell your agent *"Update intelligence-sync"* (the `intelligence-update` skill); in a CLI setup (root `intelligence.yaml`) run `npm i -g @ainova-systems/intelligence@latest` and `intelligence upgrade` — then re-run sync.

## Steps

1. Run `<sync-cmd>`.
2. Review the output — verify rule, agent, and skill counts per target, and that it ends with `IS_STATUS=ok`.
3. If warnings about unsynced directories appear, add the missing paths under `sources:` in `<manifest>`.
