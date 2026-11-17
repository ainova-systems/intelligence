// Drives the intelligence-monitor-session helper against fake Claude Code and
// Codex homes: which sessions it lists for a project, which signals it reads
// out of a transcript, how its cursor resumes, and when `wait` returns.
// verify.sh runs it with the CLI suites wherever node is on PATH.
//
//   node cli/tests/unit-monitor-session.mjs [repo-root]
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, appendFileSync, rmSync, utimesSync } from 'node:fs'
import zlib from 'node:zlib'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { spawn, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const root = process.argv[2] || fileURLToPath(new URL('../..', import.meta.url))
const helper = join(root, 'packages/sync/skills/intelligence-monitor-session/scripts/sessions.mjs')

const home = mkdtempSync(join(tmpdir(), 'monitor-session-'))
const claude = join(home, 'claude')
const codex = join(home, 'codex')
const project = join(home, 'work', 'app')
const other = join(home, 'work', 'other')
const env = { ...process.env, CLAUDE_CONFIG_DIR: claude, CODEX_HOME: codex, CLAUDE_CODE_SESSION_ID: 'self', SESSIONS_POLL_MS: '50' }

function run(...argv) {
  const r = spawnSync(process.execPath, [helper, ...argv], { env, encoding: 'utf8' })
  return { code: r.status, out: r.stdout, err: r.stderr }
}

function runAsync(...argv) {
  const child = spawn(process.execPath, [helper, ...argv], { env })
  return new Promise((resolve) => child.on('exit', (code) => resolve(code)))
}

const jsonl = (...entries) => entries.map((e) => JSON.stringify(e)).join('\n') + '\n'
const rows = (out) => out.trim().split('\n').filter(Boolean).map((l) => l.split('\t'))

// Claude Code: a live registry entry per running process, a transcript per
// session in a directory named after its cwd with every other character a '-'.
const transcripts = join(claude, 'projects', project.replace(/[^a-zA-Z0-9]/g, '-'))
mkdirSync(join(claude, 'sessions'), { recursive: true })
mkdirSync(transcripts, { recursive: true })
mkdirSync(join(claude, 'projects', other.replace(/[^a-zA-Z0-9]/g, '-')), { recursive: true })
const live = join(transcripts, 'live-1.jsonl')
const closed = join(transcripts, 'old-1.jsonl')
writeFileSync(join(claude, 'sessions', `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: 'live-1', cwd: join(project, 'sub'), status: 'busy' }))
writeFileSync(join(claude, 'sessions', '1.json'), JSON.stringify({ pid: 2147483646, sessionId: 'dead-1', cwd: project, status: 'idle' }))
writeFileSync(join(claude, 'sessions', 'self.json'), JSON.stringify({ pid: process.pid, sessionId: 'self', cwd: project, status: 'busy' }))
writeFileSync(join(transcripts, 'self.jsonl'), jsonl({ type: 'user', cwd: project, message: { content: 'hi' } }))
writeFileSync(join(claude, 'projects', other.replace(/[^a-zA-Z0-9]/g, '-'), 'live-2.jsonl'), jsonl({ type: 'user', cwd: other }))
writeFileSync(join(claude, 'sessions', '2.json'), JSON.stringify({ pid: process.pid, sessionId: 'live-2', cwd: other, status: 'busy' }))
writeFileSync(closed, jsonl({ type: 'user', cwd: project, message: { content: 'old work' } }))

writeFileSync(live, jsonl(
  { type: 'user', cwd: project, timestamp: 't1', message: { content: '<command-name>/dev-deliver</command-name>' } },
  { type: 'assistant', attributionSkill: 'dev-deliver', timestamp: 't2', message: { content: [{ type: 'tool_use', id: 'u1', name: 'Bash', input: { command: 'npm test' } }] } },
  { type: 'user', timestamp: 't3', message: { content: [{ type: 'tool_result', tool_use_id: 'u1', is_error: true, content: 'Exit code 1\ntoken ghp_abcdefghijklmnopqrstuvwxyz0123 failed' }] } },
  { type: 'user', timestamp: 't4', message: { content: [{ type: 'tool_result', tool_use_id: 'u2', is_error: true, content: "The user doesn't want to proceed with this tool use." }] } },
  { type: 'user', timestamp: 't5', message: { content: [{ type: 'tool_result', tool_use_id: 'u3', content: 'fine' }] } },
  { type: 'user', timestamp: 't6', message: { content: '<system-reminder>context</system-reminder>' } },
  { type: 'user', timestamp: 't7', message: { content: 'no, run the gate first' } },
  { type: 'user', isMeta: true, timestamp: 't8', message: { content: 'meta' } },
  { type: 'user', timestamp: 't9', message: { content: [{ type: 'text', text: '[Request interrupted by user]' }] } },
  { type: 'system', subtype: 'compact_boundary', timestamp: 't10' },
))

// Codex: a dated tree of rollouts, the first line naming the session and its cwd.
const day = join(codex, 'sessions', '2026', '11', '17')
mkdirSync(day, { recursive: true })
const rollout = join(day, 'rollout-2026-11-17T10-00-00-cx-1.jsonl')
writeFileSync(rollout, jsonl(
  { type: 'session_meta', timestamp: 'c0', payload: { id: 'cx-1', cwd: project } },
  { type: 'response_item', timestamp: 'c1', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '# AGENTS.md instructions for app' }] } },
  { type: 'response_item', timestamp: 'c2', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: '$git-finalize-pr 12' }] } },
  { type: 'event_msg', timestamp: 'c3', payload: { type: 'user_message', message: '$git-finalize-pr 12' } },
  { type: 'event_msg', timestamp: 'c4', payload: { type: 'item_completed', item: { type: 'CommandExecution', command: ['pwsh', '-Command', 'dotnet build'], exit_code: 127, aggregated_output: 'dotnet: command not found' } } },
  { type: 'event_msg', timestamp: 'c5', payload: { type: 'item_completed', item: { type: 'CommandExecution', command: ['pwsh', '-Command', 'git status'], exit_code: 0 } } },
  { type: 'event_msg', timestamp: 'c6', payload: { type: 'turn_aborted', reason: 'interrupted' } },
))
const oldRollout = join(day, 'rollout-2026-11-17T08-00-00-cx-0.jsonl')
writeFileSync(oldRollout, jsonl({ type: 'session_meta', payload: { id: 'cx-0', cwd: project } }))
const hourAgo = new Date(Date.now() - 3600e3)
utimesSync(oldRollout, hourAgo, hourAgo)
const elsewhere = join(day, 'rollout-2026-11-17T09-00-00-cx-9.jsonl')
writeFileSync(elsewhere, jsonl({ type: 'session_meta', payload: { id: 'cx-9', cwd: other } }))

const cases = {
  'lists the live sessions under the project, never itself, a dead process or another project'() {
    const r = run('list', '--root', project)
    assert.equal(r.code, 0, r.err)
    const got = rows(r.out).map(([tool, id, state]) => `${tool} ${id} ${state}`).sort()
    assert.deepEqual(got, ['claude live-1 busy', 'codex cx-1 active'])
  },

  'adds ended sessions with --closed'() {
    const got = rows(run('list', '--root', project, '--closed').out).map(([tool, id, state]) => `${tool} ${id} ${state}`).sort()
    assert.deepEqual(got, ['claude live-1 busy', 'claude old-1 closed', 'codex cx-0 closed', 'codex cx-1 active'])
  },

  'leaves out an id passed to --exclude'() {
    const ids = rows(run('list', '--root', project, '--exclude', 'cx-1').out).map((r) => r[1])
    assert.deepEqual(ids, ['live-1'])
  },

  'reads Claude Code signals with the skill that was running, and redacts credentials'() {
    const r = run('read', live)
    assert.equal(r.code, 0, r.err)
    const lines = r.out.trim().split('\n')
    const kinds = lines.map((l) => l.split('\t')[0])
    assert.deepEqual(kinds.slice(0, -1), ['SKILL', 'ERROR', 'DENIED', 'USER', 'INTERRUPT', 'COMPACT'])
    assert.match(lines[1], /skill=dev-deliver Bash npm test -> Exit code 1 token <redacted> failed/)
    assert.doesNotMatch(r.out, /ghp_/)
    assert.match(lines[3], /\tskill=dev-deliver no, run the gate first$/)
    assert.match(lines.at(-1), /^CURSOR=\d+$/)
  },

  'resumes from its cursor and holds back a line still being written'() {
    const cursor = run('read', live).out.trim().split('\n').at(-1).slice('CURSOR='.length)
    appendFileSync(live, JSON.stringify({ type: 'user', timestamp: 't11', message: { content: 'second try' } }) + '\n{"type":"us')
    const r = run('read', live, '--from', cursor)
    const lines = r.out.trim().split('\n')
    assert.equal(lines.length, 2)
    assert.match(lines[0], /^USER\tt11\t/)
    const next = Number(lines[1].slice('CURSOR='.length))
    assert.ok(next > Number(cursor))
    appendFileSync(live, 'er","timestamp":"t12","message":{"content":"third"}}\n')
    assert.match(run('read', live, '--from', String(next)).out, /^USER\tt12\t.*third\n/)
  },

  'reads Codex signals: one user turn, the skill it names, failed commands, aborts'() {
    const lines = run('read', rollout).out.trim().split('\n')
    assert.deepEqual(lines.slice(0, -1).map((l) => l.split('\t')[0]), ['SKILL', 'USER', 'ERROR', 'INTERRUPT'])
    assert.match(lines[2], /exit 127 dotnet build -> dotnet: command not found/)
  },

  'reads a compressed Codex rollout, its cursor counting lines'() {
    if (typeof zlib.zstdCompressSync !== 'function') return 'skip: this node has no zstd'
    const zst = join(day, 'rollout-2026-11-17T11-00-00-cx-2.jsonl.zst')
    writeFileSync(zst, zlib.zstdCompressSync(readFileSync(rollout)))
    const lines = run('read', zst).out.trim().split('\n')
    assert.deepEqual(lines.slice(0, -1).map((l) => l.split('\t')[0]), ['SKILL', 'USER', 'ERROR', 'INTERRUPT'])
    assert.match(lines.at(-1), /^CURSOR=7@\d+$/)
    assert.equal(run('read', zst, '--from', lines.at(-1).slice('CURSOR='.length)).out, lines.at(-1) + '\n')
    rmSync(zst)
  },

  async 'wait returns 0 when the transcript grows'() {
    const cursor = run('read', live).out.trim().split('\n').at(-1).slice('CURSOR='.length)
    const pending = runAsync('wait', 'claude', 'live-1', live, '--from', cursor, '--timeout', '5')
    setTimeout(() => appendFileSync(live, JSON.stringify({ type: 'user', message: { content: 'more' } }) + '\n'), 200)
    assert.equal(await pending, 0)
  },

  async 'wait returns 4 when a live session stays quiet past the timeout'() {
    const cursor = run('read', live).out.trim().split('\n').at(-1).slice('CURSOR='.length)
    assert.equal(await runAsync('wait', 'claude', 'live-1', live, '--from', cursor, '--timeout', '0.3'), 4)
  },

  async 'wait returns 3 when the session is gone from the registry, or Codex went quiet'() {
    const cursor = run('read', closed).out.trim().split('\n').at(-1).slice('CURSOR='.length)
    assert.equal(await runAsync('wait', 'claude', 'old-1', closed, '--from', cursor, '--timeout', '5'), 3)
    const cx = run('read', oldRollout).out.trim().split('\n').at(-1).slice('CURSOR='.length)
    assert.equal(await runAsync('wait', 'codex', 'cx-0', oldRollout, '--from', cx, '--timeout', '5'), 3)
  },

  'refuses a missing transcript and a cursor past its end'() {
    assert.equal(run('read', join(home, 'missing.jsonl')).code, 2)
    assert.equal(run('read', live, '--from', '99999999').code, 2)
    assert.equal(run('list').code, 2)
  },
}

let failed = 0
try {
  for (const [name, test] of Object.entries(cases)) {
    try {
      const skipped = await test()
      console.log(skipped ? `${skipped} - ${name}` : `ok - ${name}`)
    } catch (error) {
      failed += 1
      console.log(`FAIL - ${name}\n${error.message}`)
    }
  }
} finally {
  rmSync(home, { recursive: true, force: true })
}
console.log(failed ? `${failed} failed` : 'all passed')
process.exit(failed ? 1 : 0)
