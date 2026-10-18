# Intelligence sync status for Claude Code

`intelligence sync` renders this plugin into a project's
`.claude/skills/intelligence/` from the Intelligence engine's
`adapters/claude-plugin/` template when `targets.claude.plugin` is `true` in
`intelligence.yaml`. Change the template in the engine, never a rendered copy:
the next sync rewrites the copy, and setting the flag to `false` removes it.

It is a Claude Code plugin whose hooks module (`hooks/register.js`) checks
`intelligence sync --check` when a session starts and every five minutes,
shows the result in a line above the prompt while something needs attention,
and runs `intelligence sync` from a `Sync now` button there or the
`/intelligence sync` command. Its requirements and limits are defined in the
Intelligence CLI reference, `docs/cli.md`, under `intelligence sync`.
