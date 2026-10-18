// Intelligence sync status for Claude Code.
//
// `intelligence sync` renders this file from the engine's claude-plugin
// template when targets.claude.plugin is true (decision 0022). It is a Claude
// Code mod: a hooks module with no Node.js APIs, reaching the project only
// through the mods API `$`. It asks `intelligence sync --check` whether the
// generated output is current when a session starts and every five minutes,
// shows the answer under the prompt, and runs `intelligence sync` from a
// button above the prompt or the /intelligence command. It registers no tool
// and never submits a prompt: it informs the person, never Claude.

// A cold `sync --check` renders the project in a private copy, which takes
// minutes on Git Bash; a warm one answers from its record in seconds. The
// timeout stays just under the interval, so a slow check is waited for rather
// than reported as a failure, and the next tick never overlaps it.
const CHECK_EVERY_MS = 300000
const CHECK_TIMEOUT_MS = 290000
// `$.process.run` allows ten minutes at most, which a full sync may need: it
// first waits for any check holding the project lock (decision 0022).
const SYNC_TIMEOUT_MS = 600000
// The CLI's refusal when another command holds the project lock.
const LOCK_REFUSAL = /another intelligence sync is (running|starting)/

// What the last check found. `status` is one of unknown, ok, stale, error,
// missing-cli or elsewhere (another command held the project lock); `busy` is
// true while a sync started from here is running.
const state = { status: 'unknown', detail: '', checkedAt: null, busy: false }
// A check already in flight answers the next caller too, so a timer tick and
// a /intelligence check never run two CLI processes side by side.
let pendingCheck = null

// The CLI reports its result as one `IS_STATUS=<status> IS_DETAIL=<text>`
// line; everything else on stdout is progress.
function parseStatus(stdout) {
  const match = /^IS_STATUS=(\S+)(?: IS_DETAIL=(.*))?$/m.exec(stdout || '')
  return { status: match ? match[1] : '', detail: match && match[2] ? match[2].trim() : '' }
}

function firstLine(text) {
  const line = (text || '').split(/\r?\n/).find((l) => l.trim() !== '')
  return line ? line.trim() : ''
}

// A failing CLI prints its progress before the reason, so the first line is
// often a banner: prefer the line that says what went wrong.
function reasonLine(text) {
  const line = (text || '').split(/\r?\n/).find((l) => /^\s*ERROR:/.test(l))
  return line ? line.trim().replace(/^ERROR:\s*/, '') : firstLine(text)
}

function errorMessage(err) {
  return String(err && err.message ? err.message : err)
}

function clock(date) {
  const hh = String(date.getHours()).padStart(2, '0')
  const mm = String(date.getMinutes()).padStart(2, '0')
  return hh + ':' + mm
}

function setState(status, detail) {
  state.status = status
  state.detail = detail || ''
  state.checkedAt = new Date()
}

// The line under the prompt. Claude Code prefixes it with the plugin's name,
// so the text starts after `intelligence:`.
function statusText() {
  if (state.busy) return 'syncing…'
  const at = state.checkedAt ? ' · ' + clock(state.checkedAt) : ''
  switch (state.status) {
    case 'ok':
      return 'up to date' + at
    case 'stale':
      return 'sync needed — run /intelligence sync' + at
    case 'missing-cli':
      return 'CLI not found on PATH'
    case 'elsewhere':
      return 'an intelligence command is still running in this project' + at
    case 'error':
      return 'check failed: ' + state.detail + at
    default:
      return 'checking…'
  }
}

// Every state change redraws both places the state shows: the status line is
// replaced in full, and the band above the prompt is asked to render again.
function show($) {
  $.ui.status(statusText())
  $.ui.invalidate('ui.render')
}

async function check($) {
  if (state.busy) return
  if (pendingCheck) return pendingCheck
  pendingCheck = runCheck($).finally(() => {
    pendingCheck = null
  })
  return pendingCheck
}

