# 0026 – One access vocabulary across tools

Date: 2026-11-07
Status: accepted, implemented in part in 0.26.0 — `runner` renders in every adapter as point 2 states, and an `access:` value outside the three warns and renders as `full`; `readonly` keeps its earlier rendering in Claude Code and Codex until point 3 and the Codex `readonly` row ship in a release of their own

The owner accepted this record on 2026-11-07 as the lowest-priority work: it does
not ship in 0.25.0, and its breaking change to `readonly` waits for a release of
its own.

## Context

`access:` has two values, and `readonly` folds two limits into one: no edits and
no commands. Each adapter renders it as the closest native restriction, and the
renderings disagree on commands:

| Adapter | `readonly` renders as | Commands |
|---|---|---|
| `claude` | `tools: Read, Grep, Glob, Bash`, `disallowedTools: Write, Edit` | run |
| `cursor` | `readonly: true` | only those that change no state, per Cursor |
| `copilot` | `tools: ["read", "search"]` | none |
| `codex` | `sandbox_mode = "read-only"` | whatever the parent session's sandbox allows, because Codex ignores `sandbox_mode` in a custom agent file |
| `opencode` | `permission:` with `edit: deny` and `bash: deny` | none |
| `antigravity` | `tools:` with `view_file` and `grep_search` | none |
| `pi` | an instruction in the prompt template | not enforced |

An agent that must run checks without editing, such as a verifier, has no value
that works everywhere. Under `readonly` it runs its checks in Claude Code and
cannot run them in Copilot; under `full` it may edit in every tool.

## Decision

1. `access:` takes three values. `readonly` reads and searches, with no edits and
   no commands. `runner` reads, searches and runs commands, with no edit tools; a
   command can still write a file, so for commands the boundary is the agent's
   prose and the tool's own sandbox. `full` is unchanged.
2. The adapters map them as follows. A row lands only with its vendor citation in
   the adapter's header and a test that asserts the rendered frontmatter.

   | Adapter | `readonly` | `runner` | Checked 2026-11-07 |
   |---|---|---|---|
   | `claude` | `tools: Read, Grep, Glob` | today's `readonly`: `tools: Read, Grep, Glob, Bash`, `disallowedTools: Write, Edit` | Verified: `tools` is an allowlist and `disallowedTools` a denylist ([subagents](https://code.claude.com/docs/en/sub-agents#restrict-which-tools-a-subagent-can-use)) |
   | `copilot` | unchanged | `tools: ["read", "search", "execute"]` | Verified for the `read`, `search` and `execute` aliases in [custom agents configuration](https://docs.github.com/en/copilot/reference/custom-agents-configuration); not checked for VS Code |
   | `cursor` | unchanged | `readonly: true` | Partly: [subagents](https://cursor.com/docs/subagents) say `readonly` blocks edits and state-changing shell commands and offer no other access field. "State-changing" is not defined, so whether a test run is allowed is not verified |
   | `codex` | `features.shell_tool = false`, plus the no-edit instruction | the no-edit instruction; drop `sandbox_mode` from both | Verified that a custom agent file can turn off `features.shell_tool` and cannot set `sandbox_mode` ([subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)). No documented key removes the edit tool, so edits are stopped by instruction only |
   | `opencode` | edit and shell denied | edit denied, shell allowed | The V2 [agents docs](https://opencode.ai/docs/agents) define `permissions` rules with `edit` and `shell` actions and list the top-level `permission` field the adapter writes as legacy. Whether V2 still applies the legacy field is not verified |
   | `antigravity` | unchanged | adds `run_command` | The tool names are verified in the `tools` row of [subagents](https://antigravity.google/docs/subagents); that a listed set excludes every other tool is not stated |
   | `pi` | unchanged | an instruction that allows commands and forbids edits | Pi's [prompt templates](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/prompt-templates.md) take only `description` and `argument-hint`, so both stay prose |

3. In Claude Code `readonly` loses `Bash`. An agent that relied on it moves to
   `runner`, and the release that ships this carries it as a `### Breaking` item.

## Consequences

- A verifier declares `runner` and can run its checks in Claude Code, Copilot,
  Codex, OpenCode and Antigravity.
- A `readonly` reviewer stops running commands in Claude Code, which matches what
  it already gets in Copilot, OpenCode and Antigravity.
- Codex enforces the command limit for the first time; its edit limit is an
  instruction.
- The OpenCode rows wait on a check of the legacy `permission` field, and moving
  to V2 `permissions` may be its own change.
- The access table in the authoring conventions is rewritten from this record
  when it lands.

## Rejected

- **Widening `readonly` to allow commands everywhere.** Review agents in Copilot,
  OpenCode and Antigravity would gain shell access with no change in their source.
- **Tool-specific permission syntax in source agents.** The conventions keep it
  in adapters, and a source would then be valid for one tool only.
- **Relying on the Codex sandbox from the agent file.** Codex documents that the
  file cannot set it.
