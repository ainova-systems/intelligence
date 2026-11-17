#!/usr/bin/env node
// Finds the Claude Code and Codex sessions working in a project, reads what
// went wrong in their transcripts, and waits for a live one to write more or
// end. Neither tool documents these files: the shapes read here are the ones
// observed, and anything unrecognised is skipped rather than guessed at.
//
//   node sessions.mjs list --root <dir> [--root <dir>]... [--closed] [--limit N] [--exclude <id>]
//       one tab-separated line per session: tool id state updated transcript
//       state: busy | idle | active (live)  or  closed
//   node sessions.mjs read <transcript> [--from <cursor>]
//       one line per signal since <cursor>, then CURSOR=<position>@<size>
//   node sessions.mjs wait <tool> <id> <transcript> --from <cursor> [--timeout S] [--quiet S]
//       exit 0 the transcript grew, 3 the session ended, 4 timed out still live
//
// Requires node 18; a compressed Codex transcript (.jsonl.zst) needs node 22.15
// or a `zstd` on PATH.
import { readFileSync, readdirSync, statSync, existsSync, openSync, readSync, closeSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { homedir } from 'node:os'
import { execFileSync } from 'node:child_process'
import zlib from 'node:zlib'

const CLAUDE_HOME = process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude')
const CODEX_HOME = process.env.CODEX_HOME || join(homedir(), '.codex')
const EXCERPT = 300

function fail(message, code = 2) {
  process.stderr.write(message + '\n')
  process.exit(code)
}

function args(argv) {
  const out = { _: [], root: [], exclude: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (!a.startsWith('--')) { out._.push(a); continue }
    const key = a.slice(2)
    if (key === 'closed') { out.closed = true; continue }
    if (i + 1 >= argv.length) fail(`${a} needs a value`)
    const value = argv[++i]
    if (Array.isArray(out[key])) out[key].push(value)
    else out[key] = value
  }
  return out
}

// One spelling per directory, so a Git Bash `/d/repo`, a `D:\repo` from a
// registry and a `file:///D:/repo` from Codex compare equal.
function norm(p) {
  let s = String(p).replace(/^file:\/\/\/?/, '').replace(/\\/g, '/')
  if (process.platform === 'win32') {
    s = s.replace(/^\/([a-zA-Z])\//, '$1:/').toLowerCase()
  }
  return s.replace(/\/+$/, '')
}

const inside = (cwd, roots) => roots.some((r) => cwd === r || cwd.startsWith(r + '/'))

function alive(pid) {
  try { process.kill(pid, 0); return true } catch (e) { return e.code === 'EPERM' }
}

const mtime = (f) => { try { return statSync(f).mtimeMs } catch { return 0 } }
const iso = (ms) => (ms ? new Date(ms).toISOString() : '-')

function lines(file) {
  if (!file.endsWith('.zst')) return readFileSync(file, 'utf8').split('\n')
  const raw = readFileSync(file)
  let text
  if (typeof zlib.zstdDecompressSync === 'function') {
    text = zlib.zstdDecompressSync(raw).toString('utf8')
  } else {
    try { text = execFileSync('zstd', ['-dcq', file], { encoding: 'utf8', maxBuffer: 1 << 30 }) }
    catch { fail(`cannot read ${file}: needs node 22.15 or zstd on PATH`) }
  }
  return text.split('\n')
}

// The first bytes of a plain transcript, enough to find the line naming its cwd.
function head(file, bytes = 65536) {
  if (file.endsWith('.zst')) return lines(file).slice(0, 20)
  const fd = openSync(file, 'r')
  try {
    const buf = Buffer.alloc(bytes)
    const n = readSync(fd, buf, 0, bytes, 0)
    return buf.subarray(0, n).toString('utf8').split('\n')
  } finally { closeSync(fd) }
}

const parse = (line) => { try { return JSON.parse(line) } catch { return null } }

// --- discovery ---------------------------------------------------------------

function claudeLive() {
  const dir = join(CLAUDE_HOME, 'sessions')
  const live = new Map()
  if (!existsSync(dir)) return live
  for (const name of readdirSync(dir)) {
    if (!name.endsWith('.json')) continue
    const entry = parse(readFileSync(join(dir, name), 'utf8'))
    if (entry && entry.sessionId && entry.pid && alive(entry.pid)) live.set(entry.sessionId, entry)
  }
  return live
}

function claudeTranscript(id) {
  const projects = join(CLAUDE_HOME, 'projects')
  if (!existsSync(projects)) return null
  for (const dir of readdirSync(projects)) {
    const file = join(projects, dir, id + '.jsonl')
    if (existsSync(file)) return file
  }
  return null
}

function claudeCwd(file) {
  for (const line of head(file)) {
    const entry = parse(line)
    if (entry && entry.cwd) return entry.cwd
  }
  return null
}

function claudeSessions(roots, closed) {
  const live = claudeLive()
  const out = []
  for (const [id, entry] of live) {
    if (!inside(norm(entry.cwd), roots)) continue
    const transcript = claudeTranscript(id)
    if (transcript) out.push({ tool: 'claude', id, state: entry.status || 'active', updated: mtime(transcript), transcript })
  }
  if (!closed) return out
  const projects = join(CLAUDE_HOME, 'projects')
  if (!existsSync(projects)) return out
  // A project directory is the cwd with every other character turned into
  // '-', which is ambiguous, so it only shortlists; the transcript's own cwd decides.
  const keys = roots.map((r) => r.replace(/[^a-zA-Z0-9]/g, '-').toLowerCase())
  for (const dir of readdirSync(projects)) {
    const d = dir.toLowerCase()
    if (!keys.some((k) => d === k || d.startsWith(k + '-'))) continue
    for (const name of readdirSync(join(projects, dir))) {
      const id = name.replace(/\.jsonl$/, '')
      if (id === name || live.has(id)) continue
      const transcript = join(projects, dir, name)
      const cwd = claudeCwd(transcript)
      if (cwd && inside(norm(cwd), roots)) out.push({ tool: 'claude', id, state: 'closed', updated: mtime(transcript), transcript })
    }
  }
  return out
}

function codexFiles() {
  const base = join(CODEX_HOME, 'sessions')
  const out = []
  const walk = (dir) => {
    let names
    try { names = readdirSync(dir) } catch { return }
    for (const name of names) {
      const p = join(dir, name)
      if (/^rollout-.*\.jsonl(\.zst)?$/.test(name)) out.push(p)
      else if (/^\d+$/.test(name)) walk(p)
    }
  }
  walk(base)
  return out.map((f) => ({ f, m: mtime(f) })).sort((a, b) => b.m - a.m)
}

// Codex keeps no registry of running sessions, so a transcript written within
// the quiet window counts as live and one silent past it as ended.
function codexSessions(roots, closed, limit, quietMs) {
  const out = []
  const now = Date.now()
  for (const { f, m } of codexFiles()) {
    const live = now - m < quietMs
    if (!live && !closed) break
    if (out.length >= limit) break
    let meta
    try { meta = head(f).map(parse).find((e) => e && e.type === 'session_meta') } catch { continue }
    if (!meta || !meta.payload || !meta.payload.cwd || !inside(norm(meta.payload.cwd), roots)) continue
    out.push({ tool: 'codex', id: meta.payload.id, state: live ? 'active' : 'closed', updated: m, transcript: f })
  }
  return out
}

// --- signals -----------------------------------------------------------------

const SECRET = /(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[A-Z0-9]{16}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)/g

function excerpt(value) {
  let s = typeof value === 'string' ? value : JSON.stringify(value)
  s = (s || '').replace(SECRET, '<redacted>').replace(/\s+/g, ' ').trim()
  return s.length > EXCERPT ? s.slice(0, EXCERPT) + '…' : s
}

function textOf(content) {
  if (typeof content === 'string') return content
  if (Array.isArray(content)) return content.map((b) => (b && (b.text || (typeof b.content === 'string' ? b.content : ''))) || '').join(' ')
  return ''
}

// Wrappers a tool injects into the user's turn are context, not the user speaking.
const injected = /^\s*(<(system-reminder|environment_context|user_instructions|local-command|task-notification)|# AGENTS\.md instructions|Caveat:|Base directory for this skill)/

function claudeSignals(entries, emit) {
  const tools = new Map()
  let skill = ''
  for (const e of entries) {
    const tag = (s) => (skill ? `skill=${skill} ` : '') + s
    if (e.type === 'assistant') {
      if (e.attributionSkill) skill = e.attributionSkill
      if (e.isApiErrorMessage) emit('APIERROR', e.timestamp, tag(excerpt(textOf(e.message && e.message.content))))
      for (const b of (e.message && Array.isArray(e.message.content) ? e.message.content : [])) {
        if (b.type === 'tool_use') tools.set(b.id, `${b.name} ${excerpt(b.input && (b.input.command || b.input.skill || b.input.file_path || b.input.pattern || b.input))}`)
      }
    } else if (e.type === 'user' && !e.isMeta && e.message) {
      const content = e.message.content
      if (Array.isArray(content) && content.some((b) => b.type === 'tool_result')) {
        for (const b of content) {
          if (b.type !== 'tool_result' || !b.is_error) continue
          const out = textOf(b.content)
          const kind = /doesn't want to proceed|tool use was rejected|denied by the user|user denied/i.test(out) ? 'DENIED' : /hook/i.test(out) ? 'HOOK' : 'ERROR'
          emit(kind, e.timestamp, tag(`${tools.get(b.tool_use_id) || '?'} -> ${excerpt(out)}`))
        }
        continue
      }
      const text = textOf(content)
      const command = /<command-name>\/?([^<]+)<\/command-name>/.exec(text)
      if (command) { skill = command[1].trim(); emit('SKILL', e.timestamp, skill); continue }
      if (/\[Request interrupted by user/.test(text)) { emit('INTERRUPT', e.timestamp, tag('')); continue }
      if (text && !injected.test(text)) emit('USER', e.timestamp, tag(excerpt(text)))
    } else if (e.type === 'system') {
      if (e.subtype === 'compact_boundary') emit('COMPACT', e.timestamp, tag(''))
      else if (e.level === 'error' || e.level === 'warning') emit('SYSTEM', e.timestamp, tag(excerpt(e.content)))
    }
  }
}

function codexSignals(entries, emit) {
  // Codex records one user turn as a response item and, in some versions, an
  // event too: a turn repeating the previous one from the other record is that copy.
  let last = { text: null, from: null }
  const user = (ts, text, from) => {
    if (!text || injected.test(text)) return
    const copy = text === last.text && from !== last.from
    last = copy ? { text: null, from: null } : { text, from }
    if (copy) return
    const skill = /^\s*<skill>\s*<name>([^<]+)<\/name>/.exec(text) || /^\s*\$([a-z0-9][a-z0-9-]*)/.exec(text)
    if (skill) emit('SKILL', ts, skill[1].trim())
    if (!/^\s*<skill>/.test(text)) emit('USER', ts, excerpt(text))
  }
  for (const e of entries) {
    const p = e.payload || {}
    if (e.type === 'response_item' && p.type === 'message' && p.role === 'user') {
      user(e.timestamp, textOf(p.content), 'item')
    } else if (e.type === 'event_msg' && p.type === 'user_message') {
      user(e.timestamp, p.message || '', 'event')
    } else if (e.type === 'event_msg' && p.type === 'item_completed' && p.item && p.item.type === 'CommandExecution') {
      const code = p.item.exit_code
      if (typeof code === 'number' && code !== 0) {
        const cmd = Array.isArray(p.item.command) ? p.item.command[p.item.command.length - 1] : p.item.command
        emit('ERROR', e.timestamp, `exit ${code} ${excerpt(cmd)} -> ${excerpt(p.item.aggregated_output || '')}`)
      }
    } else if (e.type === 'event_msg' && p.type === 'turn_aborted') {
      emit('INTERRUPT', e.timestamp, excerpt(p.reason || ''))
    } else if (e.type === 'event_msg' && (p.type === 'error' || p.type === 'stream_error')) {
      emit('APIERROR', e.timestamp, excerpt(p.message || p))
    } else if (e.type === 'compacted') {
      emit('COMPACT', e.timestamp, '')
    }
  }
}

// A cursor is `<position>@<size>`: the byte offset of the first unread line in
// a plain transcript, or the count of lines read in a compressed one, which only
// whole decompression reads; and the file's size when it was read, which is what
// `wait` compares, so a line held back as unfinished never reads as growth.
function position(cursor) {
  const from = Number(String(cursor === undefined ? '0' : cursor).split('@')[0])
  if (!Number.isInteger(from) || from < 0) fail(`not a cursor: ${cursor}`)
  return from
}

function readSince(file, cursor) {
  const size = statSync(file).size
  const from = position(cursor)
  let entries, next
  if (file.endsWith('.zst')) {
    const all = lines(file)
    // The last line is either empty or still being written, unless it parses.
    const complete = parse(all[all.length - 1]) ? all.length : all.length - 1
    entries = all.slice(from, complete).map(parse).filter(Boolean)
    next = `${Math.max(from, complete)}@${size}`
  } else {
    if (from > size) fail(`cursor ${from} is past the end of ${file}`)
    const fd = openSync(file, 'r')
    const buf = Buffer.alloc(size - from)
    try { readSync(fd, buf, 0, buf.length, from) } finally { closeSync(fd) }
    // A line still being written waits for the next read, unless it parses.
    let end = buf.lastIndexOf(0x0a) + 1
    if (end < buf.length && parse(buf.subarray(end).toString('utf8'))) end = buf.length
    entries = buf.subarray(0, end).toString('utf8').split('\n').map(parse).filter(Boolean)
    next = `${from + end}@${size}`
  }
  return { entries, next }
}

function toolOf(file, entries) {
  if (entries.some((e) => e.type === 'session_meta' || e.type === 'event_msg' || e.type === 'response_item')) return 'codex'
  if (/[\\/]\.codex[\\/]|rollout-/.test(file)) return 'codex'
  return 'claude'
}

// --- commands ----------------------------------------------------------------

function list(opts) {
  if (!opts.root.length) fail('list needs --root')
  // norm first: resolve() reads a Git Bash `/d/repo` as a path on the current drive.
  const roots = opts.root.map((r) => norm(resolve(norm(r))))
  const limit = Number(opts.limit || 20)
  const quietMs = Number(opts.quiet || 900) * 1000
  const exclude = new Set([...opts.exclude, process.env.CLAUDE_CODE_SESSION_ID].filter(Boolean))
  const sessions = [...claudeSessions(roots, opts.closed), ...codexSessions(roots, opts.closed, limit, quietMs)]
    .filter((s) => !exclude.has(s.id))
    .sort((a, b) => b.updated - a.updated)
    .slice(0, limit)
  for (const s of sessions) process.stdout.write([s.tool, s.id, s.state, iso(s.updated), s.transcript].join('\t') + '\n')
}

function read(opts) {
  const file = opts._[1]
  if (!file || !existsSync(file)) fail(`no transcript: ${file || '(none given)'}`)
  const { entries, next } = readSince(file, opts.from)
  const emit = (kind, ts, text) => process.stdout.write(`${kind}\t${ts || '-'}\t${text}\n`)
  ;(toolOf(file, entries) === 'codex' ? codexSignals : claudeSignals)(entries, emit)
  process.stdout.write(`CURSOR=${next}\n`)
}

function ended(tool, id, file, quietMs) {
  if (tool === 'claude') return !claudeLive().has(id)
  return Date.now() - mtime(file) >= quietMs
}

async function wait(opts) {
  const [, tool, id, file] = opts._
  if (!tool || !id || !file) fail('wait needs <tool> <id> <transcript>')
  if (opts.from === undefined) fail('wait needs --from <cursor>')
  const timeoutMs = Number(opts.timeout || 300) * 1000
  const quietMs = Number(opts.quiet || 900) * 1000
  const pollMs = Number(process.env.SESSIONS_POLL_MS || 2000)
  position(opts.from)
  const mark = Number(String(opts.from).split('@')[1])
  if (!Number.isInteger(mark)) fail(`not a cursor from read: ${opts.from}`)
  const start = Date.now()
  for (;;) {
    let size = 0
    try { size = statSync(file).size } catch { /* gone */ }
    if (size !== mark && size > 0) process.exit(0)
    if (ended(tool, id, file, quietMs)) process.exit(3)
    if (Date.now() - start >= timeoutMs) process.exit(4)
    await new Promise((r) => setTimeout(r, pollMs))
  }
}

const opts = args(process.argv.slice(2))
switch (opts._[0]) {
  case 'list': list(opts); break
  case 'read': read(opts); break
  case 'wait': await wait(opts); break
  default: fail('usage: sessions.mjs list|read|wait (see the header of this file)')
}