async function runCheck($) {
  let result
  let cwd = ''
  try {
    // The project root, not the shell's cwd: a session started in a
    // subdirectory still checks the project the plugin was rendered for.
    cwd = await $.session.root()
    result = await $.process.run(['intelligence', 'sync', '--check'], { cwd, timeoutMs: CHECK_TIMEOUT_MS })
  } catch (err) {
    // The call rejects when the program cannot start or outlives its
    // timeout; the result arrives whatever the exit code otherwise.
    const message = errorMessage(err)
    if (/failed to start/i.test(message)) setState('missing-cli', message)
    else if (await lockHeld($, cwd)) setState('elsewhere', message)
    else setState('error', message)
    show($)
    return
  }
  const parsed = parseStatus(result.stdout)
  // Exit 0 is up to date and 2 is `out-of-date`, the only verdicts sync
  // --check gives; anything else is the CLI refusing to answer.
  // A writer holding the project lock is someone's sync, not a fault: the
  // check yields to it, and the next tick answers.
  if (result.exitCode === 0) setState('ok', parsed.detail)
  else if (result.exitCode === 2) setState('stale', parsed.detail || 'sync needed')
  else if (LOCK_REFUSAL.test(result.stderr || '')) setState('elsewhere', reasonLine(result.stderr))
  else setState('error', parsed.detail || reasonLine(result.stderr) || 'exit ' + result.exitCode)
  show($)
}

// A check cut off at its timeout behind another command, or still finishing
// on its own, leaves the project lock in place: that is a command still
// running, not a failed check. The process the timeout abandoned keeps running.
async function lockHeld($, root) {
  if (!root) return false
  try {
    return await $.fs.exists(root + '/.intelligence/sync.lock')
  } catch {
    return false
  }
}

async function runSync($) {
  if (state.busy) return
  state.busy = true
  show($)
  let outcome
  try {
    // A check of ours still running holds the project lock; the CLI would
    // wait for it too, but waiting here keeps its late answer from landing
    // after the sync's own.
    if (pendingCheck) await pendingCheck
    const cwd = await $.session.root()
    const result = await $.process.run(['intelligence', 'sync', '--compact'], { cwd, timeoutMs: SYNC_TIMEOUT_MS })
    if (result.exitCode === 0) {
      outcome = 'sync finished'
    } else {
      const reason = reasonLine(result.stderr) || parseStatus(result.stdout).detail || 'exit ' + result.exitCode
      outcome = 'sync failed: ' + reason
    }
  } catch (err) {
    outcome = 'sync could not run: ' + errorMessage(err)
  }
  state.busy = false
  $.ui.toast(outcome)
  // The check, not the sync's own exit code, decides what the status shows:
  // it is the same judgement the next timer tick would make.
  await check($)
  return outcome
}

export function register(on) {
  on('session.start', async ($, e, next) => {
    // Neither the first check nor the timer is awaited: the session must
    // never wait on the CLI, which can take minutes on a cold check.
    check($)
    $.clock.every(CHECK_EVERY_MS, () => check($))
    // Registered last and guarded: a taken name throws, and a hook that
    // throws is skipped from that line on.
    try {
      await $.command.register({
        name: 'intelligence',
        description: 'Show Intelligence sync status or run sync',
        argumentHint: '[sync|check]',
        immediate: true,
      })
    } catch (err) {
      $.ui.log('/intelligence not registered: ' + errorMessage(err), { to: 'debug' })
    }
    return next(e)
  })

  on('command.run', { command: 'intelligence' }, async ($, e) => {
    const args = (e.args || '').trim()
    if (args === 'sync') {
      if (state.busy) return { text: 'a sync started from here is still running' }
      const outcome = await runSync($)
      return { text: outcome + ' — ' + statusText() }
    }
    if (args === 'check') {
      await check($)
      return { text: statusText() }
    }
    if (args === '') {
      const detail = state.detail && state.status !== 'ok' ? ' (' + state.detail + ')' : ''
      return { text: statusText() + detail }
    }
    return { text: 'usage: /intelligence [sync|check]' }
  })

  // The band above the prompt is drawn only when there is something to act
  // on or wait for; otherwise the event passes on and nothing is drawn.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    if (state.busy) {
      return Box({
        flexDirection: 'row',
        columnGap: 1,
        children: [Text({ color: 'cyan', children: ['intelligence: syncing…'] })],
      })
    }
    if (state.status === 'stale') {
      return Box({
        flexDirection: 'row',
        columnGap: 2,
        children: [
          Text({ color: 'yellow', children: ['intelligence: sync needed'] }),
          Button({ key: 'sync', label: 'Sync now', hotkey: 's', onPress: () => runSync($) }),
        ],
      })
    }
    if (state.status === 'error') {
      return Box({
        flexDirection: 'row',
        columnGap: 1,
        children: [Text({ color: 'red', children: ['intelligence: ' + statusText()] })],
      })
    }
    return next(e)
  })
}
