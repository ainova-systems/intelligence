# Intelligence sync status for Claude Code

`intelligence sync` renders this plugin into a project's
`.claude/skills/intelligence/` from the Intelligence engine's
`adapters/claude-plugin/` template when `targets.claude.plugin` is `true` in
`intelligence.yaml`. Change the template in the engine, never a rendered copy:
the next sync rewrites the copy, and setting the flag to `false` removes it.

It is a Claude Code plugin whose hooks module (`hooks/register.js`) checks
`intelligence sync --check` when a session starts and every five minutes,
shows the result in the status line under the prompt, and runs
`intelligence sync` from a `Sync now` button above the prompt or the
`/intelligence sync` command. It needs the `intelligence` CLI on `PATH` and
Claude Code 2.1.287 or later (earlier versions load it only with
`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`).
